local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Lualine component should display elapsed time and rows affected",
	run_test_async = function()
		local live_timer_pattern = "%d?%d?:?%d%d:%d%d$"
		local final_timer_pattern = "%d%d:%d%d.%d+"
		local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

		-- test live query execution stats
		local query_long = "WAITFOR DELAY '00:00:03'; SELECT 1 AS Test;"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query_long })
		mssql.execute_query(buf)

		local select_status
		local live_query_stats = test_utils.poll(function()
			select_status = test_utils.get_lualine_status() or ""
			return select_status:find("Executing") and select_status:find(live_timer_pattern)
		end, { timeout_ms = 1500, interval = 50 })

		assert(live_query_stats, "Lualine should show 'Executing' and live timer. Got: " .. select_status)

		local res_buf, _, _ = test_utils.res_buf_catcher()
		vim.api.nvim_win_set_buf(0, buf)

		local final_status = test_utils.get_lualine_status()
		assert(final_status, "Status should not be nil.")
		assert(final_status:find("1 row affected"), "Should show '1 row affected'. Got: " .. final_status)
		assert(final_status:find(final_timer_pattern), "Should show final time with ms. Got: " .. final_status)

		test_utils.cleanup_results_buffer(res_buf)

		-- test DML
		local query_update = "SELECT * INTO #test_temp FROM (VALUES (1), (2)) AS t(c); UPDATE #test_temp SET c = c + 1;"
		vim.api.nvim_buf_set_lines(buf, 1, -1, false, { query_update })
		mssql.execute_query(buf)

		local dml_finished = test_utils.poll(function()
			return qm:get_state() == qm.states.Connected
		end, { timeout_ms = 5000 })
		assert(dml_finished, "Query did not finish (Timed out waiting for Connected state).")

		vim.api.nvim_win_set_buf(0, buf)
		local update_status = test_utils.get_lualine_status()
		assert(update_status:find("2 rows affected"), "Should show '2 rows affected'. Got: " .. update_status)

		cleanup()
	end,
}
