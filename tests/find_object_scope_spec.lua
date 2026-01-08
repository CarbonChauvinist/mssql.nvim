local finder = require("mssql.find_object")
local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
	test_name = "Find Object Scope (Server vs Database)",
	run_test_async = function()
		local captured_create_params = {}
		local mock_client = {
			id = 123456,
			request = function(_, method, params, cb)
				if method == "objectexplorer/createsession" then
					table.insert(captured_create_params, params)
					local sid = "sess_" .. #captured_create_params

					vim.defer_fn(function()
						cb(nil, {
							sessionId = sid,
							rootNode = {
								nodePath = "root",
								objectType = "Server"
							}
						})
					end, 10)
					return true, 1

				elseif method == "objectexplorer/expand" then
					-- return empty to stop recursion immediately, just testing connection setup
					vim.defer_fn(function()
						state.emit_event("objectexplorer/expandcompleted", nil, {
							sessionId = params.sessionId,
							nodes = {}
						}, { client_id = 123456 })
					end, 10)
					return true, 2

				elseif method == "objectexplorer/closeSession" then
					cb(nil, {})
					return true, 3
				end
			end
		}

		local opts = { server = "MyServer", database = "MyUserDb", user = "sa" }

		-- test 1 database sope (default)
		-- expect cache key contains db, createSession params contains db
		state._reset_all_state()
		captured_create_params = {}

		finder.initialise_cache_async(mock_client, opts, "database", true)
		test_utils.poll(function()
			return #captured_create_params > 0
		end, {timeout_ms = 1000})

		assert(#captured_create_params == 1, "Database scope: Should call createsession")
		assert(captured_create_params[1].DatabaseName == "MyUserDb", "Database scope: Should include DatabaseName in session params")

		local cache = finder.get_cache()
		local db_key_found = false
		for k, _ in pairs(cache) do
			if k:match("|database$") and k:match('"database":"MyUserDb"') then
				db_key_found = true
			end
		end
		assert(db_key_found, "Database scope: Cache key should include database name and |database suffix")


		-- test 2 server scope
		-- expect cache key does NOT contain db, createSession params do NOT contain db
		state._reset_all_state()
		captured_create_params = {}

		finder.initialise_cache_async(mock_client, opts, "server", true)
		test_utils.poll(function()
			return #captured_create_params > 0
		end, {timeout_ms = 1000})

		assert(#captured_create_params == 1, "Server scope: Should call createsession")
		assert(captured_create_params[1].DatabaseName == nil, "Server scope: Should STRIP DatabaseName from session params")
		assert(captured_create_params[1].ServerName == "MyServer", "Server scope: Should still include ServerName")

		cache = finder.get_cache()
		local server_key_found = false
		for k, _ in pairs(cache) do
			if k:match("|server$") and not k:match('"database":') then
				server_key_found = true
			end
		end
		assert(server_key_found, "Server scope: Cache key should NOT include database name and have |server suffix")
	end,
}
