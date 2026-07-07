local test_utils = require("tests.utils")

return {
  test_name = "Hover should display table information",
  run_test_async = function()
    local buf, client, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })

    local query = "SELECT * FROM Car"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

    -- "Car" starts at col 14 (0-indexed: 14)
    vim.api.nvim_win_set_cursor(0, { 1, 14 })

	local hover_contents
	local hover_success = test_utils.poll(function()
			local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
			local response, _ = client:request_sync("textDocument/hover", params, 1000, buf)

			if response and response.result and response.result.contents then
				hover_contents = response.result.contents
				return true
			end

			return false
		end)

	assert(hover_success, "Timeout: Hover returned no result after 2 seconds.")

	local hover_text = ""
	if type(hover_contents) == "table" and hover_contents[1] then
		hover_text = hover_contents[1].value
	elseif type(hover_contents) == "table" and hover_contents.value then
		hover_text = hover_contents.value
	end

	assert(
		hover_text:find("table TestDbB.dbo.Car"),
		"Hover text did not contain table name. Got: " .. vim.inspect(hover_text)
	)

    cleanup()
  end,
}
