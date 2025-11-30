local mssql = require("mssql")
local test_utils = require("tests/utils")

return {
	test_name = "save_query_results should call LSP with correct params",
	run_test_async = function()
		vim.cmd("enew")
		local buf = vim.api.nvim_get_current_buf()
		vim.b[buf].query_result_info = { ownerUri = "file:///dummy.sql" }

		--- Helper to run one scenario
		---@param filename string Filename
		---@param assert_fn function Function to assert
		local function check_save(filename, assert_fn)
			local captures = test_utils.run_with_mocks(
				{ input_value = filename },
					function()
					mssql.save_query_results()
					test_utils.defer_async(50)
				end
			)
			assert_fn(captures)
		end

		check_save("test.csv", function(c)
			assert(#c.requests == 1, "Should make LSP request")
			assert(c.requests[1].method == "query/saveCsv", "Wrong method")
			assert(c.requests[1].params.FilePath == "test.csv", "Wrong path")
			assert(vim.tbl_contains(c.cmds, "edit test.csv"), "Should edit file")
		end)

		check_save("test.xlsx", function(c)
			assert(#c.requests == 1, "Should make LSP request")
			assert(c.requests[1].method == "query/saveExcel", "Wrong method")
			assert(not vim.tbl_contains(c.cmds, "edit test.xlsx"), "Should NOT edit xlsx")
		end)

		-- invalid extension
		check_save("test.txt", function(c)
			assert(#c.requests == 0, "Should skip LSP request")
			assert(test_utils.log_contains_pattern(c.logs, "File extension not recognised"), "Missing error log")
		end)

		-- empty input (cancel)
		check_save("", function(c)
			assert(#c.requests == 0, "Should skip LSP request")
			assert(test_utils.log_contains_pattern(c.logs, "No file path"), "Missing error log")
		end)

		test_utils.safe_buf_delete(buf, { force = true})
	end,
}
