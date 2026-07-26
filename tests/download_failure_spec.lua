local downloader = require("mssql.tools_downloader")

return {
	test_name = "Tools Downloader: resumes coroutine and raises error on download failure",
	run_test_async = function()
		local orig_jobstart = vim.fn.jobstart
		local test_data_dir = vim.fn.stdpath("data")

		-- mock vim.fn.jobstart to simulate a failed job (exit code 1)
		---@diagnostic disable-next-line: duplicate-set-field
		vim.fn.jobstart = function(_, opts)
			vim.defer_fn(function()
				if opts.on_stderr then opts.on_stderr(1, { "curl: (22) The requested URL returned error: 404"}) end
				if opts.on_exit then opts.on_exit(1, 1) end
			end, 5)
			return 999
		end

		local status, err = pcall(function()
			downloader.download_tools_async("https://invalid.fake/url.tar.gz", test_data_dir)
		end)

		vim.fn.jobstart = orig_jobstart
		assert(status == false, "download_tools_async should fail and raise an error or non-zero exit code")
		assert(tostring(err):match("exit code 1"), "Error message should include exit code: " .. tostring(err))
	end,
}
