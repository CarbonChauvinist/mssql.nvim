local qmm = require("mssql.query_manager")
local state = require("mssql.state")
local utils = require("mssql.utils")

--- Sanitizes nulllable completion item fields to prevent sorting and validation crashes.
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
local cleanup_group = vim.api.nvim_create_augroup("MssqlLspCleanup", { clear = true })

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

	require("mssql.find_object").delete_unused_cache(in_use_connections)
end

-- Helper to wrap handlers with routing logic
local function make_handler(method, core_logic)
	return function(err, result, ctx, config)
		if core_logic then
			core_logic(err, result, ctx, config)
		end
		-- broadcast to dynamic listeners
		state.emit_event(method, err, result, ctx)
	end
end

---@param method string
---@return function
local generic_event_router = function(method)
	return function(err, result, ctx, _config)
		state.emit_event(method, err, result, ctx)
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

		if ctx and ctx.client_id then
			require("mssql.state").set_client_ready(ctx.client_id)
		end

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

	["query/message"] = make_handler("query/message", function(_, result)
		if utils.is_empty(result) or utils.is_empty(result.message) or utils.is_empty(result.message.message) then
			return
		end
		state.get_config().view_messages_in(result.message.message, result.message.isError)
	end),

	["connection/connectionchanged"] = make_handler("connection/connectionchanged", function(_, result, _)
		if utils.is_empty(result) or utils.is_empty(result.ownerUri) then return end
		local bufnr = vim.iter(vim.api.nvim_list_bufs()):find(function(buf)
			return utils.lsp_file_uri(buf) == result.ownerUri
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
		local existing_client = vim.lsp.get_clients({ name = lsp_name, bufnr = bufnr })[1]
		if existing_client then return existing_client end

		local qm = state.get_query_manager(bufnr)
		if qm and qm.client then return qm.client end

		utils.defer_async(interval_ms)
	end

	utils.log_error("Timed out waiting for LSP to attach to buffer " .. bufnr)
	return nil
end
-- 	local existing_client = vim.lsp.get_clients({ name = lsp_name, bufnr = bufnr })[1]
-- 	-- if existing_client then return existing_client end
--
-- 	local qm = state.get_query_manager(bufnr)
-- 	if qm and qm.client then
-- 		return qm.client
-- 	end
--
-- 	local co = coroutine.running()
-- 	local resumed = false
--
-- 	local on_attach_handler = function(client)
-- 		if not resumed then
-- 			resumed = true
-- 			utils.try_resume(co, client)
-- 		end
-- 	end
--
-- 	state.add_attach_handler(bufnr, on_attach_handler)
--
-- 	if timeout then
-- 		vim.defer_fn(function()
-- 			if not resumed then
-- 				resumed = true
-- 				utils.log_error("Waiting for the lsp to attach to buffer " .. bufnr .. " timed out")
-- 				-- handler will be cleaned up next time on_attach fires
-- 				utils.try_resume(co, nil)
-- 			end
-- 		end, timeout)
-- 	end
-- 	return coroutine.yield()
-- end


M.enable = function()
	local opts = state.get_config() or {}
	local joinpath = vim.fs.joinpath
	local default_path = joinpath(opts and opts.data_dir, "sqltools/MicrosoftSqlToolsServiceLayer")

	if jit.os == "Windows" then
		default_path = default_path .. ".exe"
	end

	local config = {
		name = lsp_name,
		cmd = {
			opts.tools_file or default_path,
			"--enable-connection-pooling",
			"--enable-sql-authentication-provider",
			"--log-file",
			joinpath(opts.data_dir, "sqltools.log"),
			"--application-name",
			"neovim",
			"--data-path",
			joinpath(opts.data_dir, "sql-tools-data"),
		},
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
				local success, err = utils.reconnect_session(qm, "Session reloaded")
				if not success then utils.log_error(err) end
			end

			-- run waiting handlers
			local handlers = state.get_attach_handlers(bufnr)
			if handlers then
				for _, handler in ipairs(handlers) do
					pcall(handler, client)
				end
				state.clear_attach_handlers(bufnr)
			end

		  -- subscribe QM to events via the Router
		  qm = state.get_query_manager(bufnr)
		  if qm then
			local buffer_uri = utils.lsp_file_uri(bufnr)

			-- for query stats (elapsed time, rows affected from SELECT queries)
			local dispose_complete = state.on_event("query/complete", function(_, result, _)
					if not vim.api.nvim_buf_is_valid(bufnr) then return end
					if result and result.ownerUri == buffer_uri then
						qm:handle_query_complete(result)
					end
				end)

			-- DML rows affected query stats
			local dispose_message = state.on_event("query/message", function(_, result, _)
					if not vim.api.nvim_buf_is_valid(bufnr) then return end
					if result and result.ownerUri == buffer_uri then
						qm:handle_query_message(result)
					end
				end)

			-- handle cleanup on detach
			vim.api.nvim_create_autocmd("LspDetach", {
				buffer = bufnr,
				group = cleanup_group,
				callback = function(args)
					if args.data.client_id == client.id then
						if dispose_complete then dispose_complete() end
						if dispose_message then dispose_message() end
					end
				end
			})
		   end
		end,
	}

	if opts.lsp_settings then
		config.settings = { mssql = opts.lsp_settings }
	end

	vim.api.nvim_create_autocmd("FileType", {
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
