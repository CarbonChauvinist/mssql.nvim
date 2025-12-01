local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Should be able to connect with a filename with spaces",
	run_test_async = function()
		local json = test_utils.create_connection_json({ target_db = "master" })
		test_utils.write_connections_file(json)
		local buf, cleanup = test_utils.create_sql_buffer({ buffer_name = "tests/filename with spaces.sql" })
		local client = test_utils.wait_for_lsp_attach(buf)
		test_utils.ui_select_fake("TestConnection")
		mssql.connect(buf)
		test_utils.wait_for_intellisenseReady(buf, client)
		cleanup()
	end,
}
