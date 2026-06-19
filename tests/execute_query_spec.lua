local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Queries should execute and show results",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbA" })

		local query = "SELECT * from TestDbA.dbo.Person join TestDbB.dbo.Car on Person.ID = Car.PersonId"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
		mssql.execute_query({ bufnr = buf })

		local res_buf, _, results = test_utils.res_buf_catcher()
		assert(res_buf, "Results buffer did not appear (Query likely failed).")
		assert(results:find("Bob"), "Sql query results do not contain Bob. Content:\n" .. results)
		assert(results:find("Hyundai"), "Sql query results do not contain Hyundai. Content:\n" .. results)

		test_utils.cleanup_results_buffer(res_buf)
		cleanup()
	end,
}
