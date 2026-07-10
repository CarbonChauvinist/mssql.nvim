local explorer = require("mssql.explorer")
local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
	test_name = "Cache initialization times out gracefully using real timer",
	run_test_async = function()
		test_utils.setup_mssql_async({
			object_explorer_timeouts = {
				server = 1,
				database = 1
			}
		})

		local mock_client = {
			id = 7777,
			request = function(_, method, _, cb)
				-- create session succeeds immediately
				if method == "objectExplorer/createSession" then
					vim.schedule(function()
						cb(nil, {
							sessionId = "sess_timeout_test",
							success = true,
							rootNode = {
								nodePath = "server_root",
								objectType = "Server",
								label = "localhost",
								isLeaf = false,
								parentNodePath = ""
							}
						})
					end)
					return true, 1
				end

				-- expand returns true (request sent) but NEVER calls callback
				-- simulates the server "hanging" or dropping the request
				if method == "objectExplorer/expand" then
					return true, 2
				end

				if method == "objectExplorer/closeSession" then
					if cb then cb(nil, {}) end
					return true, 3
				end
			end,
		}

		local conn_opts = {
			server = "localhost",
			database = "tempdb"
		} --[[@as MssqlConnectionOptions]]

		local success = explorer.initialise_cache_async(mock_client, conn_opts, { force = true })
		if state._reset_all_state then state._reset_all_state() end
		assert(success == false, "Function should have returned false (failed) due to timeout.")

		test_utils.setup_mssql_async({
			object_explorer_timeouts = {
				server = 180,
				database = 90,
			}
		})

	end,
}
