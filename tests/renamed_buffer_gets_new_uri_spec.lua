local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Renaming a buffer (saveas) should allow reconnections with new URI",
	run_test_async = function()
		mssql.new_query()
		local buf = vim.api.nvim_get_current_buf()
		---@type vim.lsp.Client
		local client = test_utils.wait_for_lsp_attach(buf)

		test_utils.ui_select_fake("TestConnection")
		mssql.connect(buf)
		test_utils.wait_for_intellisenseReady(buf, client)

		test_utils.ui_select_fake("TestDbB")
		local query = "SELECT * from TestDbB.dbo.Car"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

		mssql.execute_query(buf)
		local res_buf, _, _results = test_utils.res_buf_catcher()
		assert(res_buf, "Results buffer did not appear (Query likely failed).")

		test_utils.cleanup_results_buffer(res_buf)
		vim.api.nvim_win_set_buf(0, buf)

		local new_file = "/tmp/saveas_test.sql"
		vim.api.nvim_cmd({ cmd = "saveas", args = { new_file }, bang = true, mods = { silent = true } }, {})

		local saved_path = test_utils.poll(function()
			return vim.loop.fs_stat(new_file) ~= nil
		end)
		assert(saved_path, "File was not created at " .. new_file)

		mssql.disconnect(buf)
		local dc_success = test_utils.poll(function()
			local qm = mssql.get_query_manager(buf)
			return qm and qm:get_state() == qm.states.Disconnected
		end)
		assert(dc_success, "Was not disconnected")

		test_utils.ui_select_fake("TestConnection")
		mssql.connect(buf)
		test_utils.wait_for_intellisenseReady(buf, client)

		test_utils.safe_buf_delete(buf, { force = true })
		os.remove(new_file)
	end,
}
