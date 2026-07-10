local finder = require("mssql.find_object")
local state = require("mssql.state")
local test_utils = require("tests.utils")
local utils = require("mssql.utils")
local explorer = require("mssql.explorer")

return {
	test_name = "Find Object scripts using the originating buffer's URI even if active window changes",
	run_test_async = function()
		state._reset_all_state({ force_all = true })

		-- Setup configuration via the test harness
		test_utils.setup_mssql_async()

		-- Create originating buffer (connected SQL buffer)
		local orig_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(orig_buf, vim.fs.joinpath(vim.loop.cwd(), "orig_query.sql"))
		vim.api.nvim_set_option_value("filetype", "sql", { buf = orig_buf })
		vim.api.nvim_set_current_buf(orig_buf)

		-- Create target/destination buffer (switched buffer)
		local switched_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(switched_buf, vim.fs.joinpath(vim.loop.cwd(), "switched_query.sql"))
		vim.api.nvim_set_option_value("filetype", "sql", { buf = switched_buf })

		local orig_uri = utils.lsp_file_uri(orig_buf)

		local captured_script_params = nil

		local mock_client = {
			id = 77777,
			request = function(_, method, params, cb)
				if method == "objectexplorer/createsession" then
					vim.defer_fn(function()
						cb(nil, {
							sessionId = "sess_cross_buf",
							rootNode = { nodePath = "root", objectType = "Server" }
						})
					end, 5)
					return true, 1
				elseif method == "scripting/script" then
					captured_script_params = params
					vim.defer_fn(function()
						cb(nil, { script = "SELECT 1" })
					end, 5)
					return true, 2
				elseif method == "objectexplorer/closeSession" then
					cb(nil, {})
					return true, 3
				end
			end
		}

		local conn_opts = { server = "MyServer", database = "MyDb", user = "sa" } --[[@as MssqlConnectionOptions]]

		-- Setup mock item in cache
		local cache_key = explorer.create_cache_key(conn_opts, "database")
		explorer.get_cache()[cache_key] = {
			cache = {
				{
					label = "MyTable",
					objectType = "Table",
					metadata = {
						metadataTypeName = "Table",
						schema = "dbo",
						name = "MyTable",
						urn = "Server[@Name='MyServer']/Database[@Name='MyDb']/Table[@Name='MyTable']"
					}
				}
			},
			scope = "database",
			connection_options = conn_opts
		}

		-- Mock vim.ui.select to switch buffer before making choice
		local original_ui_select = vim.ui.select
		vim.ui.select = function(items, _opts, on_choice)
			-- Switch the current buffer to simulate the user changing tabs/windows
			vim.api.nvim_set_current_buf(switched_buf)
			on_choice(items[1], 1)
		end

		-- Run find_async passing the originating buffer's URI
		finder.find_async(conn_opts, mock_client, { scope = "database", owner_uri = orig_uri })

		-- Restore original UI select
		vim.ui.select = original_ui_select

		-- Assertions
		assert(captured_script_params ~= nil, "Scripting request was not sent")
		assert(captured_script_params.ownerURI == orig_uri, "Scripting request used wrong ownerURI. Expected: " .. orig_uri .. ", Got: " .. tostring(captured_script_params.ownerURI))

		-- Cleanup
		vim.api.nvim_buf_delete(orig_buf, { force = true })
		vim.api.nvim_buf_delete(switched_buf, { force = true })
	end
}
