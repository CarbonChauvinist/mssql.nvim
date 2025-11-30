local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Switch database should work",
	run_test_async = function()
		local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

		test_utils.ui_select_fake("TestDbB")
		mssql.switch_database(buf)

		local current_db, state

		local switch_success = test_utils.poll(function()
			local params = qm:get_connect_params()
			state = qm:get_state()
			if params and params.connection and params.connection.options then
				current_db = params.connection.options.database
			end
			if current_db == "TestDbB" and state == qm.states.Connected then
				return true
			end
			return false
		end)

		assert(switch_success, "Switch database did not successfully complete.")
		assert(current_db == "TestDbB", "Database did not switch to TestDbB. Current: " .. tostring(current_db))
		assert(state == qm.states.Connected, "Query Manager did not return to Connected state.")

		cleanup()
	end,
}
