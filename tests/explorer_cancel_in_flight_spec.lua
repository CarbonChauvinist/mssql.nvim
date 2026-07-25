local explorer = require("mssql.explorer")

return {
	test_name = "Explorer Protocol: in-flight session creation cancellation closes session on server",
	run_test_async = function()
		explorer.reset_explorer_state()

		local closed_sessions = {}
		local session_id = "sess_cancel_test"
		local createsession_cb

		local mock_client = {
			id = 9999,
			request = function(_, method, params, cb)
				if method == "objectexplorer/createsession" then
					-- hold callback to fake in-flight LSP server delay
					createsession_cb = cb
					return true, 1
				elseif method == "objectexplorer/closeSession" then
					table.insert(closed_sessions, params.sessionId)
					if cb then cb(nil, {}) end
					return true, 2
				end
				return true, 3
			end,
		}

		local conn_opts = { server = "localhost", database = "master" }

		-- 1. start session creation in background coroutine
		local co = coroutine.create(function()
			explorer.initialise_explorer_cache_async(
				mock_client,
				conn_opts,
				{ scope = "database", force = true })
		end)
		coroutine.resume(co)

		-- wait for create session request to be sent to LSP client
		local sent = vim.wait(1000, function() return createsession_cb ~= nil end, 10, false)
		assert(sent and createsession_cb ~= nil, "createsession request should have been initiated")

		-- 2. simulate calling cancel_refresh while createsession is in-flight
		explorer.cancel_refresh(conn_opts, "database")

		-- 3. late createsession response arrives from server after cancellation
		if createsession_cb then
			createsession_cb(nil, {
				sessionId = session_id,
				rootNode = { nodePath = "root", objectType = "Server" }
			})
		end

		-- 4. verify late arriving session was immediately closed on server
		assert(#closed_sessions == 1, "Late-arriving session should have been closed on server")
		assert(closed_sessions[1] == session_id, "Closed session ID should match" .. session_id)
	end,
}
