local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Results buffer should toggle between output formats",
	run_test_async = function()
		test_utils.setup_mssql_async({ results_output_format = "markdown" })
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })
		local query = "SELECT * FROM TestDbB.dbo.Car ORDER BY ID"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

		mssql.execute_query({ bufnr = buf })
		local res_buf = test_utils.res_buf_catcher()
		assert(res_buf, "Results buffer did not appear")
		assert(vim.bo[res_buf].filetype == "markdown", "Initial filetype should be markdown")

		vim.api.nvim_win_set_buf(0, res_buf)

		-- cycle: markdown -> json -> csv -> text -> markdown
		for _, expected in ipairs({ "json", "csv", "", "markdown" }) do
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gf", true, true, true), "x", false)
			local toggled = test_utils.poll(function()
				return vim.bo[res_buf].filetype == expected
			end)
			assert(toggled, "Toggle did not switch filetype to '" .. expected .. "' (got: '" .. vim.bo[res_buf].filetype .. "')")
		end

		test_utils.cleanup_results_buffer(res_buf)
		cleanup()
	end,
}
