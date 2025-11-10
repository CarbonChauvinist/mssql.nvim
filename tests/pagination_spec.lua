local mssql = require("mssql")
local utils = require("mssql.utils")
local test_utils = require("tests.utils")

return {
	test_name = "Pagination should fetch new pages and update statusline",
	run_test_async = function()
		-- 1. Override max_rows to 1 to force pagination
		-- The seed.sql file creates 3 rows in TestDbB.dbo.Car
		utils.log_info("Setting max_rows = 1")
		test_utils.setup_mssql_async({ max_rows = 1 })
		utils.wait_for_schedule_async()

		-- 2. Execute query that returns 3 rows (from seed.sql)
		local query = "SELECT * FROM TestDbB.dbo.Car ORDER BY ID"
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { query })
		utils.wait_for_schedule_async()
		mssql.execute_query()

		-- Wait for query to complete
		local client = vim.lsp.get_clients({ name = "mssql_ls", bufnr = 0 })[1]
		local buf = vim.api.nvim_get_current_buf()
		local _, err = utils.wait_for_notification_async(buf, client, "query/complete", 30000)
		if err then
			error(err.message)
		end
		test_utils.defer_async(2000)

		-- 3. Check Page 1
		utils.log_info("Checking Page 1")
		local results_buf = test_utils.get_results_buffer()
		assert(results_buf, "Could not find results buffer")

		-- Switch focus to the results buffer so lualine component updates
		vim.api.nvim_set_current_buf(results_buf)
		utils.wait_for_schedule_async()

		local content_p1 = test_utils.get_buffer_content(results_buf)
		local status_p1 = test_utils.get_lualine_status()

		assert(content_p1:find("Merc"), "Page 1 should contain 'Merc'")
		assert(not content_p1:find("Ford"), "Page 1 should NOT contain 'Ford'")
		assert(not content_p1:find("Hyundai"), "Page 1 should NOT contain 'Hyundai'")
		assert(status_p1:find("Rows 1%-1 of 3"), "Lualine status should be 'Rows 1-1 of 3', but was: " .. status_p1)

		-- 4. Test '<C-n>' (Page Down)
		utils.log_info("Checking Page 2 (pressing <C-n>)")
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-n>", true, true, true), "x", false)
		test_utils.wait_for_status("Rows 2%-2 of 3", 3000)

		local content_p2 = test_utils.get_buffer_content(results_buf)
		local status_p2 = test_utils.get_lualine_status()

		assert(not content_p2:find("Merc"), "Page 2 should NOT contain 'Merc'")
		assert(content_p2:find("Ford"), "Page 2 should contain 'Ford'")
		assert(not content_p2:find("Hyundai"), "Page 2 should NOT contain 'Hyundai'")
		assert(status_p2:find("Rows 2%-2 of 3"), "Lualine status should be 'Rows 2-2 of 3', but was: " .. status_p2)

		-- 5. Test '<C-p>' (Page Up)
		utils.log_info("Checking Page 1 again (pressing <C-p>)")
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-p>", true, true, true), "x", false)
		test_utils.wait_for_status("Rows 1%-1 of 3", 3000)

		local content_p3 = test_utils.get_buffer_content(results_buf)
		local status_p3 = test_utils.get_lualine_status()

		assert(content_p3:find("Merc"), "Page 1 (after <C-p>) should contain 'Merc'")
		assert(not content_p3:find("Ford"), "Page 1 (after <C-p>) should NOT contain 'Ford'")
		assert(not content_p3:find("Hyundai"), "Page 1 (after <C-p>) should NOT contain 'Hyundai'")
		assert(status_p3:find("Rows 1%-1 of 3"), "Lualine status should be 'Rows 1-1 of 3', but was: " .. status_p3)

		-- 6. Test '<C-M-n>' (Last Page)
		utils.log_info("Checking Last Page (pressing <C-M-n>)")
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-M-n>", true, true, true), "x", false)
		test_utils.wait_for_status("Rows 3%-3 of 3", 3000)

		local content_p4 = test_utils.get_buffer_content(results_buf)
		local status_p4 = test_utils.get_lualine_status()

		assert(not content_p4:find("Merc"), "Page 3 (after <C-M-n>) should NOT contain 'Merc'")
		assert(not content_p4:find("Ford"), "Page 3 (after <C-M-n>) should NOT contain 'Ford'")
		assert(content_p4:find("Hyundai"), "Page 3 (after <C-M-n>) should contain 'Hyundai'")
		assert(status_p4:find("Rows 3%-3 of 3"), "Lualine status should be 'Rows 3-3 of 3', but was: " .. status_p4)

		-- 7. Test '<C-M-p>' (First Page)
		utils.log_info("Checking First Page (pressing <C-M-p>)")
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-M-p>", true, true, true), "x", false)
		test_utils.wait_for_status("Rows 1%-1 of 3", 3000)

		local content_p5 = test_utils.get_buffer_content(results_buf)
		local status_p5 = test_utils.get_lualine_status()

		assert(content_p5:find("Merc"), "Page 3 (after <C-M-p>) should contain 'Merc'")
		assert(not content_p5:find("Ford"), "Page 3 (after <C-M-p>) should NOT contain 'Ford'")
		assert(not content_p5:find("Hyundai"), "Page 3 (after <C-M-p>) should contain 'Hyundai'")
		assert(status_p5:find("Rows 1%-1 of 3"), "Lualine status should be 'Rows 1-1 of 3', but was: " .. status_p5)

		-- 8. Cleanup
		utils.log_info("Cleaning up pagination test")
		vim.api.nvim_buf_delete(results_buf, { force = true })
		vim.api.nvim_set_current_buf(buf) -- Switch back to original query buffer
		test_utils.setup_mssql_async({ max_rows = 100 }) -- Restore default max_rows
		utils.log_info("Pagination test passed")
		utils.wait_for_schedule_async()
	end,
}
