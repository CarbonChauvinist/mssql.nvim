local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Pagination should fetch new pages and update statusline",
	run_test_async = function()
		-- Override max_rows to 1 to force pagination
		test_utils.setup_mssql_async({ max_rows = 1 })
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })

		-- Execute query that returns 3 rows (from seed.sql)
		local query = "SELECT * FROM TestDbB.dbo.Car ORDER BY ID"
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { query })
		mssql.execute_query(buf)

		--- Helper for repetitive assertions
		---@param res_buf integer Results buffer to parse
		---@param expected_car string Car expected to be in single results row
		---@param expected_status string Text expected to be found in status line
		local function assert_page(res_buf, expected_car, expected_status)

			test_utils.wait_for_status(expected_status, { timeout_ms = 3000, bufnr = res_buf })

			local content = ""

			local found_content = test_utils.poll(function()
				local _, res_buf_exists, text = test_utils.res_buf_catcher({ res_buf = res_buf })
				if res_buf_exists and text then
					content = text
					if content:find(expected_car) then
						return true
					end
				end
				return false
			end)

			assert(found_content,
				"Page should contain '"
				.. expected_car
				.. "'. Status: "
				.. expected_status
				.. "\nGot Buffer Content:\n:"
				.. (content or "nil")
			)
			local all_cars = {"Merc", "Ford", "Hyundai"}
			for _, car in ipairs(all_cars) do
				if car ~= expected_car then
					assert(not content:find(car), "Page should NOT contain '" .. car .. "'")
				end
			end
		end

		-- Initial Page (Page 1)
		local res_buf = test_utils.res_buf_catcher()
		assert_page(res_buf, "Merc", "Rows 1%-1 of 3")

		-- Next Page (Page 2)
		-- have to set window to results buffer since we'll be using nvim_feedkeys to test pagination
		vim.api.nvim_win_set_buf(0, res_buf)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-n>", true, true, true), "x", false)
		assert_page(res_buf, "Ford", "Rows 2%-2 of 3")

		-- Previous Page (Page 1)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-p>", true, true, true), "x", false)
		assert_page(res_buf, "Merc", "Rows 1%-1 of 3")

		-- Last Page (Page 3)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-M-n>", true, true, true), "x", false)
		assert_page(res_buf, "Hyundai", "Rows 3%-3 of 3")

		-- First Page (Page 1)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-M-p>", true, true, true), "x", false)
		assert_page(res_buf, "Merc", "Rows 1%-1 of 3")

		test_utils.cleanup_results_buffer(res_buf)
		test_utils.setup_mssql_async({ max_rows = 100 })
		cleanup()
	end,
}
