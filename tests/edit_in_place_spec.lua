local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Editing an existing file in place (`:e`) should handle reconnection gracefully",
	run_test_async = function()
		local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })
		local query = "SELECT * from dbo.Car"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

		local temp_file = vim.fn.tempname() .. ".sql"
		vim.api.nvim_cmd({ cmd = "saveas", args = { temp_file }, bang = true, mods = { silent = true } }, {})
		vim.cmd("edit!")

		local first_disconnects = test_utils.poll(function()
			return qm:get_state() ~= qm.states.connected
		end)
		assert(first_disconnects, "Need to disconnect first")

		local then_reconnects = test_utils.poll(function()
			return qm:get_state() == qm.states.connected
		end, { timeout_ms = 10000 })
		assert(then_reconnects, "QueryManager did not reconnect after :edit")

		mssql.execute_query(buf)
		local res_buf, status, results = test_utils.res_buf_catcher()
		assert(status and results:find("Merc"), "Query results verification failed after reload.")

		test_utils.cleanup_results_buffer(res_buf)
		cleanup()
		os.remove(temp_file)
	end,
}
