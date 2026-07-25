local qmm = require("mssql.query_manager")
local state = require("mssql.state")
local utils = require("mssql.utils")
local explorer = require("mssql.explorer")

--- Sanitizes nullable completion item fields to prevent sorting and validation crashes.
---
--- Converts `vim.NIL` values to standard Lua `nil` on sorting/display fields
--- (detail, documentation, sortText, filterText) inside completion items.
--- This prevents Neovim's built-in completion logic from throwing userdata comparison
--- or formatting exceptions on newer Neovim versions (~0.12+).
---
---@param result table|nil The LSP textDocument/completion response.
local function sanitize_completion_items(result)
	if not result or result == vim.NIL then return end
	local items = result.items or result
	if type(items) ~= "table" then return end

	for _, item in ipairs(items) do
		if type(item) == "table" then
			if item.detail == vim.NIL then item.detail = nil end
			if item.documentation == vim.NIL then item.documentation = nil end
			if item.sortText == vim.NIL then item.sortText = nil end
			if item.filterText == vim.NIL then item.filterText = nil end
		end
	end
end

local M = {
	-- sometimes two of these come at once, so hide for 1s
	hide_initellisense_ready = false
}
local lsp_name = "mssql_ls"

---Refreshes the object cache for all active connections
local function clean_cache()
	local in_use_connections = {}
	local active_managers = state.get_all_query_managers() or {}

	for _, bufnr in ipairs(active_managers) do
		local qm = state.get_query_manager(bufnr)
		if qm and qm:get_state() ~= qm.states.disconnected then
			local params = qm:get_connect_params()
			if params and params.connection and params.connection.options then
				table.insert(in_use_connections, params.connection.options)
			end
		end
	end

	explorer.delete_unused_cache(in_use_connections)
end

-- Helper to resolve the buffer number for notifications and requests
local function get_bufnr(result, ctx)
	if not utils.is_empty(result) and type(result) == "table" and not utils.is_empty(result.ownerUri) then
		local bufnr = utils.get_bufnr_from_uri(result.ownerUri)
		if bufnr then return bufnr end
	end
	if ctx and ctx.bufnr and ctx.bufnr ~= 0 then
		return ctx.bufnr
	end
	return 0
end

-- Helper to wrap handlers with routing logic
local function make_handler(method, core_logic)
	return function(err, result, ctx, config)
		if core_logic then
			core_logic(err, result, ctx, config)
		end

		local bufnr = get_bufnr(result, ctx)
		local client_id = ctx and ctx.client_id
		state.resume_waiting_coroutine(bufnr, method, result, err, client_id)
	end
end

---@param method string
---@return function
local generic_event_router = function(method)
	return function(err, result, ctx, _config)
		local bufnr = get_bufnr(result, ctx)
		local client_id = ctx and ctx.client_id
		state.resume_waiting_coroutine(bufnr, method, result, err, client_id)
	end
end

local customized_handlers = {
	["textdocument/completion"] = make_handler("textdocument/completion", function(err, result, ctx, config)
		sanitize_completion_items(result)
		vim.lsp.handlers["textDocument/completion"](err, result, ctx, config)
	end),

	["textdocument/intellisenseready"] = make_handler("textdocument/intellisenseready", function(err, result, ctx)
		if err then
			utils.log_error("Could not start intellisense: " .. vim.inspect(err))
		else
			if not M.hide_intellisense_ready then
				M.hide_intellisense_ready = true
				utils.log_info("Intellisense ready")
				vim.defer_fn(function()
					M.hide_intellisense_ready = false
				end, 1000)
			end
		end

		local bufnr = get_bufnr(result, ctx)
		local qm = state.get_query_manager(bufnr)
		if qm then qm:set_intellisense_ready(true) end

		return result, err
	end),

	["query/batchstart"] = make_handler("query/batchstart", function(_, result)
		if utils.is_empty(result) or utils.is_empty(result.batchSummary) or utils.is_empty(result.batchSummary.selection) then
			return
		end
		local selection = result.batchSummary.selection
		local start_line = (selection.startLine or 0) + 1
		local _batch_id = (result.batchSummary.id or 0) + 1
		local msg = string.format("Started executing query at Line %d", start_line)
		local config = state.get_config()
		if config and config.view_messages_in then
			config.view_messages_in(msg, false)
		end
	end),

	["query/message"] = make_handler("query/message", function(_, result, ctx)
		if utils.is_empty(result) or utils.is_empty(result.message) or utils.is_empty(result.message.message) then
			return
		end
		state.get_config().view_messages_in(result.message.message, result.message.isError)

		local bufnr = ctx and ctx.bufnr
		if result and result.ownerUri then
			bufnr = utils.get_bufnr_from_uri(result.ownerUri) or bufnr
		end
		if bufnr then
			local qm = state.get_query_manager(bufnr)
			if qm then
				qm:handle_query_message(result)
			end
		end
	end),

	["query/complete"] = make_handler("query/complete", function(_, result, ctx)
		local bufnr = ctx and ctx.bufnr
		if result and result.ownerUri then
			bufnr = utils.get_bufnr_from_uri(result.ownerUri) or bufnr
		end
		if bufnr then
			local qm = state.get_query_manager(bufnr)
			if qm then
				qm:handle_query_complete(result)
			end
		end
	end),

	["objectexplorer/expandcompleted"] = make_handler("objectexplorer/expandcompleted", function(err, result, ctx)
		explorer.handle_expand_completed(err, result, ctx)
	end),

	["objectexplorer/sessioncreated"] = make_handler("objectexplorer/sessioncreated", function(err, result, ctx)
		if result and not utils.is_empty(result.sessionId) then
			if not state.has_waiting_coroutine(0, "objectexplorer/sessioncreated") then
				local client_id = ctx and ctx.client_id
				local client = client_id and vim.lsp.get_client_by_id(client_id)
				if client then
					pcall(function() client:request("objectexplorer/closeSession", { sessionId = result.sessionId }) end)
				end
			end
		end
	end),

	["connection/connectionchanged"] = make_handler("connection/connectionchanged", function(_, result, _)
		if utils.is_empty(result) or utils.is_empty(result.ownerUri) then return end
		local bufnr = vim.iter(vim.api.nvim_list_bufs()):find(function(buf)
			return vim.uri_from_bufnr(buf) == result.ownerUri
		end)

		if not bufnr then return end
		local qm = state.get_query_manager(bufnr)
		if utils.is_empty(result) or utils.is_empty(result.connection) or not qm then return end

		coroutine.resume(coroutine.create(function()
			qm:connectionchanged_async(result)
		end))
		clean_cache()
	end),
}

setmetatable(customized_handlers, {
	__index = function(t, method)
		local lower_key = method:lower()
		local handler = rawget(t, lower_key)
		if handler then return handler end

		local is_mssql_method = method:match("^query/")
			or method:match("^[Cc]onnection/")
			or method:match("^[Oo]bject[Ee]xplorer/")
			or method:match("^[Ss]cripting/")
		if is_mssql_method then
			return generic_event_router(method)
		end
	end
})

M.make_handler = make_handler
M.clean_cache = clean_cache


---Waits for the lsp to attach to the given buffer, with optional timeout
---Must be run inside a coroutine
---@param bufnr integer
---@param timeout_ms? integer
---@return vim.lsp.Client?
M.wait_for_attach = function(bufnr, timeout_ms)
	timeout_ms = timeout_ms or 10000
	local start_time = vim.loop.now()
	local interval_ms = 50

	while (vim.loop.now() - start_time) < timeout_ms do
		local clients = vim.lsp.get_clients({ name = lsp_name, bufnr = bufnr })
		for _, c in ipairs(clients) do
			if not c:is_stopped() and not c._is_stopping then
				return c
			end
		end

		local qm = state.get_query_manager(bufnr)
		if qm and qm.client
			and not qm.client:is_stopped()
			and not qm.client._is_stopping
		then
			return qm.client
		end

		utils.defer_async(interval_ms)
	end

	utils.log_error("Timed out waiting for LSP to attach to buffer " .. bufnr)
	return nil
end


M.enable = function()
	local opts = state.get_config() or {}
	local joinpath = vim.fs.joinpath
	local default_path = joinpath(opts and opts.data_dir, "sqltools/MicrosoftSqlToolsServiceLayer")

	if jit.os == "Windows" then
		default_path = default_path .. ".exe"
	end

	local config = {
		name = lsp_name,
		cmd = (function()
			local cmd = {
				opts.tools_file or default_path,
				"--enable-sql-authentication-provider",
				"--log-file",
				joinpath(opts.data_dir, "sqltools.log"),
				"--application-name",
				"neovim",
				"--data-path",
				joinpath(opts.data_dir, "sql-tools-data"),
			}
			if opts.enable_connection_pooling then
				table.insert(cmd, 2, "--enable-connection-pooling")
			end
			return cmd
		end)(),
		filetypes = { "sql" },
		handlers = customized_handlers,

		on_attach = function(client, bufnr)

			if not client._request_wrapped then
				client._request_wrapped = true
				local original_request = client.request
				client.request = function(self, method, params, handler, bufnr_arg)
					if method == "textDocument/completion" and handler then
						local original_handler = handler
						handler = function(err, result, ctx, config)
							sanitize_completion_items(result)
							original_handler(err, result, ctx, config)
						end
					end
					return original_request(self, method, params, handler, bufnr_arg)
				end
			end

			local qm = state.get_query_manager(bufnr)
			local current_opts = state.get_config() or {}

			if not qm then
				local success, new_qm = pcall(qmm.new, bufnr, client, current_opts)
				if success then
					qm = new_qm
					state.set_query_manager(bufnr, qm)
				else
					utils.log_error("Failed to create QueryManager: " .. tostring(new_qm))
					return
				end
			else
				-- existing buffer reloaded (i.e. ':edit')
				qm.client = client
				local params = qm:get_connect_params()
				if params and params.connection and params.connection.options then
					local success, err = utils.reconnect_session(qm, "Session reloaded")
					if not success then utils.log_error(err) end
				end
			end
		end,
	}

	if opts.lsp_settings then
		config.settings = { mssql = opts.lsp_settings }
	end

	local lsp_group = vim.api.nvim_create_augroup("MSSQLLsp", { clear = true })
	vim.api.nvim_create_autocmd("FileType", {
		group = lsp_group,
		pattern = "sql",
		callback = function()
			vim.lsp.start(config)
		end,
	})

	if vim.bo.filetype == "sql" then
		vim.lsp.start(config)
	end

end

return M
