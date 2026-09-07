local utils = require("mssql.utils")

return {
	test_name = "build_selection_range should clamp linewise end columns and keep absolute lines",
	run_test_async = function()
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT 'a'", -- 10 bytes
			"SELECT 'bb'", -- 11 bytes
			"SELECT 'ccc'" -- 12 bytes
		})

		-- Linewise visual after exit: '> column is vim.v.maxcol (2147483647)
		local r = utils.build_selection_range(buf, { 0, 1, 1, 0 }, { 0, 3, 2147483647, 0 }, "V")
		assert(r.start_line == 0, "start_line should be 0, got " .. r.start_line)
		assert(r.end_line == 2, "end_line should be 2 (absolute), got " .. r.end_line)
		assert(r.end_col == 12, "end_col should clamp to line length 12, got " .. r.end_col)

		-- Linewise visual while active: '> column is 1, still spans the full line
		local r_active = utils.build_selection_range(buf, { 0, 3, 1, 0 }, { 0, 3, 1, 0 }, "V")
		assert(r_active.end_line == 2, "end_line should be 2, got " .. r_active.end_line)
		assert(r_active.end_col == 12, "linewise '>' col 1 should span the full line, got " .. r_active.end_col)

		-- Char-wise visual: in-range end column is preserved
		local r2 = utils.build_selection_range(buf, { 0, 1, 1, 0 }, { 0, 2, 6, 0 }, "v")
		assert(r2.end_line == 1, "end_line should be 1, got " .. r2.end_line)
		assert(r2.end_col == 5, "char-wise end_col should be unchanged, got " .. r2.end_col)

		-- Empty last line clamps to 0
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "" })
		local r3 = utils.build_selection_range(buf, { 0, 1, 1, 0 }, { 0, 2, 2147483647, 0 }, "V")
		assert(r3.end_col == 0, "empty last line should clamp to 0, got " .. r3.end_col)

		vim.api.nvim_buf_delete(buf, { force = true })
	end,
}
