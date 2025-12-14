local test_utils = require("tests.utils")

return {
	test_name = "LSP formatting should correctly format TSQL",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
		local bad_sql = "select * from     sys.tables where name='something'"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { bad_sql })

		vim.lsp.buf.format({ bufnr = buf, async = false})
		local formatted = test_utils.poll(function()
			local content = test_utils.get_buffer_content(buf)
			return content:find("SELECT") and content:find("FROM")
		end)

		assert(formatted, "Buffer was not formatted")
		local content = test_utils.get_buffer_content(buf)
		assert(content:find("SELECT"), "Keywords not uppercased")
		assert(not content:find("     "), "Excess whitespace not removed")

		cleanup()
	end,
}
