local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
	test_name = "LSP Client dynamically creates handlers for unknown MSSQL methods",
	run_test_async = function()
		local _, client, _, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
		local dynamic_method = "ObjectExplorer/RunFutureTask"
		local expected_event_name = "objectexplorer/runfuturetask"
		local listener_fired = false

		state.on_event(expected_event_name, function(_err, result, _ctx)
			listener_fired = true
			assert(result.foo == "bar", "Result payload should pass through")
		end)

		-- accessing the handler from the client
		-- because it's missing the __index metatable should fire and create it
		local dynamic_handler = client.handlers[dynamic_method]

		assert(dynamic_handler ~= nil, "Metatable should have created a handler for " .. dynamic_method)
		assert(type(dynamic_handler) == "function", "Created handler should be a function")

		-- simulate neovim receiving a notification
		dynamic_handler(nil, { foo = "bar" }, { client_id = client.id })

		assert(listener_fired, "The dynamically created handler should have emitted the event to state.lua")

		local random_method = "random/thing"
		local nil_handler = client.handlers[random_method]
		assert(nil_handler == nil, "Metatable should NOT create handlers for unknown methods like " .. random_method)

		cleanup()
	end,
}
