local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Executing a USE statement should switch database",
	run_test_async = function()
		local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
		local query = "USE TestDbB;"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
		mssql.execute_query(buf)

		local current_db = ""
		local attempts = 0
		local max_attempts = 50 -- 5 seconds
		while attempts < max_attempts do
			test_utils.defer_async(100)
			local params = qm and qm:get_connect_params()
			if params and params.connection and params.connection.options then
				current_db = params.connection.options.database
			end

			if current_db == "TestDbB" then
				break
			end
			attempts= attempts + 1
		end

		assert(current_db == "TestDbB", "Expected database to be TestDbB but instead it's " .. tostring(current_db))
		cleanup()
	end,
}
