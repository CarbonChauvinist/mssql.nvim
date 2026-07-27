local mssql = require("mssql")
local query_manager = require("mssql.query_manager")
local mssql_utils = require("mssql.utils")
local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
	test_name = "execute_current_statement sends correct 0-indexed cursor position and LSP method",
	run_test_async = function()
		local buf, cleanup = test_utils.create_sql_buffer({ buffer_name = "stmt_test.sql" })

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"SELECT 1 AS FirstStmt;",
			"SELECT 2 AS SecondStmt;",
		})

		-- position cursor on line 2 (1-indexed), Column 7
		vim.api.nvim_win_set_cursor(0, { 2, 7 })

		local captures = test_utils.run_with_mocks(
			{
				client_response = { ownerUri = "file:///dummy.sql" },
			},
			function()
				local mock_client = mssql_utils.get_lsp_client()
				local qm = query_manager.new(buf, mock_client, {})
				qm.state = qm.states.connected
				state.set_query_manager(buf, qm)

				mssql.execute_current_statement({ bufnr = buf })
			end
		)

		-- verify captured LSP request method and parameters
		local req = captures.requests[1]
		assert(req ~= nil, "LSP request should have been dispatched")
		assert(req.method == "query/executedocumentstatement", "Method should be query/executedocumentstatement, got: " .. tostring(req.method))
		assert(req.params.line == 1, "Expected 0-indexed line 1 (row 2), got: " .. tostring(req.params.line))
		assert(req.params.column == 7, "Expected column 7, got: " .. tostring(req.params.column))

		state.remove_query_manager(buf)
		cleanup()
	end,
}
