local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Long column values should be truncated based on max_column_width",
	run_test_async = function()
		test_utils.setup_mssql_async({ max_column_width = 10 })
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
		local query = "SELECT '12345678901234567890' AS TruncatedCol"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
		mssql.execute_query(buf)

		local res_buf, status, results = test_utils.res_buf_catcher()
		assert(status, "Results buffer did not appear.")

		-- logic: str:sub(1, limit) .. "..."
		local expected = "1234567890..."

		assert(
			results:find(expected, 1, true),
			"Results should contain truncated string '" .. expected .. "'. Got:\n" .. results
		)

		assert(
			not results:find("12345678901234567890", 1, true),
			"Results should NOT contain the full untruncated string."
		)

		test_utils.cleanup_results_buffer(res_buf)
		test_utils.setup_mssql_async({ max_column_width = 100 })
		cleanup()
	end,
}
