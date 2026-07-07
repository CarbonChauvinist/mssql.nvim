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
						finder.handle_expand_completed(nil, {
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

		local conn_opts = { server = "MyServer", database = "MyUserDb", user = "sa" } --[[@as MssqlConnectionOptions]]

		-- test 1 database sope (default)
		-- expect cache key contains db, createSession params contains db
		state._reset_all_state()
		captured_create_params = {}

		finder.initialise_cache_async(mock_client, conn_opts, { scope = "database", force = true })
		test_utils.poll(function()
			return #captured_create_params > 0
		end, {timeout_ms = 1000})

		assert(#captured_create_params == 1, "Database scope: Should call createsession")
		assert(captured_create_params[1].DatabaseName == "MyUserDb", "Database scope: Should include DatabaseName in session params")

		local cache = finder.get_cache()
		local db_key_found = false
		local db_scope_set = false

		for k, v in pairs(cache) do
			if k == finder.create_cache_key(conn_opts, "database") then
				db_key_found = true
				local conn_opts = v.connection_options or {}
				local finder_scope = v.scope or ""
				if finder_scope == "database" and (conn_opts.database and conn_opts.database == conn_opts.database) then
					db_scope_set = true
				end
			end
		end
		assert(db_key_found, "Database scope: Cache key should include database name")
		assert(db_scope_set, "Database scope: Cache value should have scope field set to 'database'")


		-- test 2 server scope
		-- expect cache key does NOT contain db, createSession params do NOT contain db
		state._reset_all_state()
		captured_create_params = {}

		finder.initialise_cache_async(mock_client, conn_opts, { scope = "server", force = true })
		test_utils.poll(function()
			return #captured_create_params > 0
		end, {timeout_ms = 1000})

		assert(#captured_create_params == 1, "Server scope: Should call createsession")
		assert(captured_create_params[1].DatabaseName == nil, "Server scope: Should STRIP DatabaseName from session params")
		assert(captured_create_params[1].ServerName == "MyServer", "Server scope: Should still include ServerName")

		cache = finder.get_cache()
		local server_key_found = false
		local server_scope_set = false
		for k, v in pairs(cache) do
			if k == finder.create_cache_key(conn_opts, "server") then
				server_key_found = true
				local finder_scope = v.scope or ""
				if finder_scope == "server" then
					server_scope_set = true
				end
			end
		end
		assert(server_key_found, "Server scope: Cache key should NOT include database name and have |server suffix")
		assert(server_scope_set, "Server scope: Cache value should have scope field set to 'server'")
	end,
}
