local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Pagination should preserve the configured output format",
	run_test_async = function()
		test_utils.setup_mssql_async({ max_rows = 1 })
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })

		local query = "SELECT * FROM TestDbB.dbo.Car ORDER BY ID"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

		---@type { format: string, assert_format: fun(content: string): boolean }[]
		local formats = {
			{
				format = "csv",
				assert_format = function(content) return content:find("ID,Make,PersonId") ~= nil end,
			},
			{
				format = "json",
				assert_format = function(content) return pcall(vim.json.decode, content) end,
			},
			{
				format = "text",
				assert_format = function(content) return content:find("ID%s+Make") ~= nil end,
			},
		}

		for _, f in ipairs(formats) do
			test_utils.setup_mssql_async({ results_output_format = f.format, max_rows = 1 })
			mssql.execute_query({ bufnr = buf })

			local res_buf = test_utils.res_buf_catcher()
			assert(res_buf, f.format .. " results buffer did not appear")

			vim.api.nvim_win_set_buf(0, res_buf)
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-n>", true, true, true), "x", false)
			test_utils.wait_for_status("Rosws 2%-2 of 3", { bufnr = res_buf })

			local _, _, content = test_utils.res_buf_catcher({ res_buf = res_buf })
			assert(content and content:find("Ford"), "After pagination, " .. f.format .. " did not reach page 2:\n" .. tostring(content))
			assert(f.assert_format(content), "After pagination, " .. f.format .. " content lost its format:\n" .. content)
			assert(not content:find("|"), "After pagination, " .. f.format .. " content should not be Markdown:\n" .. content)
			test_utils.cleanup_results_buffer(res_buf)
		end

		test_utils.setup_mssql_async({ max_rows = 100, results_output_format = "markdown" })
		cleanup()
	end,
}
