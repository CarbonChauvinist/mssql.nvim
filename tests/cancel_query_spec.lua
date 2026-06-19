local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
  test_name = "Cancelling a query returns the query manager to a Connected state.",
  run_test_async = function()
	local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

    local query = "WAITFOR DELAY '00:00:03' SELECT 1 AS test"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
    mssql.execute_query({ bufnr = buf })

	-- sanity check, verify we actually executed query in first place
	local executing = test_utils.poll(function()
			return qm:get_state() == qm.states.executing
		end, { timeout_ms = 1000, interval = 50 })
	assert(executing, "Query did not enter Executing state")

	mssql.cancel_query(buf)

	local polled_state
	local is_connected_after_cancel = test_utils.poll(function()
			polled_state = qm:get_state()
			return polled_state == qm.states.connected
		end)

    -- ensure we're still connected after cancellation
    assert(
		is_connected_after_cancel,
		"Query manager should be 'Connected' after cancellation, but was '" .. polled_state .. "'"
	)

	cleanup()
  end,
}
