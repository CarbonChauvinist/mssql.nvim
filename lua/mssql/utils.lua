local M = {}

---@param msg string
---@param level vim.log.levels
local function log(msg, level)
	if type(msg) == "table" then
		msg = vim.inspect(msg)
	end
	vim.schedule(function()
		vim.notify(msg, level, {
			title = "MSSQL",
			plugin = "MSSQL",
		})
	end)
end

-- as far as I can tell, only one handler can exist for an Lsp
-- method. This lets you register/unregister multiple handlers
M.register_lsp_handler = function(lsp_client, method, handler)
	if not lsp_client.custom_handlers then
		lsp_client.custom_handlers = {}
	end
	if not lsp_client.custom_handlers[method] then
		lsp_client.custom_handlers[method] = {}
	end
	lsp_client.custom_handlers[method][handler] = true

	lsp_client.handlers[method] = function(err, result, ctx)
		for custom_handler, _ in pairs(lsp_client.custom_handlers[method]) do
			-- Use pcall to ensure one crashing handler doesn't stop others
			local success, msg = pcall(custom_handler, err, result, ctx)
			if not success then
				-- Log the error so we know something wrong, but keep going
				-- Use vim.schedule to avoid interrupting the LSP client loop
				vim.schedule(function()
					vim.notify("MSSQL Handler Error: " .. tostring(msg), vim.log.levels.ERROR)
				end)
			end
		end
	end
end

M.unregister_lsp_handler = function(lsp_client, method, handler)
	if not (lsp_client.custom_handlers and lsp_client.custom_handlers[method]) then
		return
	end
	lsp_client.custom_handlers[method][handler] = nil
end

M.wait_for_schedule_async = function()
	local co = coroutine.running()
	vim.schedule(function()
		coroutine.resume(co)
	end)
	coroutine.yield()
end


---Like assert, but doesn't prepend the
---file name and line number
M.safe_assert = function(item, message)
	if not item then
		error(message, 0) -- level 0 = no file/line info
	end
	return item
end

-- resumes the coroutiune, vim notifies any errors
M.try_resume = function(co, ...)
	local result, errmsg = coroutine.resume(co, ...)

	if not result then
		log(errmsg, vim.log.levels.ERROR)
	end

	return result
end

--- The LSP wants the file path to be absolute and start with file:///,
--- But it doesn't want special characters like spaces to be escaped.
M.lsp_file_uri = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local path = vim.api.nvim_buf_get_name(bufnr)
	path = vim.fs.normalize(path)
	path = vim.fs.abspath(path)
	if vim.uv.os_uname().sysname == "Windows_NT" then
		path = "/" .. path
	end
	return "file://" .. path
end

M.get_lsp_client = function(owner_uri)
	local bufnr
	if owner_uri then
		bufnr = vim.iter(vim.api.nvim_list_bufs()):find(function(buf)
			return M.lsp_file_uri(buf) == owner_uri
		end)
		M.safe_assert(bufnr, "No buffer found with filename " .. owner_uri)
	else
		bufnr = 0
	end

	return M.safe_assert(
		vim.lsp.get_clients({ name = "mssql_ls", bufnr = bufnr })[1],
		"No MSSQL lsp client attached. Create a new sql query or open an existing sql file"
	)
end

---makes a request to the mssql lsp client
---@param client vim.lsp.Client
---@param method string
---@param params any
---@return any
---@return lsp.ResponseError?
M.lsp_request_async = function(client, method, params)
	local this = coroutine.running()
	client:request(method, params, function(err, result, _, _)
		M.try_resume(this, result, err)
	end)
	return coroutine.yield()
end

-- gets rows from the lsp given some subset parameters
M.get_rows_async = function(subset_params)
	if not (subset_params and subset_params.rowsCount and subset_params.rowsCount > 0) then
		return {}
	end

	local client = M.get_lsp_client(subset_params.ownerUri)
	if subset_params then
		local result, err = M.lsp_request_async(client, "query/subset", subset_params)
		if err then
			error("Error getting rows: " .. vim.inspect(err), 0)
		elseif not result then
			error("Error getting rows", 0)
		end

		return vim.iter(result.resultSubset.rows)
			:map(function(cells)
				return vim.iter(cells)
					:map(function(cell)
						return cell.displayValue
					end)
					:totable()
			end)
			:totable()
	end
end

--- Formats elapsed time to display string for lualine component.
---@param raw_time number?
---@param with_ms? boolean
---@return string
M.format_elapsed_time_to_string = function(raw_time, with_ms)
	if raw_time == nil then
		return ""
	end
	with_ms = with_ms == nil and true or with_ms
	local hours = math.floor(raw_time / 3600)
	local minutes = math.floor((raw_time % 3600) / 60)
	local seconds = math.floor(raw_time % 60)
	local time_str
	if hours == 0 then
		time_str = string.format("%02d:%02d", minutes, seconds)
	else
		time_str = string.format("%02d:%02d:%02d", hours, minutes, seconds)
	end

	if with_ms then
		local ms = math.floor((raw_time % 1) * 1000)
		return string.format("%s.%03d", time_str, ms)
	else
		return time_str
	end
end

M.defer_async = function(ms)
	local co = coroutine.running()
	vim.defer_fn(function()
		coroutine.resume(co)
	end, ms)

	coroutine.yield()
end

---Waits for the lsp to call the given method, with optional timeout.
---Must be run inside a coroutine.
---@param bufnr integer
---@param client vim.lsp.Client
---@param method string
---@param timeout_in_ms? integer
---@return any result
---@return lsp.ResponseError? error
M.wait_for_notification_async = function(bufnr, client, method, timeout_in_ms)
	local owner_uri = M.lsp_file_uri(bufnr)
	local this = coroutine.running()
	local resumed = false
	local handler
	handler = function(err, result, _)
		if not resumed and result and result.ownerUri == owner_uri then
			resumed = true
			M.unregister_lsp_handler(client, method, handler)
			M.try_resume(this, result, err)
		end
		return result, err
	end
	M.register_lsp_handler(client, method, handler)

	-- Only schedule timeout if valid, positive timeout is provided
	if timeout_in_ms and timeout_in_ms > 0 then
		vim.defer_fn(function()
			if not resumed then
				resumed = true
				M.unregister_lsp_handler(client, method, handler)
				M.try_resume(
					this,
					nil,
					vim.lsp.rpc_response_error(
						vim.lsp.protocol.ErrorCodes.UnknownErrorCode,
						"Waiting for the lsp to call " .. method .. " timed out for buffer " .. bufnr
					)
				)
			end
		end, timeout_in_ms)
	end

	return coroutine.yield()
end

M.ui_select_async = function(items, opts)
	-- Schedule this as it gives other UI like which-key
	-- a chance to close
	M.wait_for_schedule_async()
	local this = coroutine.running()
	vim.ui.select(items, opts, function(selected)
		vim.schedule(function()
			M.try_resume(this, selected)
		end)
	end)
	return coroutine.yield()
end

M.log_info = function(msg)
	log(msg, vim.log.levels.INFO)
end

M.log_warn = function(msg)
	log(msg, vim.log.levels.WARN)
end

M.log_error = function(msg)
	log(msg, vim.log.levels.ERROR)
end


M.get_selected_text = function()
	local mode = vim.api.nvim_get_mode().mode
	if not (mode == "v" or mode == "V" or mode == "\22") then -- \22 is Ctrl-V (visual block)
		local content = vim.api.nvim_buf_get_lines(0, 0, vim.api.nvim_buf_line_count(0), false)
		return table.concat(content, "\n")
	end

	-- exit visual mode so the marks are applied
	local esc = vim.api.nvim_replace_termcodes("<esc>", true, false, true)
	vim.api.nvim_feedkeys(esc, "x", false)

	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")
	local lines = vim.fn.getregion(start_pos, end_pos, { mode = vim.fn.visualmode() })

	return table.concat(lines, "\n")
end

--- Executes a query and returns all the results in the first batch and result set as a table of rows
M.get_query_result_async = function(query_result_summary)
	if query_result_summary.batchSummaries[1].hasError then
		error("Query thew an error", 0)
	end

	local subset_params = {
		ownerUri = query_result_summary.ownerUri,
		batchIndex = 0,
		resultSetIndex = 0,
		rowsStartIndex = 0,
		rowsCount = query_result_summary.batchSummaries[1].resultSetSummaries[1].rowCount,
	}

	M.wait_for_schedule_async()

	local rows = M.get_rows_async(subset_params)
	local columnNames = vim.iter(query_result_summary.batchSummaries[1].resultSetSummaries[1].columnInfo)
		:map(function(ci)
			return ci.columnName
		end)
		:totable()
	local result = {}

	for _, row in pairs(rows) do
		local item = {}
		for index, _ in ipairs(columnNames) do
			item[columnNames[index]] = row[index]
		end
		table.insert(result, item)
	end

	return result
end

--- Handles the logic of disconnecting and attempting to reconnect a session
---@param qm MssqlQueryManager
---@param reason string Log message context (e.g. "Session reloaded", "Buffer renamed")
---@param opts? table { timeout_ms: integer, interval: integer }
---@return boolean success, string? err_msg
M.reconnect_session = function(qm, reason, opts)
	opts = opts or {}
	local timeout_ms = opts.timeout_ms or 10000
	local interval = opts.interval or 250
	local params = qm:get_connect_params()
	local has_creds = params and params.connection and params.connection.options

	if not has_creds then return false, "Does not have connect params to reuse" end

	qm:set_state(qm.states.disconnected)
	M.log_info(reason .. ". Reconnecting...")

	M.try_resume(coroutine.create(function()
		local attempts = 0
		local max_attempts = math.ceil(timeout_ms / interval)
		local connected = false
		local last_err

		while attempts < max_attempts do
			M.defer_async(interval)
			if not params then return false, "Does not have connect params to reuse" end
			local success, err = qm:connect_async(params)
			if success then
				connected = true
				break
			end
			last_err = err
			attempts = attempts + 1
		end

		if not connected then
			return false, "Failed to auto-reconnect: " .. tostring(last_err)
		end
	end))
	return true
end

return M
