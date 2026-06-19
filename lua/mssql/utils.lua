local M = {}

local Timer = {}
Timer.__index = Timer

---Creates a new reusable Timer instance.
---@return MssqlTimer
function Timer.new()
	local self = setmetatable({}, Timer)
	self.handle = vim.uv.new_timer()
	return self
end

---Starts the timer. Automatically stops if already running.
---@param interval_ms integer
---@param callback function
function Timer:start(interval_ms, callback)
	if not self.handle or self.handle:is_closing() then
		self.handle = vim.uv.new_timer()
	end
	self:stop()
	self.handle:start(0, interval_ms, vim.schedule_wrap(callback))
end

---Stops the timer without closing the handle (reusable).
function Timer:stop()
	if self.handle and not self.handle:is_closing() then
		self.handle:stop()
	end
end

---Stops and closes the timer handle (for garbage collection).
function Timer:close()
	self:stop()
	if self.handle and not self.handle:is_closing() then
		self.handle:close()
	end
	self.handle = nil
end

M.Timer = Timer

---@param msg string
---@param level vim.log.levels
local function log(msg, level)
	if type(msg) == "table" then
		msg = vim.inspect(msg)
	end

	msg = tostring(msg or "nil")

	vim.schedule(function()
		vim.notify(msg, level, {
			title = "MSSQL",
			plugin = "MSSQL",
		})
	end)
end

M.wait_for_schedule_async = function()
	local co = coroutine.running()
	vim.schedule(function()
		coroutine.resume(co)
	end)
	coroutine.yield()
end

--- Safely checks if a value is nil or Neovim's explicit null representation (vim.NIL)
--- Use this when evaluating fields returned from LSP responses.
---@param val any
---@return boolean
M.is_empty = function(val)
	return val == nil or val == vim.NIL
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

		if M.is_empty(result.resultSubset) or M.is_empty(result.resultSubset.rows) then
			return {}
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

---Waits for specific notification from the LSP via the Global Router.
---Must be run inside a coroutine.
---@param _bufnr integer
---@param client vim.lsp.Client
---@param method string
---@param timeout_ms? integer
---@return any result
---@return lsp.ResponseError? error
M.wait_for_notification_async = function(_bufnr, client, method, timeout_ms)
	if not timeout_ms and method ~= "query/complete" then
		timeout_ms = 10000
	end
	local state = require("mssql.state")
	local co = coroutine.running()
	local resumed = false

	local dispose = state.on_event(method, function(err, result, ctx)
		if ctx and ctx.client_id == client.id then
			if not resumed then
				resumed = true
				M.try_resume(co, result, err)
			end
		end
	end)

	if timeout_ms then
		vim.defer_fn(function()
			if not resumed then
				resumed = true
				dispose()
				M.try_resume(co, nil, {
					code = -32001, -- timeout code
					message = "Waiting for " .. method .. " timed out"
				})
			end
		end, timeout_ms)
	end

	local result, err = coroutine.yield()
	dispose()
	return result, err
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


---Gets the selected text or the full buffer content if no selection
---@param bufnr? integer The buffer to read from (defaults to 0/current)
---@return string
M.get_selected_text = function(bufnr)
	bufnr = bufnr or 0
	local current_buf = vim.api.nvim_get_current_buf()

	if (bufnr == 0 or bufnr == current_buf) then
		local mode = vim.api.nvim_get_mode().mode
		if mode == "v" or mode == "V" or mode == "\22" then -- \22 is Ctrl-V (visual block)
			-- exit visual mode so the marks are applied
			local esc = vim.api.nvim_replace_termcodes("<esc>", true, false, true)
			vim.api.nvim_feedkeys(esc, "x", false)

			local start_pos = vim.fn.getpos("'<")
			local end_pos = vim.fn.getpos("'>")

			require("mssql.state").set_last_query_range_as_extmarks(bufnr, start_pos, end_pos)
			require("mssql.state").set_last_query_range({
				start = start_pos,
				end_ = end_pos,
				buf = current_buf
			})

			local lines = vim.fn.getregion(start_pos, end_pos, { mode = vim.fn.visualmode() })

			return table.concat(lines, "\n")
		end
	end

	local content = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return table.concat(content, "\n")
end

--- Executes a query and returns all the results in the first batch and result set as a table of rows
M.get_query_result_async = function(query_result_summary)
	-- ensure overall response payload and first batch summary are all valid tables
	if M.is_empty(query_result_summary) or M.is_empty(query_result_summary.batchSummaries) or M.is_empty(query_result_summary.batchSummaries[1]) then
		error("Query result is invalid or empty", 0)
	end

	if query_result_summary.batchSummaries[1].hasError then
		error("Query threw an error", 0)
	end

	local batch_summary = query_result_summary.batchSummaries[1]
	-- ensure resultSetSummaries exists except for DML statements where it won't exist
	if M.is_empty(batch_summary.resultSetSummaries) or M.is_empty(batch_summary.resultSetSummaries[1]) then
		return {} -- No result sets (e.g. INSERT/UPDATE/DELETE)
	end

	local result_set = batch_summary.resultSetSummaries[1]

	local subset_params = {
		ownerUri = query_result_summary.ownerUri,
		batchIndex = 0,
		resultSetIndex = 0,
		rowsStartIndex = 0,
		rowsCount = result_set.rowCount
	}

	M.wait_for_schedule_async()

	local rows = M.get_rows_async(subset_params)
	local columnNames = vim.iter(result_set.columnInfo)
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

-- Regex magic characters. If found, we treat the string as a Lua pattern.
-- excludes `.` and `-` as these are common in database names
-- if user needs to pattern match on either `.` or `-` will need to include
-- additional targeted magic character to engage pattern detection (e.g '^foo.bar')
-- to match single character between 'foo' and 'bar'
local PATTERN_INDICATORS = "[%^%$%(%)%%%[%]%*%+%?]"

---Checks if an item matches a filter entry (literal or pattern).
---Literal is case-insensitive while pattern is case-sensitive.
---@param item string
---@param entry string Literal string or Lua pattern
---@return boolean is_match
local function matches_filter(item, entry)

	if entry:match(PATTERN_INDICATORS) then
		return item:match(entry) ~= nil
	end

	return item:lower() == entry:lower()
end

---Filters a list based on allow/deny string literals and/or Lua patterns. Deny takes precedence.
---@param items string[] List of items to filter
---@param allow? string[] Allow list. If empty {}, returns empty result.
---@param deny? string[] Deny list.
---@return string[] filtered_items
M.filter_list = function(items, allow, deny)
	if allow and #allow == 0 then return {} end
	if not allow and (not deny or #deny == 0) then return vim.deepcopy(items) end

	local function matches_any(item, list)
		for _, val in ipairs(list) do
			if matches_filter(item, val) then return true end
		end
	end

	return vim.tbl_filter(function(item)
		if deny and matches_any(item, deny) then return false end

		if allow then return matches_any(item, allow) end

		return true
	end, items)
end

---@param path string
---@return table
M.read_json_file = function(path)
	local file
	if path then
		file = io.open(path, "r")
	end
	if not file then
		return {}
	end
	local content = file:read("*a")
	file:close()
	return vim.json.decode(content)
end

---@param path string
---@param tbl table
M.write_json_file = function(path, tbl)
	local file
	if path then
		file = io.open(path, "w")
	end
	local text = vim.json.encode(tbl)
	if file then
		file:write(text)
		file:close()
	else
		error("Could not open file: " .. path, 0)
	end
end

---@param opts MssqlConfig
---@return table|nil
M.get_connections = function(opts)
	local f = io.open(opts.connections_file, "r")
	if not f then
		return nil
	end

	local content = f:read("*a")
	f:close()
	local ok, json = pcall(vim.fn.json_decode, content)
	M.safe_assert(
		ok and type(json) == "table" and not vim.islist(json),
		"The connections json file must contain a valid json object"
	)
	return json
end

---@param opts MssqlConfig
M.edit_connections = function(opts)
	if vim.fn.filereadable(opts.connections_file) == 0 then
		M.log_info("Connections json file not found. Creating...")
		local default_connections = [=[
{
  "Example (edit this)": {
    "server": "localhost",
    "database": "master",
    "authenticationType" : "SqlLogin",
    "user" : "Admin",
    "password" : "Your_Password",
    "trustServerCertificate" : true
  }
}
]=]
		vim.fn.writefile(vim.split(default_connections, "\n"), opts.connections_file)
	end
	vim.cmd.edit(opts.connections_file)
end

return M
