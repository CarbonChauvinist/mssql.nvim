local finder = require("mssql.find_object")
local test_utils = require("tests.utils")

return {
	test_name = "Finder should strictly scope search to the connected database",
	run_test_async = function()
		print("starting")
		local _, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbA" })

		test_utils.wait_for_cache_content("dbo.Person")

		local cache = finder.get_cache()
		local current_db_key
		for key, _ in pairs(cache) do
			if key:lower():find("testdba") then
				current_db_key = key
				break
			end
		end

		local db_cache = cache[current_db_key].cache

		local found_local = vim.iter(db_cache):any(function(item)
			return item.label:lower() == "dbo.person"
		end)
		assert(found_local, "Did not find object 'dbo.Person' in TestDbA cache")

		local found_foreign = vim.iter(db_cache):any(function(item)
			return item.label:lower() == "dbo.car"
		end)
		assert(not found_foreign, "Found 'dbo.Car' (from TestDbB) inside TestDbA cache! Scope leakage.")

		cleanup()
	end,
}
