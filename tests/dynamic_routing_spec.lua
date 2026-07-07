local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
	test_name = "LSP Client dynamically creates handlers for unknown MSSQL methods",
	run_test_async = function()
		local _, client, _, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
		local dynamic_method = "ObjectExplorer/RunFutureTask"
		local expected_event_name = "objectexplorer/runfuturetask"

		local dynamic_handler = client.handlers[dynamic_method]

		assert(dynamic_handler ~= nil, "Metatable should have created a handler for " .. dynamic_method)
		assert(type(dynamic_handler) == "function", "Created handler should be a function")

		-- register test runner coroutine to wait for this dynamic event on buffer 0
		local co = coroutine.running()
		state.register_waiting_coroutine(0, expected_event_name, co)

		-- simulate neovim receiving the notification asynchronously on the next event loop cycle
		vim.schedule(function()
			dynamic_handler(nil, { foo = "bar" }, { client_id = client.id })
		end)

		-- wait (yield) until the handler resumes this coroutine
		local result, err = coroutine.yield()
		assert(err == nil, "Should not return an error")
		assert(result and result.foo == "bar", "Result payload should pass through")

		local random_method = "random/thing"
		local nil_handler = client.handlers[random_method]
		assert(nil_handler == nil, "Metatable should NOT create handlers for unknown methods like " .. random_method)

		cleanup()
	end,
}
