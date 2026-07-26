local finder = require("mssql.find_object")
local explorer = require("mssql.explorer")
local picker = require("mssql.picker")

return {
	test_name = "Find Object: per-object_type filtering returns matching items only",
	run_test_async = function()
		explorer.reset_explorer_state()

		local mock_client = { id = 12345 }
		local conn_opts = { server = "localhost", database = "master" } --[[@as MssqlConnectionOptions]]
		local key = explorer.create_cache_key(conn_opts, "database")

		local raw_cache = explorer.get_cache()
		raw_cache[key] = {
			connection_options = conn_opts,
			scope = "database",
			cache = {
				{ label = "dbo.Users", objectType = "Table", nodePath = "root/Tables/Users" },
				{ label = "dbo.Orders", objectType = "Table", nodePath = "root/Tables/Orders" },
				{ label = "dbo.GetUser", objectType = "StoredProcedure", nodePath = "root/Sprocs/GetUser" },
				{ label = "dbo.v_ActiveUsers", objectType = "View", nodePath = "root/Views/v_ActiveUsers" },
			},
		}

		local captured_items = nil
		local orig_pick = picker.pick
		---@diagnostic disable-next-line: duplicate-set-field
		picker.pick = function(items, _opts, _on_select)
			captured_items = items
		end

		-- 1. Filter by object_type = "t" (Tables only)
		local co1 = coroutine.create(function()
			finder.find_async(conn_opts, mock_client, { scope = "database", object_type = "t" })
		end)
		coroutine.resume(co1)

		assert(captured_items ~= nil and #captured_items == 2, "Should return exactly 2 tables")
		assert(captured_items[1].label == "dbo.Users" and captured_items[2].label == "dbo.Orders", "Filtered items should be tables")

		-- 2. Filter by object_type = "sp" (Stored Procedures only)
		local co2 = coroutine.create(function()
			finder.find_async(conn_opts, mock_client, { scope = "database", object_type = "p" })
		end)
		coroutine.resume(co2)

		assert(captured_items ~= nil and #captured_items == 1, "Should return exactly 1 stored procedure")
		assert(captured_items[1].label == "dbo.GetUser", "Filtered item should be stored procedure")

		-- Restore picker
		picker.pick = orig_pick
	end,
}
