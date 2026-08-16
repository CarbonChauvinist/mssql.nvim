local mssql = require("mssql")
local test_utils = require("tests/utils")
local cmds = require("mssql.commands")

---Explores safe table syntax of `vim.cmd` call to confirm cmd and presence of args
---@param cmds_tbl table
---@expected_cmd string
---@expected_arg string
---@return boolean success
local has_cmd = function(cmds_tbl, expected_cmd, expected_arg)
	for _, c in ipairs(cmds_tbl) do
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
		local extension_cases = {
			{ "test.csv", "query/saveCsv", true },
			{ "test.CSV", "query/saveCsv", true },
			{ "test.json", "query/saveJson", true },
			{ "test.xml", "query/saveXml", true },
			{ "test.xlsx", "query/saveExcel", false },
			{ "test.xls", "query/saveExcel", false },
			{ "test.txt", nil, nil },
			{ "noextension", nil, nil },
		}
		for _, c in ipairs(extension_cases) do
			local method, open_after_save = cmds.map_extension(c[1])
			assert(method == c[2], string.format(
				"map_extension(%q) method = %s, expected %s",
					c[1],
				tostring(method),
				tostring(c[2])
			))
			assert(open_after_save == c[3], string.format(
				"map_extension(%q) open = %s, expected %s", c[1], tostring(open_after_save), tostring(c[3])
			))
		end

		vim.cmd.enew()
		local buf = vim.api.nvim_get_current_buf()
		vim.b[buf].query_result_info = { ownerUri = "file:///mock_results_buffer.md" }

		--- Helper to run one scenario
		---@param filename string Filename
		---@param assert_fn function Function to assert
		---@param extra_mocks table? Additional mock config (file_exists, confirm_choice)
		local function check_save(filename, assert_fn, extra_mocks)
			local mocks = vim.tbl_extend("force", { input_value = filename }, extra_mocks or {})
			local captures = test_utils.run_with_mocks(
				mocks,
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
			assert(test_utils.log_contains_pattern(c.logs, "File extension not recognized"), "Missing error log")
		end)

		-- empty input (cancel)
		check_save("", function(c)
			assert(#c.requests == 0, "Should skip LSP request")
			assert(test_utils.log_contains_pattern(c.logs, "No file path"), "Missing error log")
		end)

		-- existing file, overwrite confirmed
		check_save("test.csv", function(c)
			assert(#c.requests == 1, "Should make LSP request")
			assert(c.requests[1].method == "query/saveCsv", "Wrong method")
		end, { file_exists = true, confirm_choice = 1})

		-- existing file, overwrite declined
		check_save("test.csv", function(c)
			assert(#c.requests == 0, "Should skip LSP request when overwrite declined")
		end, { file_exists = true, confirm_choice = 2})

		test_utils.safe_buf_delete(buf, { force = true})
	end,
}
