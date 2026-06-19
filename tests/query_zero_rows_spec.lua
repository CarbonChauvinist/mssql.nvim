local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Queries returning zero rows should work",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })

		local query = "SELECT * from dbo.Car WHERE 1=0"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

		mssql.execute_query({ bufnr = buf })

		local res_buf, _, results = test_utils.res_buf_catcher()
		assert(res_buf, "Sql query with zero result rows are not opening a results buffer.")
		assert(results:find("Make"), "Sql query results with zero rows are not showing the column headings")

		test_utils.cleanup_results_buffer(res_buf)
		cleanup()
	end,
}
