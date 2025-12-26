local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
	test_name = "Client readiness state is correctly tracked via LSP handlers",
	run_test_async = function()
		local buf, client, _, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
		state._reset_all_state()

		local is_ready = state.is_client_ready(client.id)
		assert(is_ready == nil or is_ready == false, "Client should not be ready immediately after state reset")

		local handler = client.handlers["textDocument/intelliSenseReady"]
		assert(handler, "The 'textDocument/intelliSenseReady' handler should be registered on the client")

		-- trigger handler manually, pass context with correct client_id
		local fake_ctx = { client_id = client.id, bufnr = buf }
		handler(nil, { result = "success" }, fake_ctx)

		-- prove handler successfully called state.set_client_ready(id)
		assert(state.is_client_ready(client.id) == true, "Client should be marked ready after handler executes")

		cleanup()
	end,
}
