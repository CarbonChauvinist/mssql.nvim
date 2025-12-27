local utils = require("mssql.utils")

return {
	test_name = "Reconnect logic retries on transient failures",
	run_test_async = function()
		local attempts = 0
		local mock_qm = {
			states = { disconnected = "disconnected" },
			get_connect_params = function() return { connection = { options = { user = "test" } } } end,
			set_state = function() end,

			-- mock connect to fail twice
			connect_async = function()
				attempts = attempts + 1
				if attempts < 3 then
					return false, "Mock Transient Error"
				end
				return true, nil
			end,
		}

		local started = utils.reconnect_session(mock_qm, "Test", { timeout_ms = 1000, interval = 10 })
		assert(started, "Reconnect session should have successfully STARTED the background job")
		local result = vim.wait(1000, function()
			return attempts >= 3
		end, 10, false)
		assert(result, "Timed out waiting for reconnect attempts. Stuck at: " .. attempts)
		assert(attempts == 3, "Should have retried exactly 3 times, got " .. attempts)
	end
}
