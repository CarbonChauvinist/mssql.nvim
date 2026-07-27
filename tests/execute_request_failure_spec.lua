local query_manager = require("mssql.query_manager")
local mssql_utils = require("mssql.utils")
local test_utils = require("tests.utils")

return {
	test_name = "QueryManager:execute_async explicitly handles and propagates an error from a failed query/executeString request",
	run_test_async = function()
		local buf = vim.api.nvim_create_buf(false, true)
		local simulated_error = { code = -32603, message = "Simulated Execution Error" }

		test_utils.run_with_mocks(
			{
				client_error = simulated_error,
				client_response = nil,
			},
			function()
				local mock_client = mssql_utils.get_lsp_client()
				local qm = query_manager.new(buf, mock_client, { query_timeout = 5})
				qm.state = qm.states.connected
				local result, err_msg = qm:execute_async({ query = "SELECT 1" })

				assert(result == nil, "Result should be nil on error")
				assert(type(err_msg) == "string", "Should return error string")
				assert(err_msg:find("Simulated Execution Error"), "Error message mismatch. Got: " .. tostring(err_msg))

				assert(qm:get_state() == qm.states.connected, "State should reset to connected")
			end
		)

		test_utils.safe_buf_delete(buf, { force = true })

	end,
}
