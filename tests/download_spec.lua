local test_utils = require("tests.utils")

local tools_folder = vim.fs.joinpath(vim.fn.stdpath("data"), "mssql.nvim/sqltools")
local tools_file = "MicrosoftSqlToolsServiceLayer"

local function tools_file_exists()
	local f = io.open(vim.fs.joinpath(tools_folder, tools_file), "r")
	if f then
		f:close()
		return true
	end
	return false
end

return {
	test_name = "Setup should download and extract the sql tools",
	run_test_async = function()
		local skip_request = os.getenv("SKIP_DOWNLOAD") == "true" or os.getenv("SKIP_DOWNLOAD") == "1"

		if skip_request and tools_file_exists() then
			print("    [INFO] Skipping download (SKIP_DOWNLOAD set and file exists)")
			test_utils.setup_mssql_async()
			return
		end

		vim.fn.delete(tools_folder, "rf")
		vim.fn.delete(vim.fs.joinpath(vim.fn.stdpath("data"), "mssql.nvim/config.json"))

		test_utils.setup_mssql_async()
		assert(tools_file_exists(), "The sql server tools file does not exist among the downloads")
	end,
}
