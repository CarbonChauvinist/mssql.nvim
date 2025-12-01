local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Finder should work",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })

		test_utils.wait_for_cache_content("dbo.Car", {type = "Table"})
		test_utils.ui_select_fake("dbo.Car")
		-- run finder which generates SELECT * FROM Car and executes it
		mssql.find_object(buf)

		local res_buf, _, results = test_utils.res_buf_catcher()
		assert(results:find("Hyundai"), "Sql query results do not contain Hyundai: " .. results)

		test_utils.cleanup_results_buffer(res_buf)
		cleanup()
	end,
}
