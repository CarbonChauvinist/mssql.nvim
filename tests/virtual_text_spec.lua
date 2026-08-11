local test_utils = require("tests.utils")
local mssql = require("mssql")

--- poll for virtual text extmark in the mssql_virtual_text namespace
--- and return the concatenated text chunks, or nil if not found
---@param bufnr integer
---@ns string
---@start_line <int, int>
---@end_line <int, int>
---@return string?
local get_virtual_text_at_bufnr = function(bufnr, ns, start_line, end_line)
	start_line = start_line or 0
	end_line = end_line or vim.api.nvim_buf_line_count(bufnr)
	local extmarks = vim.api.nvim_buf_get_extmarks(
		bufnr,
		ns,
		{ start_line, 0 },
		{ end_line, -1 },
		{ details = true }
	)

	local virtual_text_chunks = {}
	for _, mark in ipairs(extmarks) do
		local details = mark[4]
		if details and details.virt_text then
			for _, chunk in ipairs(details.virt_text) do
				table.insert(virtual_text_chunks, chunk[1])
			end
		end

		if details and details.virt_lines then
			for _, line_chunks in ipairs(details.virt_lines) do
				for _, chunk in ipairs(line_chunks) do
					table.insert(virtual_text_chunks, chunk[1])
				end
			end
		end
	end

	if #virtual_text_chunks > 0 then
		return table.concat(virtual_text_chunks, "")
	end
	return nil
end

return {
	test_name = "Scalar Virtual Text: placement, multi-batch, guards, and clearing",
	run_test_async = function()
		test_utils.setup_mssql_async({
			display_scalar_as_virtual_text = true,
		})

		local buf, _, _qm, cleanup = test_utils.test_scaffold({ "TestDbA" })
		local ns = vim.api.nvim_create_namespace("mssql_virtual_text")

		-- 1. single line scalar query renders virtual text at line 1 (0-indexed line 0)
		-- via execute_current_statement
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT count(*) FROM TestDbA.dbo.Person"
		})
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		mssql.execute_current_statement()
		test_utils.poll(function()
			return get_virtual_text_at_bufnr(buf, ns, 0, 0) ~= nil
		end, { timeout_ms = 5000, interval_ms = 100 })

		local ext = get_virtual_text_at_bufnr(buf, ns, 0, 0)
		assert(ext ~= nil, "[1] extmark should exist on line 0")
		assert(ext:match("=> %d+"), "[1] should display scalar number")

		-- 2. multi-line query renders virtual text at ending line 4 (0-indexed line 3)
		-- via execute_current_statement, virtual text at statement's ending line (0-indexed line 3)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT",
			"    count(*)",
			"FROM",
			"    TestDbA.dbo.Person;",
		})
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		mssql.execute_current_statement()
		test_utils.poll(function()
			return get_virtual_text_at_bufnr(buf, ns, 3, 3) ~= nil
		end, { timeout_ms = 5000, interval_ms = 100 })

		ext = get_virtual_text_at_bufnr(buf, ns, 3, 3)
		assert(ext ~= nil, "[2] extmark should exist on line 3")
		assert(ext:match("=> %d+"), "[2] should display scalar number")

		-- 3. clear_virtual_text removes all extmarks
		mssql.clear_virtual_text(buf)
		assert(get_virtual_text_at_bufnr(buf, ns, 0, -1) == nil, "[3] all extmarks should be cleared")

		-- 4. full buffer GO-separated batches (1 result set each) -> virt text on both
		-- note batch-0 virt text lands on the GO line (endLine=1), not the
		-- SELECT line - the server includes GO in the batch's selection range.
		mssql.clear_virtual_text(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT count(*) FROM TestDbA.dbo.Person;",
			"GO",
			"SELECT count(*) FROM TestDbA.dbo.Person;",
		})
		mssql.execute_query({ bufnr = buf })
		test_utils.poll(function()
			return get_virtual_text_at_bufnr(buf, ns, 1, 1) ~= nil
				and get_virtual_text_at_bufnr(buf, ns, 2, 2) ~= nil
		end, { timeout_ms = 5000, interval_ms = 100 })

		ext = get_virtual_text_at_bufnr(buf, ns, 1, 1)
		assert(ext ~= nil, "[4a] batch-0 extmark on line 1")
		assert(ext:match("=> %d+"), "[4a] batch-0 scalar")
		ext = get_virtual_text_at_bufnr(buf, ns, 2, 2)
		assert(ext ~= nil, "[4b] batch-1 extmark on line 2")
		assert(ext:match("=> %d+"), "[4b] batch-1 scalar")

		-- 5. single batch, 2 scalar results sets (semicolon, no GO)
		-- result_set_count > 1 -> guard -? results buffers, no virt text
		mssql.clear_virtual_text(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT count(*) AS cnt_a FROM TestDbA.dbo.Person;",
			"SELECT count(*) AS cnt_b FROM TestDbA.dbo.Person;",
		})
		mssql.execute_query({ bufnr = buf })
		local res_bufs = test_utils.wait_for_multiple_result_buffers(2)
		assert(vim.tbl_count(res_bufs) == 2, "[5] two (2) results buffers should appear")

		local seen = {}
		for _, content in pairs(res_bufs) do
			if content:find("cnt_a") then seen.cnt_a = true end
			if content:find("cnt_b") then seen.cnt_b = true end
		end
		assert(seen.cnt_a and seen.cnt_b, "[5] both SELECT results should appear in the result buffers")
		assert(get_virtual_text_at_bufnr(buf, ns, 0, -1) == nil, "[5] no virtual text when result_set_count > 1")
		test_utils.cleanup_multiple_buffers(res_bufs)


		-- 6. non-scalar query (multi-column) -> results buffer, no virt text
		mssql.clear_virtual_text(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT * FROM TestDbA.dbo.Person",
		})
		mssql.execute_query({ bufnr = buf })
		local res_buf = test_utils.wait_for_results_buffer()
		assert(res_buf ~= nil, "[6] results buffer should appear")
		assert(get_virtual_text_at_bufnr(buf, ns, 0, -1) == nil, "[6] no virtual text for multi-column query")
		test_utils.cleanup_results_buffer(res_buf)

		-- 7. execute_virtual_text explicit command (<mssql-leader>xv)
		mssql.clear_virtual_text(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT 42"
		})
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		mssql.execute_virtual_text()
		test_utils.poll(function()
			return get_virtual_text_at_bufnr(buf, ns, 0, 0) ~= nil
		end, { timeout_ms = 5000, interval_ms = 100 })

		ext = get_virtual_text_at_bufnr(buf, ns, 0, 0)
		assert(ext ~= nil, "[7] execute_virtual_text should place extmark on line 0")
		assert(ext:match("=> 42"), "[7] should display ' => 42'")

		-- 8. visual selection with display_scalar_as_virtual_text
		mssql.clear_virtual_text(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT 99 AS visual_test"
		})
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd.normal({ args = { "V" }, bang = true })
		mssql.execute_query({ bufnr = buf })
		test_utils.poll(function()
			return get_virtual_text_at_bufnr(buf, ns, 0, 0) ~= nil
		end, { timeout_ms = 5000, interval_ms = 100 })

		ext = get_virtual_text_at_bufnr(buf, ns, 0, 0)
		assert(ext ~= nil, "[8] visual selection scalar should show virt text")
		assert(ext:match("=> 99"), "[8] should display ' => 99'")

		-- 9. execute_virtual_text on a non-scalar query -> result buffer
		mssql.clear_virtual_text(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT * FROM TestDbA.dbo.Person"
		})
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		mssql.execute_virtual_text()
		local res_buf2 = test_utils.wait_for_results_buffer()
		assert(res_buf2 ~= nil, "[9] non-scalar via execute_virtual_text should create results buffer")
		assert(get_virtual_text_at_bufnr(buf, ns, 0, -1) == nil, "[9] no virtual text for non-scalar execute_virtual_text")
		test_utils.cleanup_results_buffer(res_buf2)

		-- 10. NULL scalar displays "NULL"
		mssql.clear_virtual_text(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT NULL" })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		mssql.execute_current_statement()
		test_utils.poll(function()
			return get_virtual_text_at_bufnr(buf, ns, 0, 0) ~= nil
		end, { timeout_ms = 5000, interval_ms = 100 })

		ext = get_virtual_text_at_bufnr(buf, ns, 0, 0)
		assert(ext ~= nil, "[10] NULL scalar should show virt text")
		assert(ext:match("=> NULL"), "[10] should display ' => NULL', got: " .. tostring(ext))

		cleanup()
		test_utils.setup_mssql_async({
			display_scalar_as_virtual_text = false,
		})
	end,

}
