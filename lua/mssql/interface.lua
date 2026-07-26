-- Handles how the user user interfaces with this plugin, i.e. keymaps and user commands
local query_manager_module = require("mssql.query_manager")
local utils = require("mssql.utils")
local state = require("mssql.state")

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
			new_default_query = {
				"d",
				M.new_default_query,
				desc = "New Default Query",
				icon = { icon = "", color = "yellow" },
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
				local qm = state.get_query_manager()
				if qm then
					local curr_state = qm:get_state()
					local states = query_manager_module.states
					if curr_state == states.connecting then
						return {
							keymaps.new_query,
							keymaps.new_default_query,
							keymaps.edit_connections,
						}
					elseif curr_state == states.executing then
						return {
							keymaps.new_query,
							keymaps.new_default_query,
							keymaps.edit_connections,
							keymaps.cancel_query,
						}
					elseif curr_state == states.connected then
						return {
							keymaps.new_query,
							keymaps.new_default_query,
							keymaps.edit_connections,
							keymaps.refresh_intellisense,
							keymaps.refresh_explorer_cache,
							keymaps.execute_query,
							keymaps.disconnect,
							{
								"s",
								M.switch_database,
								desc = "Switch Database",
								icon = { icon = "", color = "yellow" },
							},
							keymaps.find_object,
						}
					elseif curr_state == states.disconnected then
						return {
							keymaps.new_query,
							keymaps.new_default_query,
							keymaps.edit_connections,
							keymaps.connect,
							{
								"x",
								M.execute_query,
								desc = "Execute On Default",
								mode = { "n", "v" },
								icon = { icon = "", color = "green" },
							},
						}
					elseif curr_state == states.cancelling then
						return {
							keymaps.new_query,
							keymaps.new_default_query,
							keymaps.edit_connections,
						}
					else
						utils.log_error("Entered unrecognised query state: " .. curr_state)
						return {}
					end
				elseif vim.b.query_result_info then
					local save_result = {
						"s",
						M.save_query_results,
						desc = "Save Query Results",
						icon = { icon = "", color = "green" },
					}

					return { save_result, keymaps.new_query, keymaps.new_default_query, keymaps.edit_connections }
				else
					return { keymaps.new_query, keymaps.new_default_query, keymaps.edit_connections }
				end
			end

			wk.add(normal_group)

			local visual_group = vim.tbl_deep_extend("keep", wkeygroup, {})
			visual_group.mode = "v"
			visual_group.expand = function()
				local qm = state.get_query_manager()
				if not qm then
					return { keymaps.new_query, keymaps.new_default_query, keymaps.edit_connections }
				end

				local state = qm:get_state()
				local states = query_manager_module.states
				if state == states.connecting or state == states.executing or state == states.disconnected then
					return {}
				elseif state == states.connected then
					return { keymaps.execute_query }
				else
					utils.log_error("Entered unrecognised query state: " .. state)
					return {}
				end
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
			BackupDatabase = M.backup_database,
			RestoreDatabase = M.restore_database,
			ExecuteQuery = M.execute_query,
			RefreshIntelliSense = M.refresh_intellisense,
			RefreshExplorerCache = M.refresh_explorer_cache,
			EditConnections = M.edit_connections,
			SwitchDatabase = M.switch_database,
			NewQuery = M.new_query,
			NewDefaultQuery = M.new_default_query,
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
			if vim.b.query_result_info then
				return {
					"NewQuery",
					"NewDefaultQuery",
					"EditConnections",
					"SaveQueryResults",
				}
			elseif not qm then
				return {
					"NewQuery",
					"NewDefaultQuery",
					"EditConnections",
				}
			end

			local curr_state = qm:get_state()
			local states = query_manager_module.states
			if curr_state == states.connecting then
				return {
					"NewQuery",
					"NewDefaultQuery",
					"EditConnections",
				}
			elseif curr_state == states.executing then
				return {
					"NewQuery",
					"NewDefaultQuery",
					"EditConnections",
					"CancelQuery",
				}
			elseif curr_state == states.connected then
				return {
					"NewQuery",
					"NewDefaultQuery",
					"EditConnections",
					"RefreshIntelliSense",
					"RefreshExplorerCache",
					"ExecuteQuery",
					"Disconnect",
					"SwitchDatabase",
					"BackupDatabase",
					"RestoreDatabase",
					"Find",
					"FindServer",
				}
			elseif curr_state == states.disconnected then
				return {
					"NewQuery",
					"NewDefaultQuery",
					"EditConnections",
					"Connect",
				}
			elseif curr_state == states.cancelling then
				return {
					"NewQuery",
					"NewDefaultQuery",
					"EditConnections",
				}
			else
				utils.log_error("Entered unrecognised query state: " .. curr_state)
				return {}
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
