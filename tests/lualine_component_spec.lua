local mssql = require("mssql")
local test_utils = require("tests.utils")
local qmm = require("mssql.query_manager")

return {
	test_name = "Lualine component should display elapsed time and rows affected",
	run_test_async = function()
		local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

		-- test live query execution stats
		local query_long = "WAITFOR DELAY '00:00:03'; SELECT 1 AS Test;"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query_long })
		mssql.execute_query()

		local status
		local attempts = 0
		while attempts < 20 do
			status = test_utils.get_lualine_status() or ""
			if status:find("Executing") then break end
			test_utils.defer_async(50)
			attempts = attempts + 1
		end
		assert(status:find("Executing"), "Lualine should show 'Executing...'. Got " .. status)
		assert(status:find("%d?%d?:?%d%d:%d%d$"), "Lualine should show timer. Got: " .. status)
		local res_buf, _, _ = test_utils.res_buf_catcher()
		vim.api.nvim_win_set_buf(0, buf)

		local final_status = test_utils.get_lualine_status()
		assert(final_status, "Status should not be nil.")
		assert(final_status:find("1 row affected"), "Should show '1 row affected'. Got: " .. final_status)
		assert(final_status:find("%d%d:%d%d.%d+"), "Should show final time with ms. Got: " .. final_status)

		test_utils.cleanup_results_buffer(res_buf)

		-- test DML
		local query_update = "SELECT * INTO #test_temp FROM (VALUES (1), (2)) AS t(c); UPDATE #test_temp SET c = c + 1;"
		vim.api.nvim_buf_set_lines(buf, 1, -1, false, { query_update })
		mssql.execute_query()

		attempts = 0
		while qm:get_state() ~= qmm.states.Connected and attempts < 100 do
			test_utils.defer_async(50)
			attempts = attempts + 1
		end
		vim.api.nvim_win_set_buf(0, buf)
		local update_status = test_utils.get_lualine_status()
		assert(update_status:find("2 rows affected"), "Should show '2 rows affected'. Got: " .. update_status)

		cleanup()
	end,
}
