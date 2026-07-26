local mssql = require("mssql")
local test_utils = require("tests/utils")

---Explores safe table syntax of `vim.cmd` call to confirm cmd and presence of args
---@param cmds table
---@expected_cmd string
---@expected_arg string
---@return boolean success
local has_cmd = function(cmds, expected_cmd, expected_arg)
	for _, c in ipairs(cmds) do
		if type(c) == "table" and c.cmd == expected_cmd then
			if not expected_arg or (c.args and vim.list_contains(c.args, expected_arg)) then
				return true
			end
		end
	end
	return false
end

return {
	test_name = "save_query_results should call LSP with correct params",
	run_test_async = function()
		vim.cmd("enew")
		local buf = vim.api.nvim_get_current_buf()
		vim.b[buf].query_result_info = { ownerUri = "file:///mock_results_buffer.md" }

		--- Helper to run one scenario
		---@param filename string Filename
		---@param assert_fn function Function to assert
		local function check_save(filename, assert_fn)
			local captures = test_utils.run_with_mocks(
				{ input_value = filename },
					function()
					mssql.save_query_results(buf)
					test_utils.defer_async(50)
				end
			)
			assert_fn(captures)
		end

		check_save("test.csv", function(c)
			assert(#c.requests == 1, "Should make LSP request")
			assert(c.requests[1].method == "query/saveCsv", "Wrong method")
			assert(c.requests[1].params.FilePath == "test.csv", "Wrong path")
			assert(has_cmd(c.cmds, "edit", "test.csv"), "Should edit file")
		end)

		check_save("test.xlsx", function(c)
			assert(#c.requests == 1, "Should make LSP request")
			assert(c.requests[1].method == "query/saveExcel", "Wrong method")
			assert(not has_cmd(c.cmds, "edit", "test.xlsx"), "Should NOT edit xlsx")
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
