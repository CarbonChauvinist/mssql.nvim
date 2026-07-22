local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
	test_name = "Query Manager Intellisense readiness is updated when textDocument/intelliSenseReady notification is received",
	run_test_async = function()
		local buf, client, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
		qm:set_intellisense_ready(false)
		assert(qm:is_intellisense_ready() == false, "Query Manager IntelliSense should not be ready before notification is received")

		local handler = client.handlers["textDocument/intelliSenseReady"]
		assert(handler, "The 'textDocument/intelliSenseReady' handler should be registered on the client")

		-- trigger handler manually, pass context with correct client_id
		local fake_ctx = { client_id = client.id, bufnr = buf }
		local fake_result = { ownerUri = vim.uri_from_bufnr(buf) }
		handler(nil, fake_result, fake_ctx)

		-- verify QueryManager's IntelliSense state was updated to true
		assert(qm:is_intellisense_ready() == true, "Query Manager should be marked ready after textDocument/intelliSenseReady handler executes")

		cleanup()
	end,
}
