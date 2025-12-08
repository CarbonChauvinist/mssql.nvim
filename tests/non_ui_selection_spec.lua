local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Cancelling server selection UI should return to disconnected state gracefully.",
	run_test_async = function()
		local json = test_utils.create_connection_json({ target_db = "tempdb" })
		test_utils.write_connections_file(json)

		local buf, _, cleanup = test_utils.create_lsp_buffer_async()
		local errors = {}
		local original_notify = vim.notify

		---@diagnostic disable-next-line: duplicate-set-field
		vim.notify = function(msg, level, _)
			if level == vim.log.levels.ERROR then
				table.insert(errors, msg)
			end
		end

		test_utils.ui_select_fake(nil)
		mssql.connect(buf)
		local qm = mssql.get_query_manager(buf)
		test_utils.defer_async(500)

		local success = test_utils.poll(function()
			return qm:get_state() == qm.states.disconnected
		end, { timeout_ms = 2000 })
		assert(success, "QueryManager did not return to disconnected state")

		vim.notify = original_notify
		if #errors > 0 then
			print(vim.inspect(errors))
			error("Plugin crashed or logged errors during cancellation:\n:" .. table.concat(errors, "\n"))
		end

		cleanup()
	end,
}
