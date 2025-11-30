local mssql = require("mssql")

function iif(cond, true_value, false_value)
	if cond then
		return true_value
	else
		return false_value
	end
end

local tools_folder = vim.fs.joinpath(vim.fn.stdpath("data"), "mssql.nvim/sqltools")
local tools_file = iif(jit.os == "Windows", "MicrosoftSqlToolsServiceLayer.exe", "MicrosoftSqlToolsServiceLayer")

local function tools_file_exists()
	local f = io.open(vim.fs.joinpath(tools_folder, tools_file), "r")
	if f then
		f:close()
		return true
	end
	return false
end

local function setup_async()
	local co = coroutine.running()
	mssql.setup({
		open_results_in = "current_window",
	}, function()
		vim.schedule(function()
			coroutine.resume(co)
		end)
	end)
	coroutine.yield()
end

return {
	test_name = "Setup should download and extract the sql tools",
	run_test_async = function()
		local skip_request = os.getenv("SKIP_DOWNLOAD") == "true" or os.getenv("SKIP_DOWNLOAD") == "1"

		if skip_request and tools_file_exists() then
			print("    [INFO] Skipping download (SKIP_DOWNLOAD set and file exists)")
			setup_async()
			return
		end

		vim.fn.delete(tools_folder, "rf")
		vim.fn.delete(vim.fs.joinpath(vim.fn.stdpath("data"), "mssql.nvim/config.json"))

		local download_finished = false
		vim.defer_fn(function()
			assert(download_finished, "Download did not complete")
		end, 120000)

		setup_async()
		download_finished = true
		assert(tools_file_exists(), "The sql server tools file does not exist among the downloads")
	end,
}
