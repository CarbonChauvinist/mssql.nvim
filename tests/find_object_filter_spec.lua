local finder = require("mssql.find_object")
local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
	test_name = "Find Object (Server Scope) respects Allow/Deny lists",
	run_test_async = function()
		state._reset_all_state()

		local expanded_paths = {}
		local session_id = "sess_filter_test"

		local mock_client = {
			id = 56789,
			request = function(_, method, params, cb)
				if method == "objectexplorer/createsession" then
					local sid = session_id

					vim.defer_fn(function()
						state.emit_event("objectexplorer/sessioncreated", nil, {
							sessionId = sid,
							success = true,
							rootNode = { nodePath = "root", objectType = "Server" }
						}, { client_id = 56789 })

						if cb then cb(nil, { sessionId = sid }) end
					end, 10)
					return true, 1

				elseif method == "objectexplorer/expand" then
					table.insert(expanded_paths, params.nodePath)

					local nodes = {}
					if params.nodePath == "root" then
						-- level 1: folders
						nodes = {{ label = "Databases", nodePath = "root/Databases", objectType = "Folder" }}

					elseif params.nodePath == "root/Databases" then
						-- level 2: list of databases
						nodes = {
							-- matches the allow list, should be expanded
							{ label = "AllowedDb", nodePath = "root/Databases/AllowedDb", objectType = "Database" },
							-- matches the deny list, should NOT be expanded
							{ label = "DeniedDb", nodePath = "root/Databases/DeniedDb", objectType = "Database" },
							-- does not match the allow list, should NOT be expanded (implicit deny)
							{ label = "OtherDb", nodePath = "root/Databases/OtherDb", objectType = "Database" },
						}

					elseif params.nodePath == "root/Databases/AllowedDb" then
						-- level 3: inside allowed db
						nodes = {{ label = "Tables", nodePath = "root/Databases/AllowedDb/Tables", objectType = "Folder" }}

					elseif params.nodePath == "root/Databases/AllowedDb/Tables" then
						-- level 4: the object
						nodes = {{
							label = "TableInAllowedDb",
							nodePath = "root/Databases/AllowedDb/Tables/Table1",
							parentNodePath = "root/Databases/AllowedDb/Tables",
							objectType = "Table",
							metadata = { urn = "Database[@Name='AllowedDb']", schema = "dbo" }
						}}
					end

					-- trigger event logic
					vim.defer_fn(function()
						state.emit_event("objectexplorer/expandcompleted", nil, {
							sessionId = session_id,
							nodes = nodes,
						}, { client_id = 56789 })
					end, 10)

					-- if cb then cb(nil, true) end
					return true, 2

				elseif method == "objectexplorer/closeSession" then
					cb(nil, {})
					return true, 3
				end
			end
		}

		-- configure filters
		local opts = {
			server = "MyServer",
			databaseAllowList = { "Allowed.*" },
			databaseDenyList = { "Denied.*" }
		}

		finder.initialise_cache_async(mock_client, opts, "server", true)

		-- test 1: allowed db
		local found = test_utils.wait_for_cache_content("TableInAllowedDb", {debug = true, timeout = 10000 })
		assert(found, "Should find object in AllowedDb")

		-- test 2: no expansion of non-allowed dbs
		local allowed_expanded = false
		local denied_expanded = false
		local other_expanded = false

		for _, path in ipairs(expanded_paths) do
			if path == "root/Databases/AllowedDb" then allowed_expanded = true end
			if path == "root/Databases/DeniedDb" then denied_expanded = true end
			if path == "root/Databases/OtherDb" then other_expanded = true end
		end

		assert(allowed_expanded, "Should have expanded AllowedDb")
		assert(not denied_expanded, "Should NOT have expanded DeniedDb")
		assert(not other_expanded, "Should NOT have expanded OtherDb (implicitly denied by allow list)")
	end,
}
