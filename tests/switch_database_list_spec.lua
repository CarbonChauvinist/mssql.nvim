local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Switch database should list all available databases (Baseline for filtering)",
	run_test_async = function()
		local items_presented = {}
		local original_select = vim.ui.select

		local success, err = pcall(function()
			local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

			---@diagnostic disable-next-line: duplicate-set-field
			vim.ui.select = function(items, _, on_choice)
				items_presented = items
				on_choice(nil)
			end

			mssql.switch_database(buf)

			test_utils.poll(function()
				return #items_presented > 0
			end)

			local dbs = { "TestDbA", "TestDbB", "tempdb", "msdb", "model", "master" }
			for _, db in ipairs(dbs) do
				assert(
					vim.tbl_contains(items_presented, db),
					"Database list missing '" .. db .. "'"
				)
			end
			return cleanup
		end)

		vim.ui.select = original_select

		if success and type(err) == "function" then
			err()
		elseif not success then
			error(err)
		end
	end,
}
