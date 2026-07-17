local explorer = require("mssql.explorer")
local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
	test_name = "Explorer Protocol: cache initialization and session management",
	run_test_async = function()
		state._reset_all_state({ force_all = true })
		test_utils.setup_mssql_async()

		local session_id = "sess_explorer_test"

		local mock_client = {
			id = 12345,
			request = function(_, method, params, cb)
				if method == "objectexplorer/createsession" then
					vim.defer_fn(function()
						state.resume_waiting_coroutine(0, "objectexplorer/sessioncreated", {
							sessionId = session_id,
							success = true,
							rootNode = { nodePath = "root", objectType = "Server" }
						}, nil, 12345)
						cb(nil, { sessionId = session_id })
					end, 5)
					return true, 1
				elseif method == "objectexplorer/expand" then
					local nodes = {}
					if params.nodePath == "root" then
						nodes = {
							{ label = "Databases", nodePath = "root/Databases", objectType = "Folder", isLeaf = false }
						}
					elseif params.nodePath == "root/Databases" then
						nodes = {
							{ label = "master", nodePath = "root/Databases/master", objectType = "Database", isLeaf = false }
						}
					elseif params.nodePath == "root/Databases/master" then
						nodes = {
							{ label = "Tables", nodePath = "root/Databases/master/Tables", objectType = "Tables", isLeaf = false }
						}
					elseif params.nodePath == "root/Databases/master/Tables" then
						nodes = {
							{
								label = "dbo.Car",
								nodePath = "root/Databases/master/Tables/Car",
								objectType = "Table",
								isLeaf = true,
								metadata = { schema = "dbo", name = "Car" }
							}
						}
					end

					vim.defer_fn(function()
						explorer.handle_expand_completed(nil, {
							sessionId = session_id,
							nodes = nodes
						}, { client_id = 12345 })
					end, 5)
					return true, 2
				elseif method == "objectexplorer/closeSession" then
					cb(nil, {})
					return true, 3
				end
			end
		}

		local conn_opts = { server = "MyServer", database = "master", user = "sa" } --[[@as MssqlConnectionOptions]]

		-- test init
		local success = explorer.initialise_explorer_cache_async(mock_client, conn_opts, { scope = "server", force = true })
		assert(success, "Explorer cache failed to initialize")

		-- test cache contents
		local cache = explorer.get_cache()
		local key = explorer.create_cache_key(conn_opts, "server")
		assert(cache[key] ~= nil, "Cache entry was not created")
		assert(cache[key].scope == "server", "Cache scope is incorrect")

		-- wait for cache content expansion
		local found = test_utils.poll(function()
			local entry = cache[key]
			return entry.cache and #entry.cache > 0
		end)
		assert(found, "Cache nodes were not populated")
		assert(cache[key].cache[1].label == "dbo.Car", "Cache node label is incorrect")

		-- test reset state
		explorer.reset_explorer_state()
		assert(vim.tbl_isempty(explorer.get_cache()), "Cache was not cleared after reset")
	end
}
