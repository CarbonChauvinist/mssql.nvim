local utils = require("mssql.utils")
local state = require("mssql.state")
local cmds = require("mssql.commands")
local ui = require("mssql.ui")
local lsp = require("mssql.lsp")
local interface = require("mssql.interface")
local default_opts = require("mssql.default_opts")
local downloader = require("mssql.tools_downloader")
local display_query_results = require("mssql.display_query_results")
local autocmds = require("mssql.autocmds")

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

M.new_query = function()
	utils.try_resume(coroutine.create(function()
		ui.new_query_async()
	end))
end

-- Look for the connection called "default", prompt to choose a database in that server,
-- connect to that database and open a new buffer for querying (very useful!)
M.new_default_query = function()
	local curr_conf = get_config_or_warn()
	if not curr_conf then return end
	utils.try_resume(coroutine.create(function()
		cmds.new_default_query_async(curr_conf)
	end))
end

--- Prompts for a database to switch to that is on the currently connected server.
---@overload fun()
---@overload fun(callback: fun())
---@overload fun(bufnr: integer)
---@overload fun(bufnr: integer, callback: fun())
---@param bufnr? integer|fun() The buffer number, OR the callback if only one argument is passed.
---@param callback? fun() The callback to run after switching
M.switch_database = function(bufnr, callback)
	if type(bufnr) == "function" then
		callback = bufnr
		bufnr = nil
	end
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local qm = state.get_query_manager(bufnr)
	if not qm then
		utils.log_error("No mssql lsp is attached. Create a new query or open an existing one.")
		return
	end

	utils.try_resume(coroutine.create(function()
		cmds.switch_database_async(bufnr)
		qm:initialise_cache_async()
		autocmds.clean_cache()
		if callback then callback() end
	end))
end

--- Connect the current buffer (you'll be prompted to choose a connection).
---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.connect = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if vim.api.nvim_buf_get_name(bufnr) == "" and vim.api.nvim_get_option_value("ft", {buf = bufnr}) == "sql" then
		vim.cmd("file " .. "untitled-" .. bufnr .. ".sql")
		local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "mssql_ls" })
		for _, client in ipairs(clients) do
			client:stop()
		end
		vim.cmd("doautocmd FileType")
		_ = lsp.wait_for_attach(bufnr)
	end

	local qm = state.get_query_manager(bufnr)
	local curr_conf = get_config_or_warn()
	if not curr_conf then return end

	if not qm then
		utils.log_error("No mssql lsp is attached. Create a new query or open an existing one.")
		return
	end

	utils.try_resume(coroutine.create(function()
		if cmds.perform_connect_async(curr_conf, qm, bufnr) then
			qm:initialise_cache_async()
		end
	end))
end

M.edit_connections = function()
	local curr_conn = get_config_or_warn()
	if not curr_conn then return end
	utils.edit_connections(curr_conn)
end

--- Rebuilds the sql object and intellisense cache
---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.refresh_cache = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local qm = state.get_query_manager(bufnr)
	if not qm then
		utils.log_error("No mssql lsp is attached. Create a new query or open an existing one.")
		return
	end
	if qm:get_state() ~= qm.states.connected then
		utils.log_error("You are currently " .. qm:get_state())
		return
	end
	-- refresh the object cache, fire and forget
	ui.set_caching_status(true)
	vim.cmd("redrawstatus")

	coroutine.resume(coroutine.create(function()
		qm:initialise_cache_async(true)
		ui.set_caching_status(false)
		vim.cmd("redrawstatus")
	end))

	-- refresh the intellisense cache, fire and forget
	local success, msg = pcall(function()
		local client = qm:get_lsp_client()
		---@diagnostic disable-next-line: param-type-mismatch
		client:notify("textDocument/rebuildIntelliSense", { ownerUri = utils.lsp_file_uri() })
	end)
	if not success then utils.log_error(msg) end
	utils.log_info("Refreshing cache...")
end

---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.disconnect = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local qm = state.get_query_manager(bufnr)
	if not qm then
		utils.log_error("No mssql lsp is attached. Create a new query or open an existing one.")
		return
	end

	utils.try_resume(coroutine.create(function()
		qm:disconnect_async()
		autocmds.clean_cache()
	end))
end

---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.execute_query = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local qm = state.get_query_manager(bufnr)
	if not qm then
		utils.log_error("No mssql lsp is attached. Create a new query or open an existing one.")
		return
	end

	utils.try_resume(coroutine.create(function()
		local query = utils.get_selected_text(bufnr)
		local curr_conf = get_config_or_warn()
		if not curr_conf then return end
		if qm:get_state() == qm.states.disconnected then
			utils.log_error("Please connect first.")
			return
		end

		ui.clear_message_buffer()
		local result = qm:execute_async(query)
		if result then -- since cancelled query returns nil, have to check for nil before displaying
			display_query_results.display_query_results(curr_conf, result)
		end
	end))
end

---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.cancel_query = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local qm = state.get_query_manager(bufnr)
	if qm then
		utils.try_resume(coroutine.create(function()
			qm:cancel_async()
		end))
	end
end


M.backup_database = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local qm = state.get_query_manager(bufnr)
	if not qm then return end
	utils.try_resume(coroutine.create(function()
		cmds.backup_database_async(qm)
	end))
end


---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.restore_database = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local qm = state.get_query_manager(bufnr)
	if not qm then return end
	utils.try_resume(coroutine.create(function()
		cmds.restore_database_async(qm)
	end))
end

---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.save_query_results = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local result_info = vim.b[bufnr].query_result_info
	if not result_info then
		utils.log_error("Go to a query result buffer to save results")
		return
	end
	utils.try_resume(coroutine.create(function()
		cmds.save_query_results_async(result_info)
	end))
end

---@overload fun()
---@overload fun(callback: fun())
---@overload fun(bufnr: integer)
---@overload fun(bufnr: integer, callback: fun())
---@param bufnr? integer|fun() The buffer number, OR the callback if only one argument is passed.
---@param callback? fun() The callback to run after switching.
M.find_object = function(bufnr, callback)
	if type(bufnr) == "function" then
		callback = bufnr
		bufnr = nil
	end
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local qm = state.get_query_manager(bufnr)
	if not qm then return end

	if qm:get_state() ~= qm.states.connected then
		utils.log_error("You are currently " .. qm:get_state())
		return
	end

	if qm:is_refreshing() then
		ui.set_caching_status(true)
		vim.cmd("redrawstatus")
		utils.log_error("Still caching. Try again in a few seconds...")
		return
	end

	ui.set_caching_status(false)
	vim.cmd("redrawstatus")
	local curr_conf = get_config_or_warn()
	if not curr_conf then return end

	utils.try_resume(coroutine.create(function()
		-- explicitly initialise cache for "database" scope
		-- this ensures if we just switched databases we build a new cache
		-- instead of showing an empty picker
		ui.set_caching_status(true)
		vim.cmd("redrawstatus")

		local success = qm:initialise_cache_async("database")

		ui.set_caching_status(false)
		vim.cmd("redrawstatus")

		if not success then
			return
		end

		local item = qm:find_async("database")
		if not item then return end

		local buf = ui.insert_query_into_buffer(item.script)
		if buf == 0 then buf = vim.api.nvim_get_current_buf() end

		qm = state.get_query_manager(buf)
		if not qm then return end

		if curr_conf.execute_generated_select_statements and item.select then
			ui.clear_message_buffer()
			local result = qm:execute_async(item.script)
			display_query_results.display_query_results(curr_conf, result)
		end
		if callback then callback() end
	end))
end

---@overload fun()
---@overload fun(callback: fun())
---@overload fun(bufnr: integer)
---@overload fun(bufnr: integer, callback: fun())
---@param bufnr? integer|fun() The buffer number, OR the callback if only one argument is passed.
---@param callback? fun() The callback to run after switching.
M.find_object_server = function(bufnr, callback)
	if type(bufnr) == "function" then
		callback = bufnr
		bufnr = nil
	end
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local qm = state.get_query_manager(bufnr)
	if not qm then return end

	if qm:get_state() ~= qm.states.connected then
		utils.log_error("You are currently " .. qm:get_state())
		return
	end

	if qm:is_refreshing() then
		ui.set_caching_status(true)
		vim.cmd("redrawstatus")
		utils.log_error("Still caching. Try again in a few seconds...")
		return
	end

	ui.set_caching_status(false)
	vim.cmd("redrawstatus")
	local curr_conf = get_config_or_warn()
	if not curr_conf then return end

	utils.try_resume(coroutine.create(function()
		ui.set_caching_status(true)
		vim.cmd("redrawstatus")

		local success = qm:initialise_cache_async("server")

		ui.set_caching_status(false)
		vim.cmd("redrawstatus")

		if not success then
			utils.log_error("Failed to load server objects.")
			return
		end

		local item = qm:find_async("server")
		if not item then return end

		local buf = ui.insert_query_into_buffer(item.script)
		if buf == 0 then buf = vim.api.nvim_get_current_buf() end

		qm = state.get_query_manager(buf)
		if not qm then return end

		if curr_conf.execute_generated_select_statements and item.select then
			ui.clear_message_buffer()
			local result, err = qm:execute_async(item.script)

			if result then
				display_query_results.display_query_results(curr_conf, result)
			elseif err then
				utils.log_error("Failed to execute generated SELECT: " .. err)
			end

		end
		if callback then callback() end
	end))
end

M.lualine_component = ui.lualine_component

M.set_keymaps = function(prefix)
	interface.set_keymaps(prefix, M)
end

--- Setup the plugin.
---@param opts MssqlConfig? User configuration options
---@param callback function? Optional callback to run after setup
M.setup = function(opts, callback)
	opts = opts or {}
	utils.try_resume(coroutine.create(function()
		setup_async(opts)
		interface.set_user_commands(M)
		interface.set_keymaps(opts.keymap_prefix, M)
		if callback ~= nil then callback() end
	end))
end

M.get_query_manager = state.get_query_manager

return M
