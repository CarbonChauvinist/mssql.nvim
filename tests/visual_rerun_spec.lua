local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Rerun last visual selection query using extmarks",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT 'first_selection';",
			"SELECT 'second_selection';",
		})

		-- 1. Perform first selection (line 1)
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd.normal({ args = { "V" }, bang = true })

		-- Execute query - this should save the selection range as extmarks
		mssql.execute_query({ bufnr = buf })

		-- Verify results of the first query
		local res_buf1, _, results1 = test_utils.res_buf_catcher()
		assert(res_buf1, "Results buffer did not appear for first query")
		assert(results1:find("first_selection"), "Expected first selection result, got:\n" .. tostring(results1))
		test_utils.cleanup_results_buffer(res_buf1)

		-- 2. Move cursor away to second line (not in visual mode)
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		-- Execute query with rerun_last = true
		mssql.execute_query({ bufnr = buf, rerun_last = true })

		-- Verify it reruns the first query
		local res_buf2, _, results2 = test_utils.res_buf_catcher()
		assert(res_buf2, "Results buffer did not appear for rerun query")
		assert(results2:find("first_selection"), "Expected rerun to execute first selection, got:\n" .. tostring(results2))
		test_utils.cleanup_results_buffer(res_buf2)

		-- 3. Modify the first line text to verify extmarks track edits
		vim.api.nvim_buf_set_text(buf, 0, 8, 0, 23, { "first_selection_modified" })

		-- Execute query with rerun_last = true again
		mssql.execute_query({ bufnr = buf, rerun_last = true })

		-- Verify it reruns the modified query
		local res_buf3, _, results3 = test_utils.res_buf_catcher()
		assert(res_buf3, "Results buffer did not appear for modified rerun query")
		assert(results3:find("first_selection_modified"), "Expected rerun to track changes and execute modified query, got:\n" .. tostring(results3))
		test_utils.cleanup_results_buffer(res_buf3)

		cleanup()
	end,
}
