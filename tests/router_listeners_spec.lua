local state = require("mssql.state")

return {
	test_name = "Router correctly fans out messages to multiple listeners and handles unsubscription correctly",
	run_test_async = function()
		local event_name = "query/complete"
		local counter_1, counter_2, counter_3 = 0, 0, 0

		local dispose_listener_1 = state.on_event(event_name, function()
			counter_1 = counter_1 + 1
		end)

		local dispose_listener_2 = state.on_event(event_name, function()
			counter_2 = counter_2 + 1
		end)

		local dispose_listener_3 = state.on_event(event_name, function()
			counter_3 = counter_3 + 1
		end)

		state.emit_event(event_name, nil, { some_data = true }, { client_id = 1 })

		assert(counter_1 == 1, "The first handler should have executed once")
		assert(counter_2 == 1, "The second handler should have executed once")
		assert(counter_3 == 1, "The third handler should have executed once")

		if dispose_listener_1 then dispose_listener_1() end
		if dispose_listener_2 then dispose_listener_2() end
		if dispose_listener_3 then dispose_listener_3() end

		-- test dispose functionality
		state.emit_event(event_name, nil, { some_data = true }, { client_id = 1 })
		assert(counter_1 == 1, "The first handler should not have executed after being disposed")
		assert(counter_2 == 1, "The second handler should not have executed after being disposed")
		assert(counter_3 == 1, "The third handler should not have executed after being disposed")
	end,
}
