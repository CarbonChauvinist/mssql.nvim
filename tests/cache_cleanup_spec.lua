local mssql = require("mssql")
local finder = require("mssql.find_object")
local test_utils = require("tests.utils")

return {
	test_name = "Cache should be cleaned up when buffer disconnects or closes",
	run_test_async = function()
		-- disconnect test
		do
			local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })
			qm:initialise_cache_async({force = true})

			local dc_conn_opts = qm and qm:get_connection_options()
			local dc_cache_key = finder.create_cache_key(dc_conn_opts, "database")
			local cache_populated = test_utils.poll(function()
				local cache = finder.get_cache()
				return vim.iter(pairs(cache)):any(function(key)
					return key == dc_cache_key
				end)
			end)
			assert(cache_populated, "Cache was not populated for tempdb")

			mssql.disconnect(buf)

			local cache_cleared = test_utils.poll(function()
				local cache = finder.get_cache()
				return not vim.iter(pairs(cache)):any(function(key)
					return key == dc_cache_key
				end)
			end, { timeout_ms = 10000 })
			assert(cache_cleared, "Cache entry for 'tempdb' was not removed after disconnect")
			cleanup()
		end

		-- buffer delete test
		do
			local _, _, qm, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })
			qm:initialise_cache_async({ force = true })

			local del_conn_opts = qm and qm:get_connection_options()
			local del_conn_key = finder.create_cache_key(del_conn_opts, "database")
			local testdb_cached = test_utils.poll(function()
				local cache = finder.get_cache()
				return vim.iter(pairs(cache)):any(function(key)
					return key == del_conn_key
				end)
			end, { timeout_ms = 10000 })
			assert(testdb_cached, "Cache was not populated for TestDbB")
			cleanup() -- this deletes the buffer

			local testdbb_cleared = test_utils.poll(function()
				local cache = finder.get_cache()
				return not vim.iter(pairs(cache)):any(function(key)
					return key == del_conn_key
				end)
			end, { timeout_ms = 10000 })
			assert(testdbb_cleared, "Cache entry for 'TestDbB' was not removed after buffer delete")
		end
	end,
}
