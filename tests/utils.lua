local utils = require("mssql.utils")
local mssql = require("mssql")

---@class tests.utils
local M = {}

M.defer_async = utils.defer_async

M.get_completion_items = function()
	-- Trigger <C-x><C-o> to invoke omnifunc
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("a<C-x><C-o>", true, false, true), "n", true)

	-- Completion results are async
	utils.defer_async(500)
	local items = vim.fn.complete_info({ "items" }).items or {}
	vim.cmd("stopinsert")
	return vim.iter(items)
		:map(function(item)
			return item.word or item.abbr
		end)
		:totable()
end

M.ui_select_fake = function(item)
	local original_select = vim.ui.select
	---@diagnostic disable-next-line: duplicate-set-field
	vim.ui.select = function(items, _, on_choice)
		vim.ui.select = original_select
		local index
		if type(item) == "string" then
			index = vim.fn.index(items, item) + 1
			if index == nil or index == 0 then
				error("You tried to choose " .. item .. "when prompted but this wasn't an option", 0)
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

-- Takes a list of functions that should be run inside a coroutine,
-- runs each one and waits for all of them to finish. Must be
-- run inside a coroutine
M.wait_for_all_async = function(async_functions)
	local finished_count = 0
	local co = coroutine.running()

	for _, f in ipairs(async_functions) do
		coroutine.resume(coroutine.create(function()
			f()
			finished_count = finished_count + 1
			if finished_count == #async_functions then
				coroutine.resume(co)
			end
		end))
	end
	coroutine.yield()
end

--- Checks if a value exists in a table
---@param tbl table The table to search.
---@param val any The value to find.
---@return boolean
M.table_contains = function(tbl, val)
	for _, item in ipairs(tbl) do
		if item == val then
			return true
		end
	end
	return false
end

--- Checks if any string in a list contains a pattern
---@param logs string[] A list of log strings.
---@param pattern string The string pattern to find.
---@return boolean
M.log_contains_pattern = function(logs, pattern)
	for _, log in ipairs(logs) do
		if string.find(log, pattern) then
			return true
		end
	end
	return false
end

--- Finds the first visible query results buffer
---@return integer? bufnr The buffer number, or nil if not found.
M.get_results_buffer = function()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			local bufname = vim.api.nvim_buf_get_name(buf)
			if bufname:match("results %d?%d?%-%d?%d?") then
				return buf
			end
		end
	end
	return nil
end

--- Gets the full text content of a buffer as a single string
---@param bufnr integer The buffer number.
---@return string
M.get_buffer_content = function(bufnr)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

--- Gets the current string from the mssql lualine component
---@return string
M.get_lualine_status = function()
	local lualine_component_func = require("mssql").lualine_component[1]
	if not lualine_component_func then
		error("Could not find lualine component function.")
	end
	return lualine_component_func()
end

--- Polls until the lualine status matches an expected pattern
---@param expected_pattern string The string pattern to wait for.
---@param timeout_ms? integer Total time to wait (default 5000ms).
M.wait_for_status = function(expected_pattern, timeout_ms)
	timeout_ms = timeout_ms or 5000
	local last_status = ""

	local success = vim.wait(timeout_ms, function()
		last_status = M.get_lualine_status() or ""
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

--- Calls mssql.setup and yields until its async callback is done
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

return M
