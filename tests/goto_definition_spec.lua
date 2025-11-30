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
		local attempts = 0
		local max_attempts = 30

		while attempts < max_attempts do
			local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
				local response, _ = client.request_sync("textDocument/definition", params, 500, buf)

			if response and response.result and not vim.tbl_isempty(response.result) then
				result = response.result
				break
			end

			test_utils.defer_async(250)
			attempts = attempts + 1
		end

		assert(result, "Timeout: Goto Definition returned no result after 15 seconds.")
		local location = result[1] or result
		assert(location.uri, "Definition result missing URI")
		assert(location.range, "Definition result missing Range")
		assert(location.uri:find(object) or location.uri:find(vim.split(object, ".")[2]), "Definition URI should contain the object name: Got: " .. location.uri)
		print(vim.api.nvim_buf_get_name(0))

		vim.lsp.buf.definition()
		local jump_success = vim.wait(20000, function()
			return vim.api.nvim_get_current_buf() ~= buf
		end, 500)
		assert(jump_success, "Timeout: Editor did not jump to new buffer.")

		local new_buf = vim.api.nvim_get_current_buf()
		local new_buf_name = vim.api.nvim_buf_get_name(new_buf)
		local new_buf_content = test_utils.get_buffer_content(new_buf)
		local expected_name = vim.fn.substitute(location.uri, "file:", "", "")

		assert(new_buf_name == expected_name, "Opened buffer does not match expected name. Expected: " .. expected_name .. " but got: " .. new_buf_name)
		assert(new_buf_content:find("CREATE VIEW"), "Definition buffer content does not match expected pattern:\n" .. new_buf_content)
		test_utils.safe_buf_delete(new_buf, { force = true })
		cleanup()
	end,
}
