local default_opts = require("mssql.default_opts")

local M = {}

-- Store the latest configuration here so closures always see the current version
---@type MssqlOptions
local current_config = {}

---@type table<integer, MssqlQueryManager>
local query_managers = {}

---@type table<string, boolean>
local scripting_uris = {}

-- Coroutine lifecycle management
---@type table<string, { co: thread, client_id: integer? }>
local waiting_coroutines = {}

-- Store the last query selection range for rerun functionality
---@type {start: number[], end_: number[], buf: integer}?
local last_query_range = nil

-- Store extmark IDs of selection range instead of raw positions for rerun functionality
---@type {start: integer, end_: integer, buf: integer, start_ns: string, end_ns: string}?
local last_query_extmarks = nil

---@param bufnr integer
---@param method? string
---@return string
local create_waiting_cr_key = function(bufnr, method)
	method = method or "" --allow nil methods so can be used to generate keys when clearing in-flight coroutines for arbitrary buffers
	return string.format("%d|%s", bufnr, method:lower())
end

---@return MssqlOptions?
M.get_config = function()
	return current_config
end

---@param opts? MssqlOptions
M.set_config = function(opts)
	current_config = opts or {}
end

---@param bufnr? integer
---@return MssqlQueryManager?
M.get_query_manager = function(bufnr)
	if not bufnr or bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	return query_managers[bufnr]
end

---@return integer[]?
M.get_all_query_managers = function()
	return vim.tbl_keys(query_managers)
end

---@param bufnr integer
---@param qm MssqlQueryManager?
M.set_query_manager = function(bufnr, qm)
	if not bufnr then return end
	query_managers[bufnr] = qm
end

---@param bufnr integer
M.remove_query_manager = function(bufnr)
	if not bufnr then return end
	query_managers[bufnr] = nil

	-- purge all pending coroutine keys matching "bufnr|method"
	local prefix = create_waiting_cr_key(bufnr)
	for key in pairs(waiting_coroutines) do
		if key:find(prefix, 1, true) == 1 then
			waiting_coroutines[key] = nil
		end
	end
end

--- Registers a coroutine to wait for a specific LSP notification on a buffer.
---@param bufnr integer
---@param method string
---@param co thread
---@param client_id? integer
M.register_waiting_coroutine = function(bufnr, method, co, client_id)
	local key = create_waiting_cr_key(bufnr, method)
	waiting_coroutines[key] = { co = co, client_id = client_id }
end

---@param bufnr integer
---@param method string
---@return boolean
M.has_waiting_coroutine = function(bufnr, method)
	local key = create_waiting_cr_key(bufnr, method)
	return waiting_coroutines[key] ~= nil
end

---Clears a waiting coroutine reference (e.g. after a timeout or cancellation).
---@param bufnr integer
---@param method string
M.clear_waiting_coroutine = function(bufnr, method)
	local key = create_waiting_cr_key(bufnr, method)
	waiting_coroutines[key] = nil
end

---Resumes any coroutine waiting for the notification.
---@param bufnr integer
---@param method string
---@param result any
---@param err any
---@param client_id? integer
M.resume_waiting_coroutine = function(bufnr, method, result, err, client_id)
	method = method:lower()
	local key = create_waiting_cr_key(bufnr, method)
	local entry = waiting_coroutines[key]
	if entry then
		if client_id and entry.client_id and entry.client_id ~= client_id then
			return
		end
		waiting_coroutines[key] = nil
		local co = entry.co
		if coroutine.status(co) == "suspended" then
			local ok, errmsg = coroutine.resume(co, result, err)
			if not ok then
				vim.notify(tostring(errmsg), vim.log.levels.ERROR)
			end
		end
	end
end

---@param range {start: number[], end_: number[], buf: integer}
M.set_last_query_range = function(range)
	last_query_range = range
end

---@return {start: number[], end_: number[], buf: integer}?
M.get_last_query_range = function()
	return last_query_range
end

---Clears the last query range (useful when buffer is closed or after certain operations)
M.clear_last_query_range = function()
	last_query_range = nil
end

---Checks if the last query range is still valid
---@return boolean
M.is_last_query_range_valid = function()
	if not last_query_range then
		return false
	end
	if not vim.api.nvim_buf_is_valid(last_query_range.buf) then
		M.clear_last_query_range()
		return false
	end
	return true
end

---Checks if the last query range is still valid
---@return boolean
M.is_last_query_extmarks_valid = function()
	if not last_query_extmarks then
		return false
	end
	if not vim.api.nvim_buf_is_valid(last_query_extmarks.buf) then
		M.clear_last_query_extmarks()
		return false
	end
	return true
end

---@param bufnr integer
---@param start_pos number[] position from getpos()
---@param end_pos number[] position from getpos()
M.set_last_query_range_as_extmarks = function(bufnr, start_pos, end_pos)
	M.clear_last_query_extmarks()

	local start_line = start_pos[2] - 1
	local start_col = start_pos[3] - 1
	local end_line = end_pos[2] - 1
	local end_col = end_pos[3] - 1

	-- Cap start_col and end_col to actual line length in bytes to avoid out-of-range-errors
	local start_line_content = vim.api.nvim_buf_get_lines(bufnr, start_line, start_line + 1, false)[1] or ""
	local start_line_len = string.len(start_line_content)
	start_col = math.max(0, math.min(start_col, start_line_len))

	local end_line_content = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1] or ""
	local end_line_len = string.len(end_line_content)
	end_col = math.max(0, math.min(end_col, end_line_len))

	local start_ns = vim.api.nvim_create_namespace("mssql_last_query_start")
	local end_ns = vim.api.nvim_create_namespace("mssql_last_query_end")
	local start_id = vim.api.nvim_buf_set_extmark(bufnr, start_ns, start_line, start_col, {
	})

	local end_id = vim.api.nvim_buf_set_extmark(bufnr, end_ns, end_line, end_col, {
		right_gravity = false,
	})

	last_query_extmarks = {
		buf = bufnr,
		start_ns = start_ns,
		end_ns = end_ns,
		start_id = start_id,
		end_id = end_id,
	}
end


M.get_last_query_range_from_extmarks = function()
  if not last_query_extmarks then
	vim.notify("Don't have `last_query_extmarks`", vim.log.levels.ERROR)
    return nil
  end

  if not vim.api.nvim_buf_is_valid(last_query_extmarks.buf) then
	vim.notify("Don't have a valid buf in `last_query_extmarks`", vim.log.levels.ERROR)
    M.clear_last_query_extmarks()
    return nil
  end

  local start_pos = vim.api.nvim_buf_get_extmark_by_id(
    last_query_extmarks.buf,
    last_query_extmarks.start_ns,
    last_query_extmarks.start_id,
    { details = false }
  )

  local end_pos = vim.api.nvim_buf_get_extmark_by_id(
    last_query_extmarks.buf,
    last_query_extmarks.end_ns,
    last_query_extmarks.end_id,
    { details = false }
  )

  if not start_pos or #start_pos == 0 or not end_pos or #end_pos == 0 then
	vim.notify("Either `start_pos` or `end_pos` was not populated", vim.log.levels.ERROR)
    M.clear_last_query_extmarks()
    return nil
  end

  return {
    start = { last_query_extmarks.buf, start_pos[1] + 1, start_pos[2] + 1, 0 },
    end_ = { last_query_extmarks.buf, end_pos[1] + 1, end_pos[2] + 1, 0 },
    buf = last_query_extmarks.buf,
  }
end

M.clear_last_query_extmarks = function()
	if last_query_extmarks then
		pcall(vim.api.nvim_buf_del_extmark, last_query_extmarks.buf, last_query_extmarks.start_ns, last_query_extmarks.start_id)
		pcall(vim.api.nvim_buf_del_extmark, last_query_extmarks.buf, last_query_extmarks.end_ns, last_query_extmarks.end_id)
		last_query_extmarks = nil
	end
end

---TESTING ONLY: Resets ALL internal module state.
---Use in teardown/after_each block of specs to ensure isolation.
---@param opts? { force_all: boolean } If true resets all clients, otherwise retain active clients (defaults to false)
M._reset_all_state = function(opts)
	opts = opts or {}
	local force_all = opts.force_all or false
	waiting_coroutines = {}
	query_managers = {}
	scripting_uris = {}

	last_query_range = nil
	M.clear_last_query_extmarks()
end

M.mark_scripting_uri_connected = function(uri)
	scripting_uris[uri] = true
end

M.is_scripting_uri_connected = function(uri)
	return scripting_uris[uri] or false
end

return M
