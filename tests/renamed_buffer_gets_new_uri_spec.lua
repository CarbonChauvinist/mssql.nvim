local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Renaming a buffer (saveas) transfers session to new URI via query/connectionUriChanged",
	run_test_async = function()
		mssql.new_query()
		local buf = vim.api.nvim_get_current_buf()
		---@type vim.lsp.Client
		local _client = test_utils.wait_for_lsp_attach(buf)

		test_utils.ui_select_fake("TestConnection")
		mssql.connect(buf)
		test_utils.wait_for_connected(buf)
		local qm = mssql.get_query_manager(buf)
		assert(qm, "QueryManager should exist")

		local old_uri = qm:get_owner_uri()

		test_utils.ui_select_fake("TestDbB")
		local query = "SELECT * from TestDbB.dbo.Car"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

		mssql.execute_query({ bufnr = buf })
		local res_buf, _, _ = test_utils.res_buf_catcher()
		assert(res_buf, "Results buffer did not appear for initial query.")
		test_utils.cleanup_results_buffer(res_buf)
		vim.api.nvim_win_set_buf(0, buf)

		-- Save buffer to a new file location on disk (triggers BufWritePost -> query/connectionUriChanged)
		local new_file = vim.fn.tempname() .. ".sql"
		local new_uri
		vim.cmd.saveas({ args = { new_file }, bang = true, mods = { silent = true } })

		local got_new_uri = test_utils.poll(function()
			new_uri = qm:get_owner_uri()
			return new_uri ~= old_uri
		end)
		assert(got_new_uri, "QueryManager ownerUri should have updated to new file URI")
		assert(qm:get_state() == qm.states.connected, "Session should remain connected after URI transfer")

		-- Execute on renamed buffer to verify STS execution session was transferred successfully
		mssql.execute_query({ bufnr = buf })
		local new_res_buf, status, results = test_utils.res_buf_catcher()
		assert(status and results:find("Merc"), "Query results verification failed after URI transfer.")
		test_utils.cleanup_results_buffer(new_res_buf)

		test_utils.safe_buf_delete(buf, { force = true })
		os.remove(new_file)
	end,
}
