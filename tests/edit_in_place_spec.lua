local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Editing an existing file in place (`:e`) should handle reconnection gracefully",
	run_test_async = function()
		local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })
		local query = "SELECT * from dbo.Car"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

		local new_file = "/tmp/edit_in_place_test.sql"
		vim.api.nvim_cmd({ cmd = "saveas", args = { new_file }, bang = true, mods = { silent = true } }, {})
		local saved_path = test_utils.poll(function()
			return vim.loop.fs_stat(new_file) ~= nil
		end)
		assert(saved_path, "File was not created at " .. new_file)

		vim.cmd("edit")
		local first_disconnects = test_utils.poll(function()
			return qm:get_state() ~= qm.states.connected
		end)
		assert(first_disconnects, "Need to disconnect first")

		local reconnected = test_utils.poll(function()
			return qm:get_state() == qm.states.connected
		end, { timeout_ms = 10000 })
		assert(reconnected, "QueryManager did not reconnect after :edit")

		mssql.execute_query(buf)
		local res_buf, _, _ = test_utils.res_buf_catcher()
		assert(res_buf, "Query failed after reload")

		test_utils.cleanup_results_buffer(res_buf)
		cleanup()
	end,
}
