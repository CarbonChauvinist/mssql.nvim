local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Connect to database should work",
	run_test_async = function()
		local json = test_utils.create_connection_json({ target_db = "tempdb" })
		test_utils.write_connections_file(json)

		local buf, client, cleanup = test_utils.create_lsp_buffer_async()

		test_utils.ui_select_fake("TestConnection")
		mssql.connect(buf)

		test_utils.wait_for_intellisenseReady(buf, client)
		local qm = mssql.get_query_manager(buf)
		assert(qm:get_state() == qm.states.Connected, "State should be Connected")
		cleanup()
	end,
}
