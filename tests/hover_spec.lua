local test_utils = require("tests.utils")

return {
  test_name = "Hover should display table information",
  run_test_async = function()
    local buf, client, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })

    local query = "SELECT * FROM Car"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

    -- "Car" starts at col 14 (0-indexed: 14)
    vim.api.nvim_win_set_cursor(0, { 1, 14 })

	local result
	local attempts = 0
	local max_attempts = 20 -- 2 seconds (20 * 100ms)

	while attempts < max_attempts do
		local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
		local response, _ = client.request_sync("textDocument/hover", params, 1000, buf)

		if response and response.result and response.result.contents then
			result = response.result
			break
		end

		test_utils.defer_async(100)
		attempts = attempts + 1
	end

	assert(result, "Timeout: Hover returned no result after 2 seconds.")

    local contents = result.contents
	local hover_text = ""
	if type(contents) == "table" and contents[1] then
		hover_text = contents[1].value
	elseif type(contents) == "table" and contents.value then
		hover_text = contents.value
	end

	assert(
		hover_text:find("table TestDbB.dbo.Car"),
		"Hover text did not contain table name. Got: " .. vim.inspect(hover_text)
	)

    cleanup()
  end,
}
