local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Non ascii characters should render properly",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbA" })

		local query = "select * from dbo.PersonNonAscii"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
		mssql.execute_query()

		local res_buf, _, results_str = test_utils.res_buf_catcher()
		local lines = vim.split(results_str, "\n")

		test_utils.assert_visual_alignment(lines)
		test_utils.cleanup_results_buffer(res_buf)
		cleanup()
	end,
}
