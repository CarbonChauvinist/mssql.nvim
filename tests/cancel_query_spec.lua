local mssql = require("mssql")
local test_utils = require("tests.utils")
local qmm = require("mssql.query_manager")

return {
  test_name = "Cancelling a query returns the query manager to a Connected state.",
  run_test_async = function()
    local query = "WAITFOR DELAY '00:00:30' SELECT 1 AS test"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { query })

    mssql.execute_query()
    mssql.cancel_query()

	-- poll every 100ms for up to 5 seconds
	local qm = vim.b.query_manager
	local state = qm.get_state()
	local attempts = 0
	local max_attempts = 50 -- 50 * 100ms = 5 seconds

	while state ~= qmm.states.Connected and attempts < max_attempts do
		test_utils.defer_async(100)
		state = qm.get_state()
		attempts = attempts + 1
	end

    -- ensure we're still connected after cancellation
    assert(
		state == qmm.states.Connected,
		"Query manager should be 'Connected' after cancellation, but was '" .. state .. "'"
		)

    test_utils.defer_async(2000)
    vim.cmd("bdelete!")
  end,
}
