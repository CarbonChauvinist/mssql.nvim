local utils = require("mssql.utils")
local test_utils = require("tests.utils")

return {
	test_name = "Multiple handlers should run even if one crashes",
	run_test_async = function()
		-- utils.register_lsp_handler writes to .handlers and .custom_handlers
		local client = {
			id = 999,
			handlers = {},
			custom_handlers = {},
		}

		local captured_notifications = {}
		local original_notify = vim.notify

		---@diagnostic disable-next-line: duplicate-set-field
		vim.notify = function(msg, level, _)
			table.insert(captured_notifications, { msg = msg, level = level })
		end

		local handler_crash = function()
			error("Intentional Crash")
		end

		local handler_b_executed = false
		local handler_success = function()
			handler_b_executed = true
		end

		utils.register_lsp_handler(client, "test/method", handler_crash)
		utils.register_lsp_handler(client, "test/method", handler_success)
		assert(client.handlers["test/method"], "Main handler was not registered on the client")

		client.handlers["test/method"](nil, { some = "data" }, {})
		-- wait for async error logging
		test_utils.defer_async(100)

		assert(handler_b_executed, "The healthy handler (B) failed to execute due to the crash in handler A")

		local found_crash_log = vim.iter(captured_notifications):any(function(n)
			return n.msg:find("MSSQL Handler Error") and n.msg:find("Intentional Crash")
		end)
		assert(found_crash_log, "Did not find expected crash notification. Captured: " .. vim.inspect(captured_notifications))

		vim.notify = original_notify
	end,
}
