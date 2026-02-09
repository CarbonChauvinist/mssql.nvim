local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
	test_name = "Event listeners are automatically disposed when buffer closes (Zombie Prevention)",
	run_test_async = function()
		local buf, client, qm, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })

		local original_handler = qm.handle_query_complete
		local call_count = 0

		---@diagnostic disable-next-line: duplicate-set-field
		qm.handle_query_complete = function(self, result)
			call_count = call_count + 1
			return original_handler(self, result)
		end

		local uri = require("mssql.utils").lsp_file_uri(buf)
		local fake_result = { ownerUri = uri,
			batchSummaries =	{
				{
					hasError = false,
					executionElapsed = "00:00:00.500",
					resultSetSummaries = {
						{
							id = 0,
							rowCount = 42,
							complete = true
						}
					}
				}
			}
		}
		local fake_ctx = { client_id = client.id }
		state.emit_event("query/complete", nil, fake_result, fake_ctx)

		assert(call_count == 1, "Listener should be active before buffer deletion")
		test_utils.safe_buf_delete(buf, { force = true })

		test_utils.poll(function()
			return state.get_query_manager(buf) == nil
		end, { timeout_ms = 1000 })

		state.emit_event("query/complete", nil, fake_result, fake_ctx)
		assert(call_count == 1, "Zombie listener detected! The handler executed after the buffer was deleted.")

		cleanup()
	end,
}
