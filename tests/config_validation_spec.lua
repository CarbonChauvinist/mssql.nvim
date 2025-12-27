local mssql = require("mssql")
local state = require("mssql.state")
local default_opts = require("mssql.default_opts")

return {
	test_name = "Configuration inputs are validated and sanitized during setup",
	run_test_async = function()
		-- case 1 - invalid type should revert to default
		local done_1 = false
		mssql.setup({ max_rows = "not_a_number" }, function() done_1 = true end)

		vim.wait(1000, function() return done_1 end)
		assert(done_1, "Setup callback never fired for Case 1")

		local conf_1 = state.get_config() or {}
		assert(conf_1.max_rows == default_opts.max_rows, "Expected max_rows to fallback to default " .. default_opts.max_rows .. " but got " .. tostring(conf_1.max_rows))

		-- case 2 - invalid value should revert to default
		local done_2 = false
		mssql.setup({ max_rows = -10 }, function() done_2 = true end)

		vim.wait(1000, function() return done_2 end)
		local conf_2 = state.get_config() or {}
		assert(conf_2.max_rows == default_opts.max_rows, "Expected max_rows to fallback to default for negative input but got " .. tostring(conf_2.max_rows))

		-- case 3 - valid input should be preserved
		local done_3 = false
		mssql.setup({ max_rows = 500 }, function() done_3 = true end)

		vim.wait(1000, function() return done_3 end)
		local conf_3 = state.get_config() or {}
		assert(conf_3.max_rows == 500, "Valid max_rows should be preserved")
	end,
}
