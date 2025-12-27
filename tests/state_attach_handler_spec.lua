local state = require("mssql.state")

return {
	test_name = "State module add_attach_handler validates input correctly",
	run_test_async = function()
		state._reset_all_state()
		local bufnr = 1

		local func1 = function() end
		local success1, err1 = state.add_attach_handler(bufnr, func1)

		assert(success1, "Failed to add single function handler. Error: " .. tostring(err1))
		local handlers = state.get_attach_handlers(bufnr)
		assert(#handlers == 1, "Expected 1 handler, got " .. #handlers)

		local func2 = function() end
		local func3 = function() end
		local success2, err2 = state.add_attach_handler(bufnr, { func2, func3 })

		assert(success2, "Failed to add table of handlers. Error: " .. tostring(err2))
		handlers = state.get_attach_handlers(bufnr)
		assert(#handlers == 3, "Expected 3 handlers (1 + 2), got " .. #handlers)

		local success3, err3 = state.add_attach_handler(bufnr, "not a function")
		assert(not success3, "Should have rejected string input")
		assert(err3:match("neither table nor function"), "Error message mismatch: " .. tostring(err3))

		local success4, err4 = state.add_attach_handler(bufnr, 12345)
		assert(not success4, "Should have rejected number input")

		local success5a, err5a = state.add_attach_handler(bufnr, { "garbage", 123 })
		assert(not success5a, "Should have rejected table with no functions")

		local func_valid = function() end
		local success5b, err5b = state.add_attach_handler(bufnr, { "garbage", func_valid })
		assert(success5b, "Should accept table with at least one valid function")

		handlers = state.get_attach_handlers(bufnr)
		assert(#handlers == 4, "Expected 4 handlers total, got " .. #handlers)
	end,
}
