local utils = require("mssql.utils")

return {
	test_name = "Reconnect logic retries on transient failures and supersedes in-flight loops",
	run_test_async = function()
		-- 1. Test basic transient retries
		local attempts = 0
		local mock_qm = {
			states = { disconnected = "disconnected" },
			get_connect_params = function() return { connection = { options = { user = "test" } } } end,
			set_state = function() end,

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

		-- 2. Test in-flight reconnect cancellation via reconnect_token
		local loop1_attempts = 0
		local loop2_attempts = 0

		local mock_qm2 = {
			states = { disconnected = "disconnected" },
			get_connect_params = function(self)
				return { id = self.current_id or 1, connection = { options = { user = "test" } } }
			end,
			set_state = function() end,
			connect_async = function(self, params)
				if params and params.id == 1 then
					loop1_attempts = loop1_attempts + 1
				elseif params and params.id == 2 then
					loop2_attempts = loop2_attempts + 1
				end
				return false, "Always fail, in order to keep retrying for test spec"
			end,
		}

		-- Start Loop 1
		mock_qm2.current_id = 1
		utils.reconnect_session(mock_qm2, "Loop 1", { timeout_ms = 5000, interval = 15 })

		-- Wait for Loop 1 to make at least 2 attempts
		vim.wait(1000, function() return loop1_attempts >= 2 end, 10, false)
		assert(loop1_attempts >= 2, "Loop 1 should have made attempts")

		-- Switch active loop marker and trigger Loop 2
		mock_qm2.current_id = 2
		local loop1_attempts_at_supersede = loop1_attempts
		utils.reconnect_session(mock_qm2, "Loop 2", { timeout_ms = 5000, interval = 15 })

		-- Wait for Loop 2 to make attempts
		vim.wait(1000, function() return loop2_attempts >= 2 end, 10, false)

		-- Verify Loop 1 stopped incrementing (canceled by reconnect_token!)
		assert(loop1_attempts <= loop1_attempts_at_supersede + 1,
			"Loop 1 should have been canceled by reconnect_token, but kept retrying! Count: " .. loop1_attempts .. " vs " .. loop1_attempts_at_supersede)
		assert(loop2_attempts >= 2, "Loop 2 should have taken over and retried")
	end,
}
