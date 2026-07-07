local finder = require("mssql.find_object")
local state = require("mssql.state")
local utils = require("mssql.utils")
local test_utils = require("tests.utils")

return {
	test_name = "Find Object scripts cross-database by establishing a temporary connection context",
	run_test_async = function()
		state._reset_all_state({ force_all = true })
		test_utils.setup_mssql_async()

		local orig_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(orig_buf, vim.fs.joinpath(vim.loop.cwd(), "orig_query.sql"))
		vim.api.nvim_set_option_value("filetype", "sql", { buf = orig_buf })
		vim.api.nvim_set_current_buf(orig_buf)

		local orig_uri = utils.lsp_file_uri(orig_buf)

		local captured_connect_params = nil
		local captured_script_params = nil

		local mock_client = {
			id = 88888,
			request = function(_, method, params, cb)
				if method == "connection/connect" then
					captured_connect_params = params
					vim.defer_fn(function()
						cb(nil, {})
						vim.defer_fn(function()
							-- Simulate connection/complete notification after connect request resolves
							state.resume_waiting_coroutine(0, "connection/complete", {
								connectionSummary = { databaseName = params.connection.options.database }
							}, nil, 88888)
						end, 5)
					end, 5)
					return true, 1
				elseif method == "scripting/script" then
					captured_script_params = params
					vim.defer_fn(function()
						cb(nil, { script = "CREATE TABLE MyTable" })
					end, 5)
					return true, 2
				elseif method == "objectexplorer/closeSession" then
					cb(nil, {})
					return true, 3
				end
			end
		}

		local connect_options = { server = "MyServer", database = "DbA", user = "sa" }
		local connect_params = {
			ownerUri = orig_uri,
			connection = {
				options = connect_options
			}
		}

		-- Setup mock item in cache for database "DbB" (different from connected "DbA")
		local conn_opts_dbb = { server = "MyServer", database = "DbB", user = "sa" }
		local cache_key = finder.create_cache_key(conn_opts_dbb, "database")
		finder.get_cache()[cache_key] = {
			cache = {
				{
					label = "MyTable",
					objectType = "Table",
					metadata = {
						metadataTypeName = "Table",
						schema = "dbo",
						name = "MyTable",
						urn = "Server[@Name='MyServer']/Database[@Name='DbB']/Table[@Name='MyTable']"
					}
				}
			},
			scope = "database",
			connection_options = conn_opts_dbb
		}

		-- Mock vim.ui.select to immediately select the item
		local original_ui_select = vim.ui.select
		vim.ui.select = function(items, _opts, on_choice)
			on_choice(items[1], 1)
		end

		-- Run find_async
		finder.find_async(conn_opts_dbb, mock_client, { scope = "database", owner_uri = orig_uri, connect_params = connect_params })

		-- Restore
		vim.ui.select = original_ui_select

		-- Assertions
		assert(captured_connect_params ~= nil, "Temporary connection was not established")
		assert(captured_connect_params.ownerUri == "mssql://scripting/MyServer/DbB", "Wrong temporary URI connected")
		assert(captured_connect_params.connection.options.database == "DbB", "Should connect to target DbB")

		assert(captured_script_params ~= nil, "Scripting request was not sent")
		assert(captured_script_params.ownerURI == "mssql://scripting/MyServer/DbB", "Scripting request used wrong ownerURI context")

		-- Cleanup
		vim.api.nvim_buf_delete(orig_buf, { force = true })
	end
}
