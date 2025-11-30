local test_utils = require("tests.utils")

return {
	test_name = "Autocomplete should include database objects in cross db queries",
	run_test_async = function()
		local buf, _,  _, cleanup = test_utils.test_scaffold({ target_db = "TestDbA" })
		test_utils.wait_for_completion_item(buf, "Person", { text = "select * from TestDbA.dbo." })
		test_utils.defer_async(500)
		test_utils.wait_for_completion_item(buf, "Car", { text = "select * from TestDbA.dbo.Person join TestDbB.dbo." })
		cleanup()
	end,
}
