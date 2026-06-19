local mssql = require("mssql")
local utils = require("mssql.utils")
local test_utils = require("tests.utils")

return {
	test_name = "Query should time out, log error, and state should be reset",
	run_test_async = function()

		local captured_errors = {}
		local original_log_error = utils.log_error

		local success, err = pcall(function()
			---@diagnostic disable-next-line: duplicate-set-field
			utils.log_error = function(msg)
				table.insert(captured_errors, msg)
				original_log_error(msg)
			end

			test_utils.setup_mssql_async({query_timeout = 2})
			local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

			local query = "WAITFOR DELAY '00:00:04' SELECT 1"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })
			mssql.execute_query({ bufnr = buf })

			local state
			local reset_success = test_utils.poll(function()
				state = qm:get_state()
				return state == qm.states.connected
			end)

			assert(
				reset_success,
				"Query manager state was not reset. Expected '" .. qm.states.connected .. "' got '" .. state .. "'"
			)

			local found_msg = vim.iter(captured_errors):any(function(msg)
				return msg:find("Query execution timed out")
			end)
			assert(found_msg, "Did not log 'Query execution timed out'. Captured logs: " .. vim.inspect(captured_errors))

			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT 1 as TestSuccess" })
			utils.wait_for_schedule_async()
			mssql.execute_query({ bufnr = buf })

			local res_buf, _, results = test_utils.res_buf_catcher({timeout_ms = 10000})
			assert(results:find("TestSuccess"), "Subsequent query did not return expected results.")

			test_utils.cleanup_results_buffer(res_buf)
			return cleanup
		end)

		utils.log_error = original_log_error
		test_utils.setup_mssql_async({query_timeout = nil})

		if success and type(err) == "function" then
			err()
		elseif not success then
			error(err)
		end
	end,
}
