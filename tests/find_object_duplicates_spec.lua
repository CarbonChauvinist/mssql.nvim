local finder = require("mssql.find_object")
local state = require("mssql.state")
local test_utils = require("tests.utils")
local explorer = require("mssql.explorer")

return {
	test_name = "Find Object cache does not duplicate entries due to accumulated listeners",
	run_test_async = function()
		state._reset_all_state()

		local session_counter = 0
		local mock_client = {
			id = 999,
			request = function(_, method, params, cb)
				if method == "objectexplorer/createsession" then
					session_counter = session_counter + 1
					local sid = "sess_" .. session_counter

					vim.defer_fn(function()
						cb(nil, {
							sessionId = sid,
							rootNode = {
								nodePath = "root",
								objectType = "Database"
							}
						})
					end, 10)
					return true, 1

				elseif method == "objectexplorer/expand" then
					-- rely on event to populate the cache not the callback
					-- triggers path where duplicate listeners would fire
					local sid = params.sessionId
					vim.defer_fn(function()
						explorer.handle_expand_completed(nil, {
							sessionId = sid,
							nodes = {
								{ label = "Table1", objectType = "Table", parentNodePath = "root", nodePath = "root/Table1" }
							}
						}, { client_id = 999 })
					end, 20)
					return true, 2

				elseif method == "objectexplorer/closeSession" then
					cb(nil, {})
					return true, 3
				end
			end
		}

		local conn_opts = { server = "S", database = "D" } --[[@as MssqlConnectionOptions]]

		local success1 = explorer.initialise_explorer_cache_async(mock_client, conn_opts, {scope = "database", force = true })
		assert(success1, "First refresh should succeed")

		local found1 = test_utils.wait_for_cache_content("Table1", {
			type = "Table",
			timeout = 1000,
		})
		assert(found1, "Run 1: Timed out waiting for 'Table1' in cache")

		local cache = explorer.get_cache()
		local targeted_cache
		for k, v in pairs(cache) do
			if k == explorer.create_cache_key(conn_opts, "database") then
				targeted_cache = v
				break
			end
		end

		assert(#targeted_cache.cache == 1, "Run 1: Expected 1 item, got " .. #targeted_cache.cache)

		-- run 2 if duplicate listeners bug exists this will cause two listeners
		-- to fire on the single event, pushing "Table1" into the cache twice
		local success2 = explorer.initialise_explorer_cache_async(mock_client, conn_opts, {scope = "database", force = true })
		assert(success2, "Second refresh command started successfully")

		local found2 = test_utils.wait_for_cache_content("Table1", {
			type = "Table",
			timeout = 1000,
		})
		assert(found2, "Run 2: Timed out waiting for 'Table1'")

		assert(#targeted_cache.cache == 1, "Run 2: Expected exactly 1 item, got " .. #targeted_cache.cache .. ". Duplicate listeners detected!")
	end,
}
