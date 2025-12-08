local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Renaming a buffer (saveas) should allow reconnections with new URI",
	run_test_async = function()
		test_utils.setup_mssql_async({ auto_connect_on_rename = true })
		mssql.new_query()
		local buf = vim.api.nvim_get_current_buf()
		---@type vim.lsp.Client
		local client = test_utils.wait_for_lsp_attach(buf)

		test_utils.ui_select_fake("TestConnection")
		mssql.connect(buf)
		test_utils.wait_for_intellisenseReady(buf, client)
		local qm = mssql.get_query_manager(buf)

		test_utils.ui_select_fake("TestDbB")
		local query = "SELECT * from TestDbB.dbo.Car"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

		mssql.execute_query(buf)
		local res_buf, _, _ = test_utils.res_buf_catcher()
		assert(res_buf, "Results buffer did not appear (Query likely failed).")

		test_utils.cleanup_results_buffer(res_buf)
		vim.api.nvim_win_set_buf(0, buf)

		local new_file = "/tmp/saveas_test.sql"
		vim.api.nvim_cmd({ cmd = "saveas", args = { new_file }, bang = true, mods = { silent = true } }, {})

		local saved_path = test_utils.poll(function()
			return vim.loop.fs_stat(new_file) ~= nil
		end)
		assert(saved_path, "File was not created at " .. new_file)

		local reconnected = test_utils.poll(function()
			return qm:get_state() == qm.states.connected
		end)
		assert(reconnected, "Did not auto-reconnect after rename")

		mssql.execute_query(buf)
		local new_res_buf, _, _, _ = test_utils.res_buf_catcher()
		assert(new_res_buf, "Query failed after rename")
		test_utils.cleanup_results_buffer(new_res_buf)

		test_utils.safe_buf_delete(buf, { force = true })
		os.remove(new_file)
	end,
}
