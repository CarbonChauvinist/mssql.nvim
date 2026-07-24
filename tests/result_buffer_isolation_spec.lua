local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Result buffers are isolated per QueryManager and cleaned up on buffer delete",
	run_test_async = function()
		local buf_a, _, qm_a, cleanup_a = test_utils.test_scaffold({ target_db = "tempdb" })
		local buf_b, _, qm_b, cleanup_b = test_utils.test_scaffold({ target_db = "tempdb" })

		assert(qm_a ~= nil and qm_b ~= nil, "Query managers should exist")

		-- Execute real queries on both buffers
		vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, { "SELECT 1 AS ColA;" })
		vim.api.nvim_buf_set_lines(buf_b, 0, -1, false, { "SELECT 2 AS ColB;" })

		mssql.execute_query({ bufnr = buf_a })
		mssql.execute_query({ bufnr = buf_b })

		test_utils.poll(function()
			return #qm_a.result_buffers == 1 and #qm_b.result_buffers == 1
		end, { timeout_ms = 10000 })

		assert(#qm_a.result_buffers == 1, "QMA should have 1 result buffer")
		assert(#qm_b.result_buffers == 1, "QMB should have 1 result buffer")

		local res_buf_a = qm_a.result_buffers[1]
		local res_buf_b = qm_b.result_buffers[1]

		assert(vim.api.nvim_buf_is_valid(res_buf_a), "Result buffer A should be valid")
		assert(vim.api.nvim_buf_is_valid(res_buf_b), "Result buffer B should be valid")

		-- Re-executing query on QMA should clear QMA's result buffers, but NOT QMB's!
		mssql.execute_query({ bufnr = buf_a })

		test_utils.poll(function()
			return not vim.api.nvim_buf_is_valid(res_buf_a)
		end, { timeout_ms = 10000 })

		assert(not vim.api.nvim_buf_is_valid(res_buf_a), "Old result buffer A should have been deleted")
		assert(vim.api.nvim_buf_is_valid(res_buf_b), "Result buffer B should STILL be valid (ISOLATED)")

		-- Deleting buf_b (closing query tab B) should clean up QMB's result buffers
		test_utils.safe_buf_delete(buf_b, { force = true })

		test_utils.poll(function()
			return not vim.api.nvim_buf_is_valid(res_buf_b)
		end, { timeout_ms = 5000 })

		assert(not vim.api.nvim_buf_is_valid(res_buf_b), "Deleting query buffer B should clean up its result buffers")

		cleanup_a()
		cleanup_b()
	end,
}
