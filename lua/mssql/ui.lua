local utils = require("mssql.utils")
local state = require("mssql.state")
local results = require("mssql.results")
local lsp = require("mssql.lsp")

local M = {}

local message_buffer
local message_buffer_error_ns = vim.api.nvim_create_namespace("mssql_error_highlight")
local show_caching_in_status_line = false

---Returns the valid results split window ID for the current tabage, or nil if invalid
---Resets `vim.t.mssql_results_win` to prevent stale window handle references when closed
---@return integer? win The valid results windows ID, or nil if closed/invalid
local get_valid_results_win = function()
	local win = vim.t.mssql_results_win
	if win and vim.api.nvim_win_is_valid(win) then
		return win
	end
	vim.t.mssql_results_win = nil
	return nil
end

---Setter for external modules to toggle caching status in lualine
---@param is_caching boolean
M.set_caching_status = function(is_caching)
	show_caching_in_status_line = is_caching
end

---Creates a new query buffer and waits for LSP attachment (default 10s)
---@param opts? { timeout_ms?: integer, buf_name?: string }
---@return integer buf
---@return vim.lsp.Client? lsp
M.new_query_async = function(opts)
	opts = opts or {}
	local timeout_ms = opts.timeout_ms or 10000
	local buf_name = opts.buf_name

	-- The language server requires all files to have a file name.
	-- Vscode names new files "untitled-1" etc so we'll do the same
	vim.cmd.enew()
	local buf = vim.api.nvim_get_current_buf()
	if buf_name and buf_name ~= "" then
		vim.api.nvim_buf_set_name(buf, buf_name .. ".sql")
	else
		vim.api.nvim_buf_set_name(buf, "untitled-" .. buf .. ".sql")
		vim.b[buf].is_temp_name = true
	end
	vim.cmd.setfiletype({ args = { "sql" } })

	local client = lsp.wait_for_attach(buf, timeout_ms)
	return buf, client
end

--- Inserts query text into current buffer or creates a new one
---@param query string
---@param label? string
---@return integer bufnr on success
M.insert_query_into_buffer = function(query, label)
	local source_buf = vim.api.nvim_get_current_buf()

	if vim.trim(table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false))) == "" then
		vim.api.nvim_buf_set_lines(source_buf, 0, 0, false, vim.split(query, "\n"))
		if label and (vim.b[source_buf].is_temp_name or vim.api.nvim_buf_get_name(source_buf) == "") then
			vim.api.nvim_buf_set_name(source_buf, label .. ".sql")
			vim.b[source_buf].is_temp_name = nil

			-- if renaming an already-connected buffer, register the new URI with server
			local source_qm = state.get_query_manager(source_buf)
			if source_qm and source_qm:get_state() == source_qm.states.connected then
				local conn_params = source_qm:get_connect_params()
				if conn_params then
					source_qm:connect_async(conn_params)
				end
			end
		end

		return source_buf
	end

	local source_qm = state.get_query_manager(source_buf)
	if not source_qm then
		error("Connect to a database first", 0)
	end
	local source_conn_params = source_qm:get_connect_params()

	local target_buf = M.new_query_async({ buf_name = label })

	local target_qm = state.get_query_manager(target_buf)
	if target_qm and source_conn_params then
		target_qm:connect_async(source_conn_params)
	end
	vim.api.nvim_buf_set_lines(target_buf, 0, 0, false, vim.split(query, "\n"))
	return target_buf
end

M.show_results_buffer_options = {
	current_window = function(bufnr)
		vim.api.nvim_set_option_value("buflisted", true, { buf = bufnr })
		vim.api.nvim_set_current_buf(bufnr)
	end,
	split = function(bufnr)
		local original_window = vim.api.nvim_get_current_win()
		local win = get_valid_results_win()

		-- open a split if we haven't done already
		if not win then
			vim.cmd.split()
			win = vim.api.nvim_get_current_win()
			vim.t.mssql_results_win = win
		end

		vim.api.nvim_set_option_value("buflisted", true, { buf = bufnr })
		vim.api.nvim_win_set_buf(win, bufnr)
		vim.api.nvim_set_current_win(original_window)
	end,
	vsplit = function(bufnr)
		local original_window = vim.api.nvim_get_current_win()
		local win = get_valid_results_win()

		-- open a split if we haven't done already
		if not win then
			vim.cmd.vsplit()
			win = vim.api.nvim_get_current_win()
			vim.t.mssql_results_win = win
		end

		vim.api.nvim_set_option_value("buflisted", true, { buf = bufnr })
		vim.api.nvim_win_set_buf(win, bufnr)
		vim.api.nvim_set_current_win(original_window)
	end,
}

-- If the open_results_in is a string, sets it to the appropriate function
---@param opts? MssqlConfig
M.set_show_results_option = function(opts)
	opts = opts or {}
	if type(opts.open_results_in) == "string" and M.show_results_buffer_options[opts.open_results_in] then
		opts.open_results_in = M.show_results_buffer_options[opts.open_results_in]
	elseif type(opts.open_results_in) == "function" then
		return
	else
		utils.log_error(
			vim.inspect(opts.open_results_in)
				.. " is not a valid option for open_results_in. Must be one of: "
				.. table.concat(vim.tbl_keys(M.show_results_buffer_options), ", ")
				.. ", or a function"
		)
	end
end

---Clears all text content from the SQL messages buffer
---@return nil
M.clear_message_buffer = function()
	if message_buffer and vim.api.nvim_buf_is_valid(message_buffer) then
		vim.api.nvim_set_option_value("modifiable", true, { buf = message_buffer })
		vim.api.nvim_buf_set_lines(message_buffer, 0, -1, false, {})
		vim.api.nvim_set_option_value("modifiable", false, { buf = message_buffer })
	end
end

---@type table<string, function>
M.view_message_options = {
	---Displays message as a Neovim notification
	---@param message string
	---@param is_error boolean
	notification = function(message, is_error)
		if is_error then
			utils.log_error(message)
		else
			utils.log_info(message)
		end
	end,

	---Appends message to the dedicated messages buffer.
	---@param message string
	---@param is_error boolean
	buffer = function(message, is_error)
		local opts = state.get_config()

		if not (message_buffer and vim.api.nvim_buf_is_valid(message_buffer)) then
			message_buffer = vim.api.nvim_create_buf(false, false)
			vim.api.nvim_buf_set_name(message_buffer, "sql messages")
			vim.api.nvim_set_option_value("buftype", "nofile", { buf = message_buffer })
			vim.api.nvim_set_option_value("bufhidden", "hide", { buf = message_buffer })
			vim.api.nvim_set_option_value("swapfile", false, { buf = message_buffer })
			vim.api.nvim_set_option_value("readonly", true, { buf = message_buffer })
			vim.api.nvim_set_option_value("modifiable", false, { buf = message_buffer })
			if opts and opts.open_results_in then
				opts.open_results_in(message_buffer)
			end
		end
		-- Append a line at the end
		local lines = vim.api.nvim_buf_line_count(message_buffer)
		vim.api.nvim_set_option_value("modifiable", true, { buf = message_buffer })
		local message_lines = vim.split(message:gsub("\r", ""), "\n")
		vim.api.nvim_buf_set_lines(message_buffer, lines, lines, false, message_lines)

		-- Apply the 'Error' highlight group to the line
		if is_error then
			vim.api.nvim_buf_set_extmark(message_buffer, message_buffer_error_ns, lines, 0, {
				end_row = lines + #message_lines,
				hl_group = "Error",
			})
		end

		vim.api.nvim_set_option_value("modifiable", false, { buf = message_buffer })
	end,
}

---@type table<function>
M.lualine_component = {
	---Status line formatter component showing MSSQL connection/execution state.
	---@param bufnr? integer
	---@return string?
	function(bufnr)
		if type(bufnr) ~= "number" then
			bufnr = vim.api.nvim_get_current_buf()
		end
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return ""
		end
		local qm = state.get_query_manager(bufnr)
		local qri = vim.b[bufnr].query_result_info
		local config = state.get_config()

		if qri then
			return results.get_pagination_status(bufnr)
		elseif not qm then
			return
		end

		local qm_state = qm:get_state()
		local icons = config and config.icons and config.icons.status_line or {}

		if qm_state == qm.states.disconnected then
			local disconnected_icon = (icons.enabled and icons.disconnected .. " ") or ""
			return disconnected_icon .. "Connect to MSSQL"
		elseif qm_state == qm.states.connecting then
			return "Connecting..."
		end

		local status_parts = {}
		local exec_info = qm:last_execution()
		local connect_params = qm:get_connect_params()

		local server_db_string = ""
		if connect_params and connect_params.connection and connect_params.connection.options then
			local server = connect_params.connection.options.server
			local db = connect_params.connection.options.database
			if db and server then
				local db_icon, server_icon = "", ""
				if icons.enabled then
					server_icon = icons.server .. " "
					db_icon = " " .. icons.database .. " "
					server_db_string = server_icon .. server .. db_icon .. db
				else
					server_db_string = server .. " | " .. db
				end
			end
		end

		if qm_state == qm.states.executing then
			table.insert(status_parts, server_db_string)
			table.insert(status_parts, "Executing...")
			if exec_info.elapsed_time then
				table.insert(status_parts, utils.format_elapsed_time_to_string(exec_info.elapsed_time, false))
			end
		else -- Connected state (after completion, cancellation, or idle)
			if exec_info.rows_affected ~= nil then
				local rows_text = exec_info.rows_affected == 1 and "row" or "rows"
				table.insert(status_parts, string.format("%d %s affected", exec_info.rows_affected, rows_text))
			end
			if exec_info.elapsed_time and exec_info.elapsed_time > 0 then
				table.insert(status_parts, utils.format_elapsed_time_to_string(exec_info.elapsed_time, true))
			end
			table.insert(status_parts, server_db_string)
		end

		if qm_state == qm.states.connected then
			if not qm:is_intellisense_ready() then
				table.insert(status_parts, "Updating IntelliSense...")
			elseif show_caching_in_status_line and qm:is_refreshing() then
				table.insert(status_parts, "Caching database objects...")
			end
		end

		return table.concat(status_parts, "  ")
	end,

	---Condition function to control visibility of the lualine statue component.
	---@param bufnr? integer
	---@return boolean
	cond = function(bufnr)
		if type(bufnr) ~= "number" then
			bufnr = vim.api.nvim_get_current_buf()
		end
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return false
		end
		local qm = state.get_query_manager(bufnr)
		return qm ~= nil or vim.b[bufnr].query_result_info ~= nil
	end,
}

---Resolves the configured message view output destination to its matching function.
---@param opts MssqlConfig
M.set_view_message_option = function(opts)
	if type(opts.view_messages_in) == "string" and M.view_message_options[opts.view_messages_in] then
		opts.view_messages_in = M.view_message_options[opts.view_messages_in]
	elseif type(opts.view_messages_in) == "function" then
		return
	else
		utils.log_error(
			vim.inspect(opts.view_messages_in)
			.. " is not a valid option for view_messages_in. Must be one of: "
			.. table.concat(vim.tbl_keys(M.view_message_options), ", ")
			.. ", or a function"
		)
	end
end


return M
