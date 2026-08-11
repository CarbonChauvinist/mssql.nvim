local utils = require("mssql.utils")
local state = require("mssql.state")
local cmds = require("mssql.commands")
local ui = require("mssql.ui")
local lsp = require("mssql.lsp")
local interface = require("mssql.interface")
local default_opts = require("mssql.default_opts")
local downloader = require("mssql.tools_downloader")
local results = require("mssql.results")
local autocmds = require("mssql.autocmds")
local explorer = require("mssql.explorer")
local query_manager_module = require("mssql.query_manager")

local joinpath = vim.fs.joinpath
local M = {}

-- Helper to ensure directory exists
local function make_directory(path)
	if vim.fn.isdirectory(path) == 0 then
		vim.fn.mkdir(path, "p")
	end
end

---@return MssqlOptions? conf
local function get_config_or_warn()
	local conf = state.get_config()
	if not conf then
		utils.log_error("MSSQL plugin not initialized. Please call require('mssql').setup({}) first.")
		return nil
	end
	return conf
end

---Normalizes buffer, validates plugin config, retrieves QM, and checks state.
---@param bufnr? integer
---@param required_state? MssqlQueryManagerState
---@return MssqlOptions? config
---@return MssqlQueryManager? qm
---@return integer bufnr
local resolve_session = function(bufnr, required_state)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local conf = get_config_or_warn()
	if not conf then
		return nil, nil, bufnr
	end

	local qm = state.get_query_manager(bufnr)
	if not qm then
		utils.log_error("No mssql lsp is attached. Create a new query or open an existing one.")
		return conf, nil, bufnr
	end

	if required_state and qm:get_state() ~= required_state then
		utils.log_error("Must be " .. required_state .. ". Currently: " .. qm:get_state())
		return conf, qm, bufnr
	end

	return conf, qm, bufnr
end

-- Asynchronous setup logic (downloading tools, etc.)
---@param user_opts? MssqlConfig
local function setup_async(user_opts)
	---@type MssqlOptions
	local opts = vim.tbl_deep_extend("keep", user_opts or {}, default_opts) --[[@as MssqlOptions]]

    -- ensure that we use user's custom icons if configured, but validate are only single character
    if opts.icons then
		for group_name, group_config in pairs(opts.icons) do
			if type(group_config) == "table" then
				for icon_label, icon in pairs(group_config) do
					if icon_label ~= "enabled" and type(icon) == "string" and vim.fn.strchars(icon) > 1 then
						utils.log_warn("Icon '" .. icon_label .. "' should be a single character, got: " .. icon .. ". Resetting to plugin default")
						if default_opts.icons[group_name] then
							opts.icons[group_name][icon_label] = default_opts.icons[group_name][icon_label]
						end
					end
				end
			end
		end
    end

	-- validate max_rows since now used for paginagtion
	if type(opts.max_rows) ~= "number" or opts.max_rows <= 0 then
		utils.log_info(string.format("Invalid max_rows value (%s). Defaulting to %d", tostring(opts.max_rows), default_opts.max_rows))
		opts.max_rows = default_opts.max_rows
	end

	opts.connections_file = opts.connections_file or joinpath(opts.data_dir, "connections.json")

	state.set_config(opts)
	ui.set_show_results_option(opts)
	ui.set_view_message_option(opts)
	make_directory(opts.data_dir)

	-- if the opts specify a tools file path, don't download.
	if opts.tools_file then
		local file = io.open(opts.tools_file, "r")
		if not file then
			error("No sql tools file found at " .. opts.tools_file, 0)
		end
		file:close()
	else
		local config_file = joinpath(opts.data_dir, "config.json")
		local config = utils.read_json_file(config_file)
		local download_url = downloader.get_tools_download_url()

		-- download if it's a first time setup or the last downloaded is old
		if config and (not config.last_downloaded_from or config.last_downloaded_from ~= download_url) then
			downloader.download_tools_async(download_url, opts.data_dir)
			config.last_downloaded_from = download_url
			utils.write_json_file(config_file, config)
		end
	end

	lsp.enable()
	autocmds.setup(opts)
end

M.new_query = utils.async(function()
		ui.new_query_async()
	end)

--- Prompts for a database to switch to that is on the currently connected server.
---@overload fun()
---@overload fun(callback: fun())
---@overload fun(bufnr: integer)
---@overload fun(bufnr: integer, callback: fun())
---@param bufnr? integer|fun() The buffer number, OR the callback if only one argument is passed.
---@param callback? fun() The callback to run after switching
M.switch_database = utils.async(function(bufnr, callback)
	if type(bufnr) == "function" then
		callback = bufnr
		bufnr = nil
	end

	local _, qm, buf = resolve_session(bufnr, query_manager_module.states.connected)
	if not qm then return end

	cmds.switch_database_async(buf)
	qm:initialise_explorer_cache_async({ is_background = true })
	explorer.clean_cache()
	if callback then callback() end
end)

--- Connect the current buffer (you'll be prompted to choose a connection).
---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.connect = utils.async(function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if vim.api.nvim_buf_get_name(bufnr) == "" and vim.api.nvim_get_option_value("ft", {buf = bufnr}) == "sql" then
		vim.api.nvim_buf_set_name(bufnr, "untitled-" .. bufnr .. ".sql")
		local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "mssql_ls" })
		for _, client in ipairs(clients) do
			client:stop()
		end
		vim.cmd.doautocmd({ args = { "FileType" } })
		_ = lsp.wait_for_attach(bufnr)
	end

	local curr_conf, qm, _ = resolve_session(bufnr)
	if not qm or not curr_conf then return end

	local active_clients = vim.lsp.get_clients({ bufnr = bufnr, name = "mssql_ls" })
	for _, c in ipairs(active_clients) do
		if not c:is_stopped() and not c._is_stopping then
			qm.client = c
			break
		end
	end

	if cmds.perform_connect_async(curr_conf, qm, bufnr) then
		qm:initialise_explorer_cache_async( { is_background = true })
	end
	explorer.clean_cache()
end)

M.edit_connections = function()
	local curr_conn = get_config_or_warn()
	if not curr_conn then return end
	utils.edit_connections(curr_conn)
end

--- Rebuilds the server-side Intellisense autocomplete cache
---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.refresh_intellisense = function(bufnr)
	local _, qm, buf = resolve_session(bufnr, query_manager_module.states.connected)
	if not qm then return end
	local client = qm:get_lsp_client()

	if qm:get_state() ~= qm.states.connected then
		utils.log_error("To refresh intellisense you must be connected. You are currently " .. qm:get_state())
		return
	end

	if client then
		qm:set_intellisense_ready(false)
	end

	local success, msg = pcall(function()
		---@diagnostic disable-next-line: param-type-mismatch
		client:notify("textDocument/rebuildIntelliSense", { ownerUri = vim.uri_from_bufnr(buf) })
	end)

	if not success then utils.log_error(msg)
	else
		utils.log_info("Refreshing IntelliSense cache...")
	end
end

--- Rebuilds the client-side Object Explorer search cache
---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.refresh_explorer_cache = function(bufnr)
	local _, qm = resolve_session(bufnr, query_manager_module.states.connected)
	if not qm then return end
	ui.set_caching_status(true)
	utils.request_redrawstatus()
	utils.log_info("Refreshing Object Explorer cache...")
	coroutine.resume(coroutine.create(function()
		local success = qm:initialise_explorer_cache_async({ force = true, is_background = false })
		ui.set_caching_status(false)
		utils.request_redrawstatus()
		if success then
			utils.log_info("Object Explorer cache refreshed")
		end
	end))
end

---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.disconnect = utils.async(function(bufnr)
	local _, qm = resolve_session(bufnr)
	if not qm then return end

	qm:disconnect_async()
	explorer.clean_cache()
end)

---@param opts? MssqlExecutionOptions
M.execute_query = utils.async(function(opts)
	opts = opts or {}
	local opts_bufnr = opts.bufnr and opts.bufnr or nil

	local curr_conf, qm, bufnr = resolve_session(opts_bufnr, query_manager_module.states.connected)
	if not qm or not curr_conf then return end

	ui.clear_message_buffer()
	local result, query, line, column, range

	if opts.current_statement then
		local cursor = vim.api.nvim_win_get_cursor(0)
		line = cursor[1] - 1
		column = cursor[2]
	elseif opts.rerun_last then
		if not state.is_last_query_extmarks_valid() then
			utils.log_error("No valid previous query selection found to rerun.")
			return
		end
		local last_range = state.get_last_query_range_from_extmarks()
		if not last_range then
			utils.log_error("No previous query range found.")
			return
		end

		local lines = vim.fn.getregion(last_range.start, last_range.end_, { mode = "v"})
		query = table.concat(lines, "\n")

		if not query or query == "" then
			utils.log_error("No text found in previous selection range.")
			return
		end

		range = { -- convert to 0-indexed from 1-indexed extmark positions
			start_line = last_range.start[1] - 1,
			start_col = last_range.start[2] - 1,
			end_line = last_range.end_[1] - 1,
			end_col = last_range.end_[2] - 1,
		}

		if opts.highlight == true then
			vim.fn.setpos("'<", last_range.start)
			vim.fn.setpos("'>", last_range.end_)
			vim.cmd.normal("gv")
		end
	elseif not opts.current_statement and not opts.rerun_last then
		query = utils.get_selected_text(bufnr)
		local mode = vim.api.nvim_get_mode().mode
		if mode:match("[vV]") or mode == "\22" then
			local p_start = vim.fn.get_pos("'<")
			local p_end = vim.fn.getpos("'>")
			range = {
				start_line = math.max(0, p_start[2] - 1),
				start_col = math.max(0, p_start[3] - 1),
				end_line = math.max(0, p_end[2] - 1),
				end_col = math.max(0, p_end[3] -1),
			}
		end
	end

	ui.clear_message_buffer()
	--- for rerun_last, send the extracted query text directly
	--- the extmark-derived range has inflated endColumn from
	--- linewise visual marks (col=MAXINT), which breaks executeDocumentSelection
	local exec_range = range
	if opts.rerun_last then exec_range = nil end
	result = qm:execute_async({ query = query, line = line, column = column, range = exec_range })
	if result then -- since cancelled query returns nil, have to check for nil before displaying
		results.display(curr_conf, result, opts)
	end
end)

---Executes the SQL statement under the cursor in the current buffer
---@param opts? MssqlExecutionOptions
M.execute_current_statement = utils.async(function(opts)
	opts = opts or {}
	opts.current_statement = true
	M.execute_query(opts)
end)

---Executes statement under cursor and renders scalar result as inline virtual text
---@param opts? MssqlExecutionOptions
M.execute_virtual_text = utils.async(function(opts)
	opts = opts or {}
	opts.virtual_text = true
	opts.current_statement = true
	M.execute_query(opts)
end)

M.clear_virtual_text = ui.clear_virtual_text

---Executes the last query selection from the current buffer using saved extmarks
---@param opts? MssqlExecutionOptions
M.execute_rerun_last = utils.async(function(opts)
	opts = opts or {}
	opts.rerun_last = true
	M.execute_query(opts)
end)

---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.cancel_query = utils.async(function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local qm = state.get_query_manager(bufnr)
	if qm then
		qm:cancel_async()
	end
end)

---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.save_query_results = utils.async(function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local result_info = vim.b[bufnr].query_result_info
	if not result_info then
		utils.log_error("Go to a query result buffer to save results")
		return
	end

	cmds.save_query_results_async(result_info)
end)

---@param opts? FindObjectOpts
M.find_object = utils.async(function(opts)
	opts = opts or {}
	local scope = utils.normalize_findobject_scope(opts.scope)
	local object_type = opts.object_type
	local callback = opts.callback

	local curr_conf, qm, _bufnr = resolve_session(opts.bufnr, query_manager_module.states.connected)
	if not qm or not curr_conf then return end

	if qm:is_refreshing() then
		ui.set_caching_status(true)
		utils.request_redrawstatus()
		utils.log_error("Still caching. Try again in a few seconds...")
		return
	end

	ui.set_caching_status(false)
	utils.request_redrawstatus()

	-- explicitly initialise cache for "database" scope
	-- this ensures if we just switched databases we build a new cache
	-- instead of showing an empty picker
	ui.set_caching_status(true)
	utils.request_redrawstatus()

	local success = qm:initialise_explorer_cache_async({ scope = scope, is_background = false })

	ui.set_caching_status(false)
	utils.request_redrawstatus()

	if not success then return end

	local item = qm:find_async({ scope = scope, object_type = object_type })
	if not item then return end

	local target_buf = ui.insert_query_into_buffer(item.script, item.label)
	if target_buf == 0 then target_buf = vim.api.nvim_get_current_buf() end

	qm = state.get_query_manager(target_buf)
	if not qm then return end

	if curr_conf.execute_generated_select_statements and item.select then
		ui.clear_message_buffer()
		local result, err = qm:execute_async({ query = item.script })

		if result then
			results.display(curr_conf, result)
		elseif err then
			utils.log_error("Failed to execute generated SELECT: " .. tostring(err))
		end
	end

	if callback then callback() end
end)

M.lualine_component = ui.lualine_component

M.set_keymaps = function(prefix)
	interface.set_keymaps(prefix, M)
end

--- Setup the plugin.
---@param opts MssqlConfig? User configuration options
---@param callback function? Optional callback to run after setup
M.setup = utils.async(function(opts, callback)
	opts = opts or {}

	setup_async(opts)
	interface.set_user_commands(M)
	interface.set_keymaps(opts.keymap_prefix, M)
	if callback ~= nil then callback() end
end)

M.get_query_manager = state.get_query_manager

return M
