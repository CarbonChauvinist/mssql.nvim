local mssql = require("mssql")
local test_utils = require("tests.utils")
local default_opts = require("mssql.default_opts")

return {
	test_name = "Messages should be displayed according to the config ('buffer'|'notification')",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
		test_utils.setup_mssql_async({ view_messages_in = "notification" })

		-- test notification setup
		local captured_notifications = {}
		local original_notify = vim.notify

		---@diagnostic disable-next-line: duplicate-set-field
		vim.notify = function(msg, _level, _opts)
			table.insert(captured_notifications, msg)
		end

		local query_notify = "PRINT 'Hello Notification';"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query_notify })
		mssql.execute_query(buf)

		local notification_found = test_utils.poll(function()
			for _, msg in ipairs(captured_notifications) do
				if msg:find("Hello Notification") then
					return true
				end
			end
			return false
		end)

		vim.notify = original_notify
		assert(notification_found,
			"Did not receive expected notification. Captured: "
			..
			vim.inspect(captured_notifications)
		)

		-- test buffer setup
		test_utils.setup_mssql_async({ view_messages_in = "buffer" })
		local query_buffer = "PRINT 'Hello Buffer';"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query_buffer })
		mssql.execute_query(buf)

		local msg_buf_name = ""

		local buffer_found = test_utils.poll(function()
			for _, b in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_valid(b) then
					local name = vim.api.nvim_buf_get_name(b)
					if name:find("sql messages") then
						msg_buf_name = name
						local content = test_utils.get_buffer_content(b)
						if content:find("Hello Buffer") then
							test_utils.safe_buf_delete(b, { force = true })
							return true
						end
					end
				end
			end
			return false
		end)

		assert(buffer_found,
			"Message buffer not found or missing content. Last known message buffer: "
			..
			msg_buf_name
		)

		test_utils.setup_mssql_async({ view_messages_in = default_opts.view_messages_in })
		cleanup()
	end,
}
