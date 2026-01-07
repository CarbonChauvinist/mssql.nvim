local mssql = require("mssql")
local test_utils = require("tests.utils")
local state = require("mssql.state")

return {
	test_name = "Query execution: respect disabled timeout",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })

		local config = state.get_config() or {}
		config.query_timeout = nil
		state.set_config(config)

		local original_defer = vim.defer_fn
		local default_timer_detected = false

		---@diagnostic disable-next-line: duplicate-set-field
		vim.defer_fn = function(cb, ms)
			if ms == 10000 then
				default_timer_detected = true
			end
			return original_defer(cb, ms)
		end

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT 1" })
		mssql.execute_query(buf)

		local res_buf = test_utils.res_buf_catcher()
		assert(res_buf, "Query failed to complete")

		assert(not default_timer_detected, "FAILURE: 10s timeout timer was scheduled despite query_timeout=nil")

		vim.defer_fn = original_defer
		test_utils.cleanup_results_buffer(res_buf)
		cleanup()
	end,
}
