local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Embedded newlines should be escaped in 'text' query results",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
		local query = "SELECT 'Line1' + CHAR(10) + 'Line2' AS NewLineCol;"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
		mssql.execute_query({ bufnr = buf })

		local res_buf, status, results = test_utils.res_buf_catcher()
		assert(status, "Results buffer did not appear.")

		-- Expectation: sanitise() replaces \n with `\n` (backtick, backslash, n, backtick)
		local expected = "Line1`\\n`Line2"
		assert(
			results:find(expected, 1, true),
			"Results should contain escaped newline '" .. expected .. "' Got:\n:" .. results
		)

		test_utils.cleanup_results_buffer(res_buf)
		cleanup()
	end,
}
