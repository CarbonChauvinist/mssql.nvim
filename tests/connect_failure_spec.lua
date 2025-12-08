local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Connection failure should be handled gracefully and revert QueryManager to 'disconnected' state.",
	run_test_async = function()
		local json = test_utils.create_connection_json({ target_db = "DoesNotExist" })
		test_utils.write_connections_file(json)

		local buf, _, cleanup = test_utils.create_lsp_buffer_async()

		test_utils.ui_select_fake("TestConnection")
		mssql.connect(buf)

		local qm = mssql.get_query_manager(buf)
		local state
		assert(qm, "QueryManager should exist after connect call")

		local state_reset = test_utils.poll(function()
			state = qm:get_state()
			return state == qm.states.disconnected
		end, { timeout_ms = 5000 })
		assert(state_reset, "State did not reset to Disconnected. Current " .. state)

		cleanup()
	end,
}
