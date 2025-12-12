local finder = require("mssql.find_object")
local test_utils = require("tests.utils")

return {
	test_name = "Cache initialization should time out gracefully if session creation hangs",
	run_test_async = function()
		local original_defer = vim.defer_fn
		local expected_timeout = 10000
		local timeout_triggered = false

		---@diagnostic disable-next-line: duplicate-set-field
		vim.defer_fn = function(cb, ms)
			if ms == expected_timeout then
				timeout_triggered = true
				original_defer(cb, 0)
			else
				original_defer(cb, ms)
			end
		end

		local mock_client = {
			id = 8888,
			handlers = {},
			custom_handlers = {},
			request = function(_, method, _, cb)
				if method == "objectexplorer/createsession" then
					vim.schedule(function()
						cb(nil, { success = true })
					end)
					return true, 1
				end
			end,
		}

		local connection_options = {
			server = "localhost",
			database = "tempdb"
		}

		local success, err = pcall(function()
			-- This internally calls wait_for_notification_async(..., 10000)
			finder.initialise_cache_async(mock_client, connection_options, true)
		end)

		vim.defer_fn = original_defer
		assert(timeout_triggered, "The timeout timer was not scheduled with expected " .. expected_timeout .. "ms")
		assert(not success, "initialise_cache_async should have failed due to timeout")
		assert(tostring(err):find("timed out"), "Error message should mention timeout. Got: " .. tostring(err))
	end,
}
