local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Executing multiple statements should show multiple results",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
		local query = "SELECT 1 AS FirstResult; SELECT 2 AS SecondResult;"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
		mssql.execute_query(buf)

		local results_map = test_utils.wait_for_multiple_result_buffers(2, { timeout_ms = 10000 })

		local found_first = false
		local found_second = false
		local combined_content = ""

		for _, content in pairs(results_map) do
			combined_content = combined_content .. "\n--BUF--\n" .. content
			if content:find("FirstResult") and content:find("1") then
				found_first = true
			end
			if content:find("SecondResult") and content:find("2") then
				found_second = true
			end
		end

		assert(found_first, "Could not find result set 1 (FirstResult). Got:\n" .. combined_content)
		assert(found_second, "Could not find result sert 2 (SecondResult). Got:\n" .. combined_content)

		test_utils.cleanup_multiple_buffers(results_map)
		cleanup()
	end,
}
