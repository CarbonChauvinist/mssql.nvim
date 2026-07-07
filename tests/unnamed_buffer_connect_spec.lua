local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Connecting an unnamed buffer should auto-rename and initialize LSP",
	run_test_async = function()
		test_utils.setup_mssql_async()

		-- admittedly this is an edge case (create unnamed buffer and explicitly set ft)
		vim.cmd("enew")
		local buf = vim.api.nvim_get_current_buf()
		vim.bo[buf].filetype = "sql"

		assert(vim.api.nvim_buf_get_name(buf) == "", "Buffer should initially be unnamed")

		test_utils.ui_select_fake("TestConnection")
		mssql.connect(buf)

		local new_name = vim.api.nvim_buf_get_name(buf)
		assert(new_name:match("untitled%-" .. buf .. "%.sql$"), "Buffer was not auto-renamed. Got: " .. new_name)

		local client = test_utils.wait_for_lsp_attach(buf)
		assert(client, "LSP failed to attach after auto-rename")

		test_utils.wait_for_intellisenseReady(buf, client)
		test_utils.wait_for_connected(buf)

		local query = "SELECT 1 AS result"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
		mssql.execute_query({ bufnr = buf })
		local res_buf, status, _ = test_utils.res_buf_catcher()

		assert(res_buf, "Results buffer did not appear.")
		assert(status, "Query failed to execute.")

		test_utils.cleanup_results_buffer(res_buf)
		test_utils.safe_buf_delete(buf, { force = true })
	end,
}
