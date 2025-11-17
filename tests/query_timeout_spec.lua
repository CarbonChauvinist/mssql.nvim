local mssql = require("mssql")
local utils = require("mssql.utils")
local qmm = require("mssql.query_manager")
local test_utils = require("tests.utils")

return {
	test_name = "Query should time out and state should be reset",
	run_test_async = function()
		-- 1. Setup: Create a fresh buffer and set filetype
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_option_value("filetype", "sql", {buf = buf})
		vim.api.nvim_win_set_buf(0, buf)


		-- 2. Override query_timeout
		-- with a very short query_timeout (e.g. 0.05 minutes = 3 seconds)
		utils.log_info("Overriding query_timeout to 0.05")
		test_utils.setup_mssql_async({query_timeout = 0.05})
		utils.wait_for_schedule_async()

		-- 3. Setup: Wait for LSP to attach
		local client
		utils.log_info("Waiting for LSP to attach...")
		local success = vim.wait(15000, function()
			client = vim.lsp.get_clients({name = "mssql_ls", bufnr = buf})
			return client ~= nil
		end, 100)
		if not success then
			utils.log_error("LSP client did not attach within 15s")
			return
		end

		-- 4. Setup: Connect to database
		test_utils.ui_select_fake("master")
		mssql.connect()

		local qm = vim.b.query_manager
		if not qm then
			error("Query manager not found on buffer. Did connect_spec run?")
		end

		-- 5. Run a query that will time out
		local query = "WAITFOR DELAY '00:00:10' SELECT 1"
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { query })
		utils.wait_for_schedule_async()

		mssql.execute_query()

		-- 6. Wait for duration longer than the timeout
		-- i.e. 5 seconds (timeout is 3s, plus 2s for auto-cancel).
		test_utils.defer_async(5000)

		-- 7. `execute_async` function's auto-cancel should set state to 'connected'
		local state = qm.get_state()
		assert(
			state == qmm.states.Connected,
			"Query manager state was not reset. Expected '" .. qmm.states.Connected .. "' got '" .. state .. "'"
		)

		-- 8. Test regular fast query to ensure connection is still usable
		vim.api.nvim_win_set_buf(0, buf) -- make sure we're still in query buffer
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SELECT 1 AS TestSuccess" })
		utils.wait_for_schedule_async()

		mssql.execute_query()

		local _, err = utils.wait_for_notification_async(buf, client, "query/complete", 30000)
		if err then
			error("Subsequent query failed after timeout: ".. err.message)
		end

		test_utils.defer_async(5000)

		-- 9. Ensure the subsequent query worked
		local res_buf = test_utils.get_results_buffer()
		local results = test_utils.get_buffer_content(res_buf)--table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
		assert(
			results:find("TestSuccess"),
			"Subsequent query did not return expected results."
		)

		-- 10. Teardown: Clean up all buffer this test created
		if res_buf then
			vim.api.nvim_buf_delete(res_buf, { force = true })
		end
		vim.api.nvim_buf_delete(buf, { force = true})
	end,
}
