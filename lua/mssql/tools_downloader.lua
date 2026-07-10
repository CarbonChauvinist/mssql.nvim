local utils = require("mssql.utils")
local joinpath = vim.fs.joinpath
local M = {}

-- Check the OS and system architecture
M.get_tools_download_url = function()
	local urls = {
		Windows = {
			arm64 = "https://github.com/microsoft/sqltoolsservice/releases/download/6.0.20260709.1/Microsoft.SqlTools.Migration-win-arm64-net10.0.zip",
			x64 = "https://github.com/microsoft/sqltoolsservice/releases/download/6.0.20260709.1/Microsoft.SqlTools.Migration-win-x64-net10.0.zip",
			x86 = "https://github.com/microsoft/sqltoolsservice/releases/download/6.0.20260709.1/Microsoft.SqlTools.Migration-win-x86-net10.0.zip",
		},
		Linux = {
			arm64 = "https://github.com/microsoft/sqltoolsservice/releases/download/6.0.20260709.1/Microsoft.SqlTools.ServiceLayer-linux-arm64-net10.0.tar.gz",
			x64 = "https://github.com/microsoft/sqltoolsservice/releases/download/6.0.20260709.1/Microsoft.SqlTools.ServiceLayer-linux-x64-net10.0.tar.gz",
		},
		OSX = {
			arm64 = "https://github.com/microsoft/sqltoolsservice/releases/download/6.0.20260709.1/Microsoft.SqlTools.Migration-osx-arm64-net10.0.tar.gz",
			x64 = "https://github.com/microsoft/sqltoolsservice/releases/download/6.0.20260709.1/Microsoft.SqlTools.ServiceLayer-osx-x64-net10.0.tar.gz",
		},
	}
	local hashes = {
		Windows = {
			arm64 = "sha256:4fb6d2a5a6a7c304bdffaca65f80dfae76010d22ef6d09fc3fedab8393e7b50a",
			x64 = "sha256:44e4197de678c856254a832adbc18703bfdea984d2cd1efccacb25b5f8343c71",
			x86 = "sha256:3456ac726c77a8e5e6f925d287be2f3c5f99f0f6b1ddeeb67d5a960238fc7189",
		},
		Linux = {
			arm64 = "sha256:c872ff665f847beddd9f37f98ba52f255b0f1a6700c64e29d2e230bcae5fc183",
			x64 = "sha256:47d3d758b529e72cac0519a2d6bb9c9e046f60d2008e048fdd9b8d3de3d28461"
		},
		OSX = {
			arm64 = "sha256:83dbab91f26b37fa166b76dd7b998a14878f9dfe379da2db933bb07f90249e65",
			x64 = "sha256:47d3d758b529e72cac0519a2d6bb9c9e046f60d2008e048fdd9b8d3de3d28461"
		}
	}

	local os = jit.os
	local arch = jit.arch

	if not urls[os] then
		error("Your OS " .. os .. " is not supported. It must be Windows, Linux or OSX.", 0)
	end

	local url = urls[os][arch]
	if not url then
		error("Your system architecture " .. arch .. " is not supported. It can either be x64 or arm64.", 0)
	end

	local hash = hashes[os] and hashes[os][arch]
	return url, hash
end

-- Delete any existing download folder, download, unzip and write the most recent url to the config
M.download_tools_async = function(url, data_folder)
	local target_folder = joinpath(data_folder, "sqltools")
	local _, expected_hash = M.get_tools_download_url()
	local raw_hash = ""
	if expected_hash then
		raw_hash = expected_hash:match("^sha256:(%x+)") or expected_hash
		raw_hash = raw_hash:lower()
	end

	local download_job
	if jit.os == "Windows" then
		local temp_file = joinpath(data_folder, "/temp.zip")
		local check_cmd = ""
		if raw_hash ~= "" then
			check_cmd = string.format([[
			$actualHash = (Get-FileHash -Path "%s" -Algorithm SHA256).Hash
			if ($actualHash.ToLower() -ne "%s") {
				throw "Checksum verification failed! Expected: %s, Got: $actualHash"
			}
			]], temp_file, raw_hash, raw_hash)
		end
		-- Turn off the progress bar to speed up the download
		download_job = {
			"powershell",
			"-Command",
			string.format(
				[[
          $ErrorActionPreference = 'Stop'
          $ProgressPreference = 'SilentlyContinue'
          Invoke-WebRequest %s -OutFile "%s"
		  %s
          if (Test-Path -LiteralPath "%s") { Remove-Item -LiteralPath "%s" -Recurse }
          Expand-Archive "%s" "%s"
          Remove-Item "%s"
          $ProgressPreference = 'Continue'
        ]],
				url,
				temp_file,
				check_cmd,
				target_folder,
				target_folder,
				temp_file,
				target_folder,
				temp_file
			),
		}
	else
		local temp_file = joinpath(data_folder, "/temp.gz")
		local check_cmd = ""
		if raw_hash ~= "" then
			check_cmd = string.format([[
			if command -v sha256sum >/dev/null 2>&1; then
				echo "%s  %s" | shasum -a 256 --check
			else
				echo "Error: sha256sum or shasum command not found. Cannot verify checksum." >&2
				exit 1
			fi
			]], raw_hash, temp_file, raw_hash, temp_file)
		end
		download_job = {
			"bash",
			"-c",
			string.format(
				[[
          set -e
          curl -L "%s" -o "%s"
		  %s
          rm -rf "%s"
          mkdir "%s"
          tar -xzf "%s" -C "%s"
          rm "%s"
        ]],
				url,
				temp_file,
				check_cmd,
				target_folder,
				target_folder,
				temp_file,
				target_folder,
				temp_file
			),
		}
	end

	utils.log_info("Downloading sql tools...")

	local co = coroutine.running()
	vim.fn.jobstart(download_job, {
		on_exit = function(_, code)
			if code ~= 0 then
				utils.log_error("Sql tools download error: exit code " .. code)
			else
				utils.log_info("Downloaded successfully")
				coroutine.resume(co)
			end
		end,
		stderr_buffered = true,
		on_stderr = function(_, data)
			if data and data[1] ~= "" then
				utils.log_error("Sql tools download error: " .. table.concat(data, "\n"))
			end
		end,
	})
	coroutine.yield()
end

return M
