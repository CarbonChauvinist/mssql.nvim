local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
	test_name = "Multiple buffers/tabs act as independent sessions and don't leak state",
	run_test_async = function()
		local buf_a, _, _, cleanup_a = test_utils.test_scaffold({ target_db = "TestDbA" })
		local buf_b, _, _, cleanup_b = test_utils.test_scaffold( { target_db = "TestDbB" })

		local qm_a = state.get_query_manager(buf_a)
		local qm_b = state.get_query_manager(buf_b)

		if not qm_a or not qm_b then
			error("Query Managers not created for buffers")
		end

		local db_a = qm_a:get_database_name()
		local db_b = qm_b:get_database_name()

		assert(db_a == "TestDbA", "Buffer A should be connected to TestDbA, but got: " .. tostring(db_a))
		assert(db_b == "TestDbB", "Buffer B should be connected to TestDbB, but got: " .. tostring(db_b))
		assert(db_a ~= db_b, "CRITICAL: The two buffers are sharing the same QueryManager instance!")

		test_utils.safe_buf_delete(buf_b)
		test_utils.poll(function()
			return state.get_query_manager(buf_b) == nil
		end, { timeout_ms = 1000 })
		assert(state.get_query_manager(buf_b) == nil, "Query manager B should be garbage collected after buffer deletion")

		assert(state.get_query_manager(buf_a) ~= nil, "Query manager A should still exist")
		assert(state.get_query_manager(buf_a):get_database_name() == "TestDbA", "Query manager A should maintain its state")

		cleanup_a()
		cleanup_b()
	end,
}
