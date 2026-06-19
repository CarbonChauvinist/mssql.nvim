local default_opts = require("mssql.default_opts")

local M = {}

---@type table<integer, boolean>
local ready_clients = {}

-- Store the latest configuration here so closures always see the current version
---@type MssqlOptions
local current_config = {}

---@type table<integer, MssqlQueryManager>
local query_managers = {}

---@type table<integer, function[]>
local attach_handlers = {}

-- Event Router Registry
-- Format: { ["query/complete"] = { <callback1>, <callback2> ... } }
---@type table<string, function[]?>
local event_listeners = {}

---@type table<string, function[]?>
local named_listeners = {}

-- Store the last query selection range for rerun functionality
---@type {start: number[], end_: number[], buf: integer}?
local last_query_range = nil

-- Store extmark IDs of selection range instead of raw positions for rerun functionality
---@type {start: integer, end_: integer, buf: integer}?
local last_query_extmarks = nil

---@param client_id integer
M.set_client_ready = function(client_id)
	ready_clients[client_id] = true
end

---@param client_id integer
---@return boolean success
M.is_client_ready = function(client_id)
	return ready_clients[client_id] == true
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
end

---@param bufnr? integer
---@return function[]
M.get_attach_handlers = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	return attach_handlers[bufnr] or nil
end

---Adds a handler (or list of handlers) to the buffer's wait list
---@param bufnr? integer
---@param handler function|function[]
---@return boolean? success
---@return string? msg
M.add_attach_handler = function(bufnr, handler)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if not attach_handlers[bufnr] then
		attach_handlers[bufnr] = {}
	end

	local handler_type = type(handler)
	if handler_type ~= "table" and handler_type ~= "function" then
		return false, "Attempted to add handler that was neither table nor function."
	end
	if handler_type == "table" then
		local handler_count = 0
		for _, h in ipairs(handler) do
			if type(h) == "function" then
				table.insert(attach_handlers[bufnr], h)
				handler_count = handler_count + 1
			end
		end
		if handler_count == 0 then
			return false, "No items in table were a function, no handlers added."
		end
	elseif type(handler) == "function" then
		table.insert(attach_handlers[bufnr], handler)
	end
	return true
end

---Clears handlers for a buffer (used after they have fired)
---@param bufnr integer
M.clear_attach_handlers = function(bufnr)
	attach_handlers[bufnr] = nil
end


---Registers a one-off listener for an LSP method.
---@param method string The LSP method name (e.g., "query/complete")
---@param callback function(err, result, ctx)
---@param group_id? string (Optional) Unique ID to prevent duplication
---@return function dispose Function to remove the listener
M.on_event = function(method, callback, group_id)
	method = method:lower()

	-- handle named listeners (idempotent)
	if group_id then
		if type(group_id) ~= "string" then
			error("group_id must be a string")
		end
		if not named_listeners[method] then named_listeners[method] = {} end
		named_listeners[method][group_id] = callback

		-- returns disposer for this specific ID
		return function()
			if named_listeners[method] then
				named_listeners[method][group_id] = nil
			end
		end
	end

	-- handle anon listeners
	if not event_listeners[method] then
		event_listeners[method] = {}
	end
	table.insert(event_listeners[method], callback)

	-- Return a dispose function to allow clean removal
	return function()
		local listeners = event_listeners[method]
		if not listeners then return end
		for i, cb in ipairs(listeners) do
			if cb == callback then
				table.remove(listeners, i)
				break
			end
		end
	end
end

---Emits an event to all registered listeners.
---@param method string
---@param err any
---@param result any
---@param ctx any
M.emit_event = function(method, err, result, ctx)
	method = method:lower()
	if event_listeners[method] then
		for _, cb in ipairs(event_listeners[method]) do
			pcall(cb, err, result, ctx)
		end
	end

	if named_listeners[method] then
		for _, cb in pairs(named_listeners[method]) do
			pcall(cb, err, result, ctx)
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
M._reset_all_state = function()
	event_listeners = {}
	named_listeners = {}
	attach_handlers = {}
	query_managers = {}
	ready_clients = {}
	last_query_range = nil
	M.clear_last_query_extmarks()
end

return M
