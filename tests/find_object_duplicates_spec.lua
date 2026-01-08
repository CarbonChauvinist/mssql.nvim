local finder = require("mssql.find_object")
local state = require("mssql.state")
local test_utils = require("tests.utils")

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
						state.emit_event("objectexplorer/expandcompleted", nil, {
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

		local opts = { server = "S", database = "D" }
		local cache_key = vim.json.encode(opts) .. "|" .. "database"

		local success1 = finder.initialise_cache_async(mock_client, opts, nil, true)
		assert(success1, "First refresh should succeed")

		local found1 = test_utils.wait_for_cache_content("Table1", {
			type = "Table",
			timeout = 1000,
		})
		assert(found1, "Run 1: Timed out waiting for 'Table1' in cache")

		local entry1 = finder.get_cache()[cache_key]
		assert(#entry1.cache == 1, "Run 1: Expected 1 item, got " .. #entry1.cache)

		-- run 2 if duplicate listeners bug exists this will cause two listeners
		-- to fire on the single event, pushing "Table1" into the cache twice
		local success2 = finder.initialise_cache_async(mock_client, opts, nil, true)
		assert(success2, "Second refresh command started successfully")

		local found2 = test_utils.wait_for_cache_content("Table1", {
			type = "Table",
			timeout = 1000,
		})
		assert(found2, "Run 2: Timed out waiting for 'Table1'")

		local entry2 = finder.get_cache()[cache_key]
		assert(#entry2.cache == 1, "Run 2: Expected exactly 1 item, got " .. #entry2.cache .. ". Duplicate listeners detected!")
	end,
}
