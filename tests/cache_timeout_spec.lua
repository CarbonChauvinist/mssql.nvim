local finder = require("mssql.find_object")
local state = require("mssql.state")

return {
	test_name = "Cache initialization times out gracefully using real timer",
	run_test_async = function()
		local TEST_TIMEOUT_MS = 50

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

		local connection_options = {
			server = "localhost",
			database = "tempdb"
		}

		local success = finder.initialise_cache_async(mock_client, connection_options, true, TEST_TIMEOUT_MS)
		if state._reset_all_state then state._reset_all_state() end
		assert(success == false, "Function should have returned false (failed) due to timeout.")

	end,
}
