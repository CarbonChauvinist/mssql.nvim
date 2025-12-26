local state = require("mssql.state")

return {
	test_name = "Multiple handlers should run even if one crashes",
	run_test_async = function()
		local event_name = "test/resilience_check"
		local survivor_executed = false

		local dispose_crash = state.on_event(event_name, function()
			error("This is an INTENTIONAL crash for testing purposes")
		end)

		local dispose_survivor = state.on_event(event_name, function()
			survivor_executed = true
		end)

		state.emit_event(event_name, nil, { some_data = true }, { client_id = 1 })

		assert(survivor_executed, "The second handler should have executed despite the first one crashing")

		if dispose_crash then dispose_crash() end
		if dispose_survivor then dispose_survivor() end
	end,
}
