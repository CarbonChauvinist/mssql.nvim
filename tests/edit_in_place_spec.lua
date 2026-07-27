local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Editing an existing file in place (`:e`) should handle reconnection gracefully",
	run_test_async = function()
		local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })
		local query = "SELECT * from dbo.Car"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

		local temp_file = vim.fn.tempname() .. ".sql"
		vim.cmd.saveas({ args = { temp_file }, bang = true, mods = { silent = true } })

		-- reload buffer from disk via :edit!
		vim.cmd.edit({ bang = true })

		-- :edit! triggers on_detach (disconnected) --> LspAttach (reconnects)
		local first_disconnects = test_utils.poll(function()
			return qm:get_state() ~= qm.states.connected
		end)
		assert(first_disconnects, "Need to disconnect first on buffer detach")

		local then_reconnects = test_utils.poll(function()
			return qm:get_state() == qm.states.connected
		end, { timeout_ms = 15000 })
		assert(then_reconnects, "QueryManager did not reconnect after :edit!")

		mssql.execute_query({ bufnr = buf })
		local res_buf, status, results = test_utils.res_buf_catcher()
		assert(status and results:find("Merc"), "Query results verification failed after reload. Content: " .. tostring(results))

		test_utils.cleanup_results_buffer(res_buf)
		cleanup()
		os.remove(temp_file)
	end,
}
