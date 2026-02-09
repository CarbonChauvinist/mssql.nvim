local utils = require("mssql.utils")
local mssql = require("mssql")

---@class tests.utils
local M = {}

---@type integer
local next_mock_client_id = 10000

local res_buf_pattern = "results %d?%d?%-%d?%d?.md$"

-- Simple aliases for convenience.
M.defer_async = utils.defer_async

M.wait_for_notification_async = utils.wait_for_notification_async

--- Finds the first visible query results buffer (for single results set queries).
---@return integer? bufnr The buffer number, or nil if not found.
local get_results_buffer = function()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			local bufname = vim.api.nvim_buf_get_name(buf)
			if bufname:match(res_buf_pattern) then
				return buf
			end
		end
	end
	return nil
end

--- Finds ALL visible query result buffers (for multiple result set queries).
---@return integer[] buffers Table containing buffer numbers, or empty table if none found.
local function get_all_result_buffers()
	local buffers = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			local bufname = vim.api.nvim_buf_get_name(buf)
			if bufname:match(res_buf_pattern) then
				table.insert(buffers, buf)
			end
		end
	end
	return buffers
end

--- Waits for a buffer to contain at least one line of text (non-empty).
---@param bufnr integer The buffer to check.
---@param opts? { timeout_ms: integer } Options table.
---@return boolean success True if content appeared.
local wait_for_buffer_content = function(bufnr, opts)
	opts = opts or {}
	local timeout_ms = opts.timeout_ms or 5000
	return M.poll(function()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		return #lines > 1 or (#lines == 1 and lines[1] ~= "")
	end, { timeout_ms = timeout_ms, interval_ms = 100 })
end

--- Calculates the visual display column of every '|' character in a string.
---@param str string String to be parsed.
---@return integer[] positions Visual indices of pipes.
local function get_pipe_visual_positions(str)
	local positions = {}
	local current_width = 0
	local pipe_byte = string.byte("|")

	for i = 1, vim.fn.strchars(str) do
		local char = vim.fn.strcharpart(str, i - 1, 1)

		if string.byte(char) == pipe_byte then
			table.insert(positions, current_width)
		end

		current_width = current_width + vim.fn.strdisplaywidth(char)
	end
	return positions
end

--- Gets the full text content of a buffer as a single string.
---@param bufnr integer The buffer number.
---@return string content The buffer content joined by newlines.
M.get_buffer_content = function(bufnr)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

--- Triggers completion and returns the list of visible completion items.
---@return string[] items List of completion words or abbreviations.
M.get_completion_items = function()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("a<C-x><C-o>", true, false, true), "n", true)

	-- Completion results are async
	utils.defer_async(100)
	local items = vim.fn.complete_info({ "items" }).items or {}
	vim.cmd("stopinsert")

	return vim.tbl_map(function(item)
		return item.word or item.abbr
	end, items)
end

--- Mocks vim.ui.select to automatically choose an item.
---@param item string|number The item label to select (string) or index (number).
M.ui_select_fake = function(item)
	local original_select = vim.ui.select
	---@diagnostic disable-next-line: duplicate-set-field
	vim.ui.select = function(items, _, on_choice)
		vim.ui.select = original_select
		local index

		if type(item) == "string" then
			local matched_item = nil

			for i, list_item in ipairs(items) do
				local match = false

				-- simple string match (e.g. database list: "master", "tempdb")
				if type(list_item) == "string" and list_item == item then
					match = true
				-- complex object match (e.g. finder list: { label="dbo.Car", ... })
				elseif type(list_item) == "table" and (
						list_item.label == item or
					    list_item.text == item or
					    list_item.name == item
					) then
						match = true
				end

				if match then
					index = i
					matched_item = list_item
					break
				end
			end

			-- if we found a table object, use that as the selection
			-- otherwise keep the original string (for simple lists)
			item = matched_item or item

			if not index or index == 0 then
				error("You tried to choose '" .. tostring(item) .. "' when prompted but this wasn't an option.", 0)
			end

		elseif type(item) == "number" then
			index = item
			if not items[index] then
				error("The index " .. index .. " is out of range in the items: " .. vim.inspect(items))
			end
			item = items[index]
		end

		vim.defer_fn(function()
			on_choice(item, index)
		end, 3000)
	end
end

--- Helper to generate JSON content dynamically for connections.json.
---@param opts? { target_db: string } Options table.
---@return string connection_json The formatted JSON string.
M.create_connection_json = function(opts)
	opts = opts or {}
	local db = opts.target_db or os.getenv("DbDatabase") or "master"
	return string.format(
			[[
{
  "TestConnection": {
    "server": "%s",
    "database": "%s",
    "authenticationType": "SqlLogin",
    "user": "%s",
    "password": "%s",
    "trustServerCertificate": true
  }
}
]],
			os.getenv("DbServer") or "localhost",
			db,
			os.getenv("DbUser") or "sa",
			os.getenv("DbPassword") or "password"
	)
end

--- Helper to overwrite the connections.json file.
--- Allows dynamically updating connections per unit test.
---@param content string JSON object string to write to connections.json.
M.write_connections_file = function(content)
	local data_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "mssql.nvim")
	local path = vim.fs.joinpath(data_dir, "connections.json")

	if vim.fn.isdirectory(data_dir) == 0 then
		vim.fn.mkdir(data_dir, "p")
	end

	local f = io.open(path, "w")
	if f then
		f:write(content)
		f:close()
	else
		error("Could not write connections file at " .. path)
	end
end

--- Wait for a results buffer to appear.
---@param opts { timeout_ms: integer } Timeout in milliseconds (default 5000).
---@return integer buf Buffer number of results buffer.
M.wait_for_results_buffer = function(opts)
	opts = opts or {}
	local timeout_ms = opts.timeout_ms or 5000
	local res_buf

	local success = M.poll(function()
		res_buf = get_results_buffer()
		return res_buf ~= nil
	end, { timeout_ms = timeout_ms, interval_ms = 100 })

	if not success then
		error(string.format("Timeout: Results buffer did not appear within %d seconds.", timeout_ms / 1000))
	end

	return res_buf
end

--- Waits for a specific number of result buffers to appear and return their contents.
---@param expected_count integer The number of result sets we expect.
---@param opts? { timeout_ms: integer }
---@return table<integer, string> results_map Map of { [bufnr] = "content" }
M.wait_for_multiple_result_buffers = function(expected_count, opts)
	opts = opts or {}
	local timeout = opts.timeout_ms or 10000
	local found_buffers = {}

	local attempts = 0
	local max_attempts = math.ceil(timeout / 100)

	while attempts < max_attempts do
		found_buffers = get_all_result_buffers()
		if #found_buffers >= expected_count then
			break
		end
		M.defer_async(100)
		attempts = attempts + 1
	end

	if #found_buffers < expected_count then
		error(string.format("Timeout: Expected %d result buffers, but found %d.", expected_count, #found_buffers))
	end

	local results_map = {}
	for _, buf in ipairs(found_buffers) do
		local ok = pcall(wait_for_buffer_content, buf, { timeout_ms = 2000 })
		if ok then
			results_map[buf] = M.get_buffer_content(buf)
		else
			results_map[buf] = "<EMPTY/TIMEOUT>"
		end
	end

	return results_map
end

--- Waits for intellisenseReady event, signals connection was successful.
---@param buf integer The buffer number to watch for the notification.
---@param client vim.lsp.Client The LSP client to watch.
---@param opts? { timeout_ms: integer } How long to wait (default 30000).
---@return any result The result payload from the notification.
M.wait_for_intellisenseReady = function(buf, client, opts)
	opts = opts or {}
	local timeout_ms = opts.timeout_ms or 30000
	timeout_ms = timeout_ms or 30000

	if require("mssql.state").is_client_ready(client.id) then
		return true
	end

	local result, err = utils.wait_for_notification_async(buf, client, "textDocument/intelliSenseReady", timeout_ms)
	if err then
		utils.log_error(err.message)
	end

	assert(result, "No result returned from textDocument/intelliSenseReady")
	if result.errorMessage then
		utils.log_error("Error returned from textDocument/intelliSenseReady: " .. result.errorMessage)
	end

	return result
end

--- Waits for QueryManager to report a "connected" state
---@param bufnr integer
---param opts? { timeout_ms: integer }
M.wait_for_connected = function(bufnr, opts)
	opts = opts or {}
	local timeout_ms = opts.timeout_ms or 5000
	local state = require("mssql.state")

	local success = M.poll(function()
		local qm = state.get_query_manager(bufnr)
		if not qm then return false end
		return qm:get_state() == qm.states.connected
	end, { timeout_ms = timeout_ms, interval_ms = 100 })

	if not success then
		local qm = state.get_query_manager(bufnr)
		if not qm then
			error("Timeout: QueryManager never attached to buffer " .. bufnr)
		else
			error("Timeout: QueryManage attached but stuck in state: " .. tostring(qm:get_state()))
		end
	end
end

--- Checks if any string in a list contains a substring pattern.
---@param logs string[] A list of log strings.
---@param pattern string The string pattern to find.
---@return boolean found True if pattern matches any log entry.
M.log_contains_pattern = function(logs, pattern)
	for _, log in ipairs(logs) do
		if string.find(log, pattern) then
			return true
		end
	end
	return false
end

--- Gets the current string from the mssql lualine component.
---@param bufnr? integer Optional buffer to get status for (defaults to current).
---@return string? status The status string or nil.
M.get_lualine_status = function(bufnr)
	if bufnr and not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local lualine_component_func = require("mssql").lualine_component[1]
	if not lualine_component_func then
		error("Could not find lualine component function.")
	end
	return lualine_component_func(bufnr)
end

--- Polls until the lualine status matches an expected pattern.
---@param expected_pattern string The string pattern to wait for.
---@param opts? { timeout_ms: integer, bufnr: integer } Options table (default timeout 5s)
M.wait_for_status = function(expected_pattern, opts)
	opts = opts or {}
	local timeout_ms = opts.timeout_ms or 5000
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local last_status = ""

	local success = vim.wait(timeout_ms, function()
		last_status = M.get_lualine_status(bufnr) or ""
		return last_status:find(expected_pattern) ~= nil
	end, 10)

	if not success then
		utils.log_error(string.format(
		"Timeout waiting for status '%s'. Last status: '%s'",
		expected_pattern,
		last_status
	))
	end
end

--- Calls mssql.setup and yields until its async callback is done.
---@param opts table The options table to pass to setup().
M.setup_mssql_async = function(opts)
	local co = coroutine.running()
	mssql.setup(opts, function()
		vim.schedule(function()
		coroutine.resume(co)
		end)
	end)
	coroutine.yield()
end

--- Safely removes results buffer.
---@param results_buffer integer The results buffer to remove.
M.cleanup_results_buffer = function(results_buffer)
	if results_buffer and vim.api.nvim_buf_is_valid(results_buffer) then
		vim.api.nvim_buf_delete(results_buffer, {force = true})
	end
end

--- Cleanup helper for multiple buffers.
---@param results_map table The map returned from wait_for_multiple_results.
M.cleanup_multiple_buffers = function(results_map)
	for buf, _ in pairs(results_map) do
		M.cleanup_results_buffer(buf)
	end
end

--- Create a new SQL buffer and returns it with a cleanup function.
---@param opts? { buffer_name: string } Options table.
---@return integer bufnr The new, active buffer number.
---@return function cleanup A function to delete a buffer.
M.create_sql_buffer = function(opts)
	opts = opts or {}
	local buf = vim.api.nvim_create_buf(true, false)
	local name = opts.buffer_name or ("test-buffer-" .. buf .. ".sql")
	local full_path = vim.fs.joinpath(vim.fn.getcwd(), name)
	vim.api.nvim_buf_set_name(buf, full_path)
	vim.api.nvim_set_option_value("filetype", "sql", {buf = buf})
	vim.api.nvim_win_set_buf(0, buf)

	local cleanup = function()
		if buf and vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, {force = true})
		end
	end

	return buf, cleanup
end

--- Waits for the mssql_ls client to attach to a specific buffer.
---@param buf? integer The buffer number to check.
---@param opts? { timeout_ms: integer } Options table (default 15s).
---@return vim.lsp.Client client The attached LSP client.
M.wait_for_lsp_attach = function(buf, opts)
	opts = opts or {}
	if not buf or buf == 0 then
		buf = vim.api.nvim_get_current_buf()
	end

	local timeout_ms = opts.timeout_ms or 15000
	local final_client
	local last_debug_state = "No attempt made"

	utils.log_info(string.format("Waiting for LSP to attach to buffer %d...", buf))

	local success = M.poll(function()
		if not vim.api.nvim_buf_is_valid(buf) then
			last_debug_state = "Buffer " .. buf .. " became invalid"
			return false
		end

		local clients = vim.lsp.get_clients({ name = "mssql_ls", bufnr = buf })

		if #clients == 0 then
			last_debug_state = "No clients found for buffer"
			return false
		end

		for _, client in	ipairs(clients) do
			if not client:is_stopped() then
				final_client = client
				return true
			else
				last_debug_state = string.format("Found client %d but it was STOPPED", client.id)
			end
		end

		return false
	end, { timeout_ms = timeout_ms, interval_ms = 100 })

	if not success then
		error(string.format(
			"Timeout waiting for LSP on buf %d. Reason: %s",
			buf,
			last_debug_state
		))
	end

	return final_client
end

--- Creates a SQL buffer AND waits for the LSP.
---@return integer bufnr The new, active buffer number.
---@return vim.lsp.Client client The attached LSP client.
---@return function cleanup A function to delete the buffer.
M.create_lsp_buffer_async = function()
	local buf, cleanup_buffer = M.create_sql_buffer()
	local client = M.wait_for_lsp_attach(buf)

	return buf, client, cleanup_buffer
end

--- Porcelain to scaffold buffers, connections, and logic for tests
---@param opts? { target_db: string } The database to connect to directly (e.g. "TestDbB")
---@return integer buf The new, active buffer number.
---@return vim.lsp.Client client The attached LSP client.
---@return MssqlQueryManager qm The query manager.
---@return function cleanup A function to delete the buffer.
M.test_scaffold = function(opts)
	opts = opts or {}
	local target_db = opts.target_db or "master"
	local conn_json = M.create_connection_json({ target_db = target_db })
	M.write_connections_file(conn_json)

	local buf, client, cleanup = M.create_lsp_buffer_async()

	M.ui_select_fake("TestConnection")
	mssql.connect(buf)
	M.wait_for_intellisenseReady(buf, client)
	M.wait_for_connected(buf)

	---@module "query_manager"
	---@type MssqlQueryManager?
	local qm = mssql.get_query_manager(buf)
	if not qm then
		error("Query manager not found on buffer.")
	end

	return buf, client, qm, cleanup
end

--- Porcelain to get results buffer, wait for results and return.
---@param opts? { res_buf: integer?, timeout_ms: integer?} Options table.
---@return integer? buf Results buffer.
---@return boolean status Whether call was successful.
---@return string? contents Results buffer contents.
M.res_buf_catcher = function(opts)
	opts = opts or {}
	local timeout_ms = opts.timeout_ms or 5000
	local res_buf = opts.res_buf or M.wait_for_results_buffer({ timeout_ms = timeout_ms })
	local results
	local status, _ = pcall(wait_for_buffer_content, res_buf, { timeout_ms = timeout_ms })
	if status then
		results = M.get_buffer_content(res_buf)
	end
	return res_buf, status, results
end

--- Waits for a specific string to appear in the find_object cache.
---@param item_label string The label to search for (e.g. "dbo.Car")
---@param opts? { type: string, timeout: number, debug: boolean } Options table.
---@return boolean status? True if item_label is found in cache.
M.wait_for_cache_content = function(item_label, opts)
	opts = opts or {}
	local timeout_ms = opts.timeout or 30000

	local cache_info = {
		size = 0,
		items = {},
		seen_types = {}
	}

	local function check_cache()
		local find_object = require("mssql.find_object")
		local global_cache = find_object.get_cache()

		if not global_cache then
			return false
		end

		for _, connection_data in pairs(global_cache) do
			local cache = connection_data.cache
			if cache then
				cache_info.size = #cache
				cache_info.items = cache

				for _, item in ipairs(cache) do
					local name_match = item.label == item_label or (item.text and item.text:find(item_label, 1, true))

					if name_match then
						local item_type = item.objectType or item.nodeType

						if not opts.type or item_type == opts.type then
							return true
						end

						if opts.debug then
							table.insert(cache_info.seen_types, item_type or "nil")
						end
					end
				end
			end
		end
		return false
	end

	local success = M.poll(check_cache, { timeout_ms = timeout_ms, interval = 100 })

	if not success then
		local debug_dump = {}

		local msg = {
			string.format("Timeout waiting for '%s' in cache", item_label),
			string.format("Type: %s", opts.type or "Any"),
			string.format("Cache size: %d", cache_info.size),
		}

		if opts.debug then
			for i = 1, math.min(20, #cache_info.items) do
				local item = cache_info.items[i]
				local type_str = item.objectType or item.nodeType or "?"
				table.insert(debug_dump, string.format("%s [%s]", item.label, type_str))
			end
			table.insert(msg, string.format("First %d items: %s", #debug_dump, table.concat(debug_dump, ", ")))
		end

		if #cache_info.seen_types > 0 then
			table.insert(msg, "Wrong-type matches: " .. table.concat(cache_info.seen_types, ", "))
		end

		error(table.concat(msg, ". "))
	end

	return true
end

--- Safely deletes a given buffer
---@param buf integer Buffer to delete.
---@param opts table? Options passed to nvim_buf_delete.
---@return boolean success True if deleted successfully.
M.safe_buf_delete = function(buf, opts)
	opts = opts or {}

	if not vim.api.nvim_buf_is_valid(buf) then
		vim.notify("Cannot delete invalid buffer: " .. tostring(buf), vim.log.levels.WARN)
		return false
	end

	local success, result = pcall(vim.api.nvim_buf_delete, buf, opts)
	if not success then
		vim.notify("Failed to delete buffer: " .. tostring(result), vim.log.levels.ERROR)
		return false
	end

	return true
end

--- Polling helper that sets up the buffer and waits for a specific completion.
---@param buf integer The buffer to type into.
---@param expected_label string The item we expect to see (e.g. "ColumnName").
---@param opts? { text: string, cursor: integer[], timeout: number} Options table.
M.wait_for_completion_item = function(buf, expected_label, opts)
	opts = opts or {}
	local timeout = opts.timeout or 15000

	-- ensure the context
	if not vim.api.nvim_buf_is_valid(buf) then
		error("Cannot wait for completion: Buffer " .. tostring(buf) .. " is invalid/deleted.")
	end
	local ok = pcall(vim.api.nvim_win_set_buf, 0, buf)
	if not ok then
		error("Failed to switch to buffer " .. tostring(buf) .. ". It may have been deleted.")
	end

	if opts.text then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { opts.text })
		if not opts.cursor then
			vim.api.nvim_win_set_cursor(0, { 1, #opts.text})
		end
	end

	if opts.cursor then
		if #opts.cursor ~= 2 then
			error("opts.cursor must be a {row, col} tuple")
		end
		if opts.text then M.defer_async(50) end
		vim.api.nvim_win_set_cursor(0, opts.cursor)
	end

	local last_items = {}

	-- polling loop
	local function check_completions()
		if not vim.api.nvim_buf_is_valid(buf) then return false end
		local items = M.get_completion_items()
		if not items then return false end
		last_items = items
		return vim.tbl_contains(items, expected_label)
	end

	local attempts = 0
	local max_attempts = math.ceil(timeout / 500) -- poll every 500ms

	while attempts < max_attempts do
		if check_completions() then return end

		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-e>", true, false, true), "n", true)
		M.defer_async(500)
		attempts = attempts + 1
	end

	error(string.format(
		"Timeout waiting for '%s'.\nContext: %s\nFound %d items, including: %s",
		expected_label,
		opts.text and ("Input: '" .. opts.text) or ("Cursor: " .. vim.inspect(opts.cursor or "Current")),
		#last_items,
		table.concat(vim.list_slice(last_items, 1, math.min(10, #last_items)), ", ")
	))
end

--- Assertion: Checks that all lines in list have '|' characters
--- at the exact same visual column positions.
---@param lines string[] List of strings to check.
M.assert_visual_alignment = function(lines)
	-- filter out separator lines or empty lines
	local data_rows = vim.tbl_filter(function(line)
		return line:find("|") ~= nil and line:find("[^%-%|%s]") ~= nil
	end, lines)

	if #data_rows < 2 then return end

	local reference_positions = get_pipe_visual_positions(data_rows[1])

	for i, line in ipairs(data_rows) do
		local positions = get_pipe_visual_positions(line)
		if not vim.deep_equal(reference_positions, positions) then
			error(string.format(
				"Visual alignment failed on line %d.\nExpected pipes at: %s\nActual pipes at:    %s\nContent: %s",
				i,
				vim.inspect(reference_positions),
				vim.inspect(positions),
				line
			))
		end
	end
end

--- Runs a function within a mocked environment for logging, input, and LSP calls.
---@param mocks { input_value: string?, client_response: table?, client_error: table? } Mock data configuration.
---@param func function The test function to run.
---@return table captures { logs: string[], cmd: string[], requests: table[] }
M.run_with_mocks = function(mocks, func)
	local captures = { logs = {}, cmds = {}, requests = {} }

	local orig_input = vim.fn.input
	local orig_info = utils.log_info
	local orig_error = utils.log_error
	local orig_cmd = vim.cmd
	local orig_get_client = utils.get_lsp_client

	---@diagnostic disable: duplicate-set-field
	vim.fn.input = function() return mocks.input_value end
	utils.log_info = function(msg) table.insert(captures.logs, "INFO: " .. msg) end
	utils.log_error = function(msg) table.insert(captures.logs, "ERROR: " .. msg) end
	vim.cmd = function(cmd) table.insert(captures.cmds, cmd) end

	next_mock_client_id = next_mock_client_id + 1

	local mock_client = {
		id = next_mock_client_id,
		request = function(_, method, params, cb)
			table.insert(captures.requests, { method = method, params = params })
			vim.schedule(function() cb(mocks.client_error, mocks.client_response or { success = true }) end)
		end,
	}
	utils.get_lsp_client = function() return mock_client end
	---@diagnostic enable: duplicate-set-field

	func()

	vim.fn.input = orig_input
	utils.log_info = orig_info
	utils.log_error = orig_error
	vim.cmd = orig_cmd
	utils.get_lsp_client = orig_get_client

	return captures
end

--- Generic polling function that waits for a predicate to return true. (Defaults to 10s/250ms timeout/interval).
---@param predicate fun(): boolean The function to check. Should return true when condition is met.
---@param opts? { timeout_ms: integer, interval_ms: integer }
---@return boolean success True if the predicate returned before the timeout.
M.poll = function(predicate, opts)
	opts = opts or {}
	local timeout = opts.timeout_ms or 10000
	local interval = opts.interval_ms or 250
	local max_attempts = math.ceil(timeout / interval)
	local attempts = 0

	while attempts < max_attempts do
		if predicate() then
			return true
		end
		M.defer_async(interval)
		attempts = attempts + 1
	end

	return false
end

return M
