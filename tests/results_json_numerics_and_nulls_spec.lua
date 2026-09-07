local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "JSON results should emit numerics as numbers and NULL as null",
	run_test_async = function()
		test_utils.setup_mssql_async({ results_output_format = "json" })
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbA" })

		-- numeric columns (ID, Age, PersonId, BigId) vs string columns (Name, Make)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT p.ID, p.Name, p.Age, CAST(p.ID AS BIGINT) AS BigId, c.Make, c.PersonId "
			.. "FROM TestDbA.dbo.Person AS p "
			.. "INNER JOIN TestDbB.dbo.Car AS c ON p.ID = c.PersonId",
		})
		mssql.execute_query({ bufnr = buf })

		local res_buf, _, results_json = test_utils.res_buf_catcher()
		assert(res_buf, "JSON results buffer did not appear")
		local ok, decoded = pcall(vim.json.decode, results_json)
		assert(ok, "Results content is not valid JSON:\n" .. results_json)
		assert(#decoded > 0, "JSON array is empty")

		local first = decoded[1]
		assert(type(first.ID) == "number", "ID should be a number, got " .. type(first.ID))
		assert(type(first.Age) == "number", "Age should be a number, got " .. type(first.Age))
		assert(type(first.PersonId) == "number", "PersonId should be a number, got " .. type(first.PersonId))
		assert(type(first.BigId) == "number", "BigId should be a number, got " .. type(first.BigId))
		assert(type(first.Name) == "string", "Name should be a string, got " .. type(first.Name))
		assert(type(first.Make) == "string", "Make should be a string, got " .. type(first.Make))

		test_utils.cleanup_results_buffer(res_buf)

		-- NULL should be emitted as JSON null (vim.NIL) not a dropped key
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT p.ID, CAST(NULL AS INT) AS NullableInt FROM TestDbA.dbo.Person AS p",
		})
		mssql.execute_query({ bufnr = buf })

		local res_buf2, _, results_null = test_utils.res_buf_catcher()
		assert(res_buf2, "NULL JSON results buffer did not appear")
		local ok2, decoded2 = pcall(vim.json.decode, results_null)
		assert(ok2, "NULL results content is not valid JSON:\n" .. results_null)
		assert(#decoded2 > 0, "NULL JSON array is empty")
		assert(decoded2[1].NullableInt == vim.NIL, "NULL should decode to vim.NIL, got " .. vim.inspect(decoded2[1].NullableInt))
		test_utils.cleanup_results_buffer(res_buf2)

		test_utils.setup_mssql_async({ results_output_format = "markdown" })
		cleanup()
	end,
}
