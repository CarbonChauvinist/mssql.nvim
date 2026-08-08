local downloader = require("mssql.tools_downloader")

return {
	test_name = "Tools Downloader: raises error on download failure",
	run_test_async = function()
		local orig_system = vim.system
		local test_data_dir = vim.fn.stdpath("data")

		-- mock vim.system to simulate a failed download (exit code 22)
		---@diagnostic disable-next-line: duplicate-set-field
		vim.system = function(cmd, opts)
			return {
				wait = function()
					return {
						code = 22,
						stdout = "",
						stderr = "curl: (22) The requested URL returned error: 404"
					}
				end,
			}
		end

		local status, err = pcall(function()
			downloader.download_tools_async("https://invalid.fake/url.tar.gz", test_data_dir)
		end)

		vim.system = orig_system
		assert(status == false, "download_tools_async should fail and raise an error on non-zero exit code")
		assert(tostring(err):match("exit code 22"), "Error message should include exit code 22: " .. tostring(err))
		assert(tostring(err):match("404"), "Error message should include stderr output: " .. tostring(err))
	end,
}
