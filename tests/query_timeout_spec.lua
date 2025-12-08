local mssql = require("mssql")
local utils = require("mssql.utils")
local test_utils = require("tests.utils")

return {
	test_name = "Query should time out and state should be reset",
	run_test_async = function()

		test_utils.setup_mssql_async({query_timeout = 2})
		local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

		local query = "WAITFOR DELAY '00:00:04' SELECT 1"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
		mssql.execute_query(buf)

		local state = qm:get_state()
		local attempts = 0

		while state ~= qm.states.connected and attempts < 50 do
			test_utils.defer_async(100)
			state = qm:get_state()
			attempts = attempts + 1
		end

		assert(
			state == qm.states.connected,
			"Query manager state was not reset. Expected '" .. qm.states.connected .. "' got '" .. state .. "'"
		)

		-- test regular quick query to ensure connection is still useable
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT 1 AS TestSuccess" })
		utils.wait_for_schedule_async()
		mssql.execute_query(buf)

		local res_buf, _, results = test_utils.res_buf_catcher()
		assert(
			results:find("TestSuccess"),
			"Subsequent query did not return expected results."
		)

		test_utils.cleanup_results_buffer(res_buf)
		test_utils.setup_mssql_async({query_timeout = nil})
		cleanup()
	end,
}
