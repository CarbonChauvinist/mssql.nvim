local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Switch database should work",
	run_test_async = function()
		local _, _, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

		test_utils.ui_select_fake("TestDbB")
		mssql.switch_database()

		local current_db = ""
		local state= ""
		local attempts = 0

		while attempts < 50 do
			test_utils.defer_async(100)
			local params = qm:get_connect_params()
			if params and params.connection and params.connection.options then
				current_db = params.connection.options.database
			end
			state = qm:get_state()
			if current_db == "TestDbB" and state == qm.states.Connected then
				break
			end
			attempts = attempts + 1
		end

		assert(current_db == "TestDbB", "Database did not switch to TestDbB. Current: " .. tostring(current_db))
		assert(state == qm.states.Connected, "Query Manager did not return to Connected state.")

		cleanup()
	end,
}
