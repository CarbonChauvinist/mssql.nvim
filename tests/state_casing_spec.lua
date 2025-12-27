local state = require("mssql.state")

return {
	test_name = "State module handles event casing insensitively",
	run_test_async = function()

		-- case 1 register CamelCase, emits lowercase
		local case1_hit = false
		state.on_event("Test/EventOne", function() case1_hit = true end)

		state.emit_event("test/eventone", nil, nil, nil)
		assert(case1_hit, "Failed to catch lowercase event with CamelCase listener")

		-- case 2 register lowercase, emit CamelCase
		local case2_hit = false
		state.on_event("test/eventtwo", function() case2_hit = true end)

		state.emit_event("Test/EventTwo", nil, nil, nil)
		assert(case2_hit, "Failed to catch CamelCase event with lowercase listener")

		-- case 3 named listeners (idempotency) with mixed casing
		local case3_count = 0
		state.on_event("Test/EventThree", function() case3_count = case3_count + 1 end, "my_id")
		-- registered second time should overwrite the first, not duplicate
		state.on_event("TEST/EVENTTHREE", function() case3_count = case3_count + 1 end, "my_id")

		state.emit_event("test/eventthree", nil, nil, nil)
		assert(case3_count == 1, "Named listeners failed to overwrite when casing differed. Count: " .. case3_count)

		local success, err = pcall(function()
			---@diagnostic disable-next-line: param-type-mismatch
			state.on_event("test/event", function() end, 12345)
		end)
		assert(not success, "on_event should throw error for non-string group_id")
		assert(err and err:match("group_id must be a string"), "Error message mismatch: " .. tostring(err))
	end,
}
