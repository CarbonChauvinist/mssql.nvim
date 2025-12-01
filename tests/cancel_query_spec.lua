local mssql = require("mssql")
local test_utils = require("tests.utils")
local qmm = require("mssql.query_manager")

--- Polls for desired query manager state.
---@param qm MssqlQueryManager The query manager instance
---@param target_state MssqlQueryManagerState The expected state string
---@param opts? { timeout_ms: integer }
---@return MssqlQueryManagerState state The final state
local poll_for_qm_state = function(qm, target_state, opts)
	opts = opts or {}
	local timeout_ms = opts.timeout_ms or 20000

	local state = qm:get_state()
	local attempts = 0
	local max_attempts = math.ceil(timeout_ms / 250)

	while state ~= target_state and attempts < max_attempts do
		test_utils.defer_async(250)
		state = qm:get_state()
		attempts = attempts + 1
	end

	return state
end

return {
  test_name = "Cancelling a query returns the query manager to a Connected state.",
  run_test_async = function()
	local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

    local query = "WAITFOR DELAY '00:00:03' SELECT 1 AS test"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
    mssql.execute_query(buf)

	-- sanity check, verify we actually executed query in first place
	local executing = false
	for _ = 1, 20 do
		if qm:get_state() == qmm.states.Executing then
			executing = true
			break
		end
		test_utils.defer_async(50)
	end
	assert(executing, "Query did not enter Executing state")

	mssql.cancel_query(buf)

	local state = poll_for_qm_state(qm, qmm.states.Connected, { timeout_ms = 20000 })

    -- ensure we're still connected after cancellation
    assert(
		state == qmm.states.Connected,
		"Query manager should be 'Connected' after cancellation, but was '" .. state .. "'"
		)

	cleanup()
  end,
}
