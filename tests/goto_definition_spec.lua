local test_utils = require("tests.utils")

return {
	test_name = "Go to definition should return object in new buffer",
	run_test_async = function()
		local buf, client, _, cleanup = test_utils.test_scaffold({ target_db = "msdb" })

		local object = "sys.views"
		local query = "SELECT * FROM " .. object
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
		vim.api.nvim_win_set_cursor(0, { 1, 18 })

		local result
		local expected_uri
		local ready = test_utils.poll(function()
			local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
			local res, _ = client:request_sync("textDocument/definition", params, 500, buf)

			if res and res.result and not vim.tbl_isempty(res.result) then
				local loc = res.result[1] or result.result
				expected_uri = loc.uri
				return true
			end
			return false
		end, { timeout_ms = 15000 })

		assert(ready, "Timeout: Server did not return a definition location.")
		vim.lsp.buf.definition()

		local jump_success = test_utils.poll(function()
			return vim.api.nvim_get_current_buf() ~= buf
		end, { timeout_ms = 20000, interval = 500})

		assert(jump_success, "Timeout: Editor did not jump to new buffer.")

		local def_buf = vim.api.nvim_get_current_buf()
		local def_buf_name = vim.api.nvim_buf_get_name(def_buf)
		local expected_path = vim.uri_to_fname(expected_uri)

		local expected_dir = vim.fs.dirname(expected_path)
		local got_dir = vim.fs.dirname(def_buf_name)
		local got_file = vim.fs.basename(def_buf_name)
		assert(got_dir == expected_dir, "Opened buffer directory does not match. Expected: " .. expected_dir .. " but got: " .. got_dir)
		assert(got_file:match("^sys%.views_") and got_file:match("%.sql$"), "Opened buffer filename is incorrect: " .. got_file)
		local content = test_utils.get_buffer_content(def_buf)
		assert(content:find("CREATE VIEW"), "Definition buffer content does not match expected pattern:\n" .. content)

		test_utils.safe_buf_delete(def_buf, { force = true })
		cleanup()
	end,
}
