local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Executing a USE statement should switch database",
	run_test_async = function()
		local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
		local query = "USE TestDbB;"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
		mssql.execute_query({ bufnr = buf })

		local current_db = ""
		local switch_success = test_utils.poll(function()
			local params = qm and qm:get_connect_params()
			if params and params.connection and params.connection.options then
				current_db = params.connection.options.database
			end

			return current_db == "TestDbB"
		end)

		assert(switch_success, "Database switch timed out. Expected 'TestDbB', but got: " .. tostring(current_db))
		cleanup()
	end,
}
