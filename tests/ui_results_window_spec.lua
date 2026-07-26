local ui = require("mssql.ui")
local test_utils = require("tests.utils")

return {
	test_name = "UI: results split window is isolated per tabpage and resets stale handles",
	run_test_async = function()
		-- create buffer and test split window in Tab 1
		local buf1 = vim.api.nvim_create_buf(false, true)
		ui.show_results_buffer_options.split(buf1)

		local win_tab1 = vim.t.mssql_results_win
		assert(win_tab1 ~= nil, "Should have created a results window in Tab 1")
		assert(vim.api.nvim_win_is_valid(win_tab1), "Tab 1 results should be valid")

		-- open tab 2 and verify tabpage isolation
		vim.cmd.tabnew()
		local buf2 = vim.api.nvim_create_buf(false, true)
		ui.show_results_buffer_options.split(buf2)

		local win_tab2 = vim.t.mssql_results_win
		assert(win_tab2 ~= nil, "Should have created a results window in Tab 2")
		assert(win_tab1 ~= win_tab2, "Tab 1 and Tab 2 must have distinct results windows")

		vim.cmd.tabclose({ bang = true })
		vim.api.nvim_win_close(win_tab1, true)

		-- running a split in a new buffer should create a new window cleanly
		local buf3 = vim.api.nvim_create_buf(false, true)
		ui.show_results_buffer_options.split(buf3)

		local win_tab1_new = vim.t.mssql_results_win
		assert(win_tab1_new ~= nil and win_tab1_new ~= win_tab1, "Closing window should reset handle and open a fresh window")

		test_utils.safe_buf_delete(buf1, { force = true })
		test_utils.safe_buf_delete(buf2, { force = true })
		test_utils.safe_buf_delete(buf3, { force = true })
	end,
}
