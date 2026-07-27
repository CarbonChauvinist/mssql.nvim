-- Handles how the user user interfaces with this plugin, i.e. keymaps and user commands
local query_manager_module = require("mssql.query_manager")
local state = require("mssql.state")

---Maps query manager state & buffer context to available action keys
---@param qm MssqlQueryManager?
---@param is_results_buf boolean
---@param mode "n"|"v"
---@return string[] action_keys
local get_available_actions = function(qm, is_results_buf, mode)
	if mode == "v" then
		if qm and qm:get_state() == query_manager_module.states.connected then
			return { "execute_query" }
		end
		return {}
	end

	if is_results_buf then
		return { "save_query_results", "new_query", "edit_connections" }
	end

	if not qm then
		return { "new_query", "edit_connections" }
	end

	local curr_state = qm:get_state()
	local states = query_manager_module.states

	if curr_state == states.connecting or curr_state == states.cancelling then
		return { "new_query", "edit_connections" }
	elseif curr_state == states.executing then
		return { "new_query", "edit_connections", "cancel_query" }
	elseif curr_state == states.connected then
		return {
			"new_query",
			"edit_connections",
			"refresh_intellisense",
			"refresh_explorer_cache",
			"execute_query",
			"disconnect",
			"switch_database",
			"find_object",
			"find_object_server",
		}
	elseif curr_state == states.disconnected then
		return { "new_query", "edit_connections", "connect" }
	end

	return { "new_query", "edit_connections" }
end

local action_to_user_command = {
	new_query = "NewQuery",
	edit_connections = "EditConnections",
	connect = "Connect",
	disconnect = "Disconnect",
	cancel_query = "CancelQuery",
	execute_query = "ExecuteQuery",
	refresh_intellisense = "RefreshIntelliSense",
	refresh_explorer_cache = "RefreshExplorerCache",
	switch_database = "SwitchDatabase",
	save_query_results = "SaveQueryResults",
	find_object = "Find",
	find_object_server = "FindServer",
}

return {
	---@param prefix string
	---@param M MssqlModule The mssql module (from init.lua)
	set_keymaps = function(prefix, M)
		if not prefix then
			return
		end

		local keymaps = {
			new_query = { "n", M.new_query, desc = "New Query", icon = { icon = "", color = "yellow" } },
			connect = { "c", M.connect, desc = "Connect", icon = { icon = "󱘖", color = "green" } },
			disconnect = { "q", M.disconnect, desc = "Disconnect", icon = { icon = "", color = "red" } },
			cancel_query = { "l", M.cancel_query, desc = "Cancel Query", icon = { icon = "", color = "red" } },
			execute_query = {
				"x",
				M.execute_query,
				desc = "Execute Query",
				mode = { "n", "v" },
				icon = { icon = "", color = "green" },
			},
			switch_database = {
				"s",
				M.switch_database,
				desc = "Switch Database",
				icon = { icon = "", color = "yellow" },
			},
			save_query_results = {
				"s",
				M.save_query_results,
				desc = "Save Query Results",
				icon = { icon = "", color = "green" },
			},
			edit_connections = {
				"e",
				M.edit_connections,
				desc = "Edit Connections",
				icon = { icon = "󰅩", color = "grey" },
			},
			refresh_intellisense = {
				"r",
				M.refresh_intellisense,
				desc = "Refresh Intellisense",
				icon = { icon = "", color = "grey" },
			},
			refresh_explorer_cache = {
				"rf",
				M.refresh_explorer_cache,
				desc = "Refresh Object Explorer cache",
				icon = { icon = "", color = "red" },
			},
			find_object = {
				"f",
				function() M.find_object() end,
				desc = "Find",
				icon = { icon = "", color = "green" },
			},
			find_table = {
				"ft",
				function() M.find_object({object_type = "t"}) end,
				desc = "Find Table",
				icon = { icon = "", color = "green" },
			},
			find_view = {
				"fv",
				function() M.find_object({object_type = "v"}) end,
				desc = "Find View",
				icon = { icon = "", color = "green" },
			},
			find_sproc = {
				"fp",
				function() M.find_object({object_type = "p"}) end,
				desc = "Find Sproc",
				icon = { icon = "", color = "green" },
			},
			find_func = {
				"ff",
				function() M.find_object({object_type = "f"}) end,
				desc = "Find Function",
				icon = { icon = "", color = "green" },
			},
			find_object_server = {
				"F",
				function() M.find_object({scope = "server"}) end,
				desc = "Find (Server)",
				icon = { icon = "", color = "red" },
			},
			find_table_server = {
				"Ft",
				function() M.find_object({scope = "server", object_type = "t"}) end,
				desc = "Find Table (Server)",
				icon = { icon = "", color = "red" },
			},
			find_view_server = {
				"Fv",
				function() M.find_object({scope = "server", object_type = "v"}) end,
				desc = "Find View",
				icon = { icon = "", color = "red" },
			},
			find_sproc_server = {
				"Fp",
				function() M.find_object({scope = "server", object_type = "p"}) end,
				desc = "Find Sproc (Server)",
				icon = { icon = "", color = "red" },
			},
			find_func_server = {
				"Ff",
				function() M.find_object({scope = "server", object_type = "f"}) end,
				desc = "Find Function (Server)",
				icon = { icon = "", color = "red" },
			},
		}

		local success, wk = pcall(require, "which-key")
		if success then
			local wkeygroup = {
				prefix,
				group = "mssql",
				icon = { icon = "", color = "yellow" },
			}

			local normal_group = vim.tbl_deep_extend("keep", wkeygroup, {})
			normal_group.expand = function()
				local action_keys = get_available_actions(state.get_query_manager(), vim.b.query_result_info ~= nil, "n")
				return vim.tbl_map(function(k) return keymaps[k] end, action_keys)
			end

			wk.add(normal_group)

			local visual_group = vim.tbl_deep_extend("keep", wkeygroup, {})
			visual_group.mode = "v"
			visual_group.expand = function()
				local action_keys = get_available_actions(state.get_query_manager(), false, "v")
				return vim.tbl_map(function(k) return keymaps[k] end, action_keys)
			end

			wk.add(visual_group)
		else
			for _, m in pairs(keymaps) do
				vim.keymap.set(m.mode or "n", prefix .. m[1], m[2], { desc = m.desc })
			end
			vim.keymap.set("n", prefix .. "s", function()
				if vim.b.query_result_info then
					M.save_query_results()
				else
					M.switch_database()
				end
			end)
		end
	end,

	---@param M MssqlModule
	set_user_commands = function(M)
		local commands = {
			Connect = M.connect,
			Disconnect = M.disconnect,
			ExecuteQuery = M.execute_query,
			RefreshIntelliSense = M.refresh_intellisense,
			RefreshExplorerCache = M.refresh_explorer_cache,
			EditConnections = M.edit_connections,
			SwitchDatabase = M.switch_database,
			NewQuery = M.new_query,
			SaveQueryResults = M.save_query_results,
			CancelQuery = M.cancel_query,

			Find = function(args)
				local opts = { scope = "database" }
				for _, arg in ipairs(args) do
					if arg == "server" then opts.scope = "server"
					elseif arg == "table" then opts.object_type = "t"
					elseif arg == "view" then opts.object_type = "v"
					elseif arg == "proc" then opts.object_type = "p"
					elseif arg == "func" then opts.object_type = "f"
					end
				end
				M.find_object(opts)
			end,

			FindServer = function(args)
				local opts = { scope = "server" }
				for _, arg in ipairs(args) do
					if arg == "table" then opts.object_type = "t"
					elseif arg == "view" then opts.object_type = "v"
					elseif arg == "proc" then opts.object_type = "p"
					elseif arg == "func" then opts.object_type = "f"
					end
				end
				M.find_object(opts)
			end,
		}

		local complete = function(_, cmd_line, _)
			local parts = vim.split(cmd_line, "%s+")
			local subcommand = parts[2]

			if subcommand == "Find" or subcommand == "FindServer" then
				if #parts > 2 then
					return { "server", "table", "view", "proc", "func" }
				end
			end

			local qm = state.get_query_manager()
			local action_keys = get_available_actions(qm, vim.b.query_result_info ~= nil, "n")
			local cmds = {}
			for _, key in ipairs(action_keys) do
				local cmd_name = action_to_user_command[key]
				if cmd_name and not vim.list_contains(cmds, cmd_name) then
					table.insert(cmds, cmd_name)
				end
			end
		end

		vim.api.nvim_create_user_command("MSSQL", function(opts)
			local fargs = opts.fargs
			local cmd_name = fargs[1]

			local handler = commands[cmd_name]
			if not handler then
				error("No such command " .. (cmd_name or ""), 0)
			end

			table.remove(fargs, 1)
			handler(fargs)
		end, { nargs = "+", complete = complete })
	end,
}
