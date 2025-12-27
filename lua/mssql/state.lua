local M = {}

---@type table<integer, boolean>
local ready_clients = {}

-- Store the latest configuration here so closures always see the current version
---@type MssqlConfig
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

---@param client_id integer
M.set_client_ready = function(client_id)
	ready_clients[client_id] = true
end

---@param client_id integer
---@return boolean success
M.is_client_ready = function(client_id)
	return ready_clients[client_id] == true
end

---@return MssqlConfig?
M.get_config = function()
	return current_config or {}
end

---@param opts? MssqlConfig
M.set_config = function(opts)
	current_config = opts or {}
end

---@param bufnr? integer
---@return MssqlQueryManager?
M.get_query_manager = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
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

---TESTING ONLY: Resets ALL internal module state.
---Use in teardown/after_each block of specs to ensure isolation.
M._reset_all_state = function()
	event_listeners = {}
	named_listeners = {}
	attach_handlers = {}
	query_managers = {}
	ready_clients = {}
end

return M
