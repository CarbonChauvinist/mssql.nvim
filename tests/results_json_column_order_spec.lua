local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "JSON results should preserve column order in object keys",
	run_test_async = function()
		test_utils.setup_mssql_async({ results_output_format = "json" })
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbA" })

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT p.ID, p.Name, p.Age FROM TestDbA.dbo.Person AS p",
		})
		mssql.execute_query({ bufnr = buf })

		local res_buf, _, results_json = test_utils.res_buf_catcher()
		assert(res_buf, "JSON results buffer did not appear")

		local id_pos = results_json:find('"ID"', 1, true)
		local name_pos = results_json:find('"Name"', 1, true)
		local age_pos = results_json:find('"Age"', 1, true)
		assert(id_pos and name_pos and age_pos, "expected ID/Name/Age keys:\n" .. results_json)
		assert(id_pos < name_pos and name_pos < age_pos, "JSON keys not in SELECT order (requires jq >= 1.6):\n" .. results_json)

		test_utils.cleanup_results_buffer(res_buf)

		test_utils.setup_mssql_async({ results_output_format = "markdown" })
		cleanup()
	end,
}
