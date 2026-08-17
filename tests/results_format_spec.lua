local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Query results should support JSON, CSV, and Text formatting",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDBA" })
		local query = "SELECT c.ID, p.Name, c.Make, c.PersonId from TestDbA.dbo.Person AS p INNER JOIN TestDbB.dbo.Car AS c on p.ID = c.PersonId"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

		-- test JSON
		test_utils.setup_mssql_async({ results_output_format = "json" })
		mssql.execute_query({ bufnr = buf })

		local res_buf_json, _, results_json = test_utils.res_buf_catcher()
		assert(res_buf_json, "JSON results buffer did not appear")
		local ok, decoded = pcall(vim.json.decode, results_json)
		assert(ok, "Results content is not valid JSON:\n" .. results_json)
		assert(#decoded > 0, "JSON array is empty")
		assert(decoded[1].Name ~= nil, "JSON object is missing 'Name' property")
		assert(decoded[1].Make ~= nil, "JSON object is missing 'Make' property")
		assert(vim.bo[res_buf_json].filetype == "json", "Results buffer filetype is not 'JSON': " .. " instead is: " .. vim.bo[res_buf_json].filetype)

		test_utils.cleanup_results_buffer(res_buf_json)

		-- test CSV
		test_utils.setup_mssql_async({ results_output_format = "csv" })
		mssql.execute_query({ bufnr = buf })

		local res_buf_csv, _, results_csv = test_utils.res_buf_catcher()
		assert(res_buf_csv, "CSV results buffer did not appear")
		assert(results_csv:find("ID,Name,Make,PersonId"), "CSV header is missing or incorrect:\n" .. results_csv)
		assert(results_csv:find("1,Bob,Merc,1"), "CSV row content is missing or incorrect:\n" .. results_csv)
		assert(vim.bo[res_buf_csv].filetype == "csv", "Results buffer filetype is not 'csv': " .. "instead is: " .. vim.bo[res_buf_csv].filetype)

		test_utils.cleanup_results_buffer(res_buf_csv)

		-- test "text"
		test_utils.setup_mssql_async({ results_output_format = "text" })
		mssql.execute_query({ bufnr = buf })

		local res_buf_text, _, results_text = test_utils.res_buf_catcher()
		assert(res_buf_text, "Text results buffer did not appear")
		assert(not results_text:find("|"), "Text table should not contain Markdown pipes:\n" .. results_text)
		assert(results_text:find("Bob%s+Merc"), "Text table columns are not formatted correctly:\n" .. results_text)
		assert(vim.bo[res_buf_text].filetype == "", "Results buffer filetype is not '': " .. "instead is: " .. vim.bo[res_buf_text].filetype)

		test_utils.cleanup_results_buffer(res_buf_text)

		test_utils.setup_mssql_async({ results_output_format = "markdown" })
		cleanup()
	end,
}
