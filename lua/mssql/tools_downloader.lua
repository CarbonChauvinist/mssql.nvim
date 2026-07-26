local utils = require("mssql.utils")
local joinpath = vim.fs.joinpath
local M = {}

-- Check the OS and system architecture
---@param opts? { custom_version?: string, custom_version_sha256?: string }
M.get_tools_download_url = function(opts)
	opts = opts or {}
	local state = require("mssql.state")
	local config = state.get_config() or {}
	local default_ver = "6.0.20260709.1"

	local sts_ver = opts.custom_version or config.sts_version or default_ver
	local target_sha256 = opts.custom_version_sha256 or config.sts_version_sha256

	local base_url = "https://github.com/microsoft/sqltoolsservice/releases/download"
	local dotnet_ver = "net10.0"
	local MIGRATION = "Microsoft.SqlTools.Migration"
	local SERVICE_LAYER = "Microsoft.SqlTools.ServiceLayer"

	---@param pkg string
	---@param os_name string
	---@param arch string
	---@param ext string
	---@return string
	local make_url = function(pkg, os_name, arch, ext)
		return string.format("%s/%s/%s-%s-%s-%s.%s", base_url, sts_ver, pkg, os_name, arch, dotnet_ver, ext)
	end

	local urls = {
		Windows = {
			arm64 = make_url(MIGRATION, "win", "arm64", "zip"),
			x64 = make_url(MIGRATION, "win", "x64", "zip"),
			x86 = make_url(MIGRATION, "win", "x86", "zip"),
		},
		Linux = {
			arm64 = make_url(SERVICE_LAYER, "linux", "arm64", "tar.gz"),
			x64 = make_url(SERVICE_LAYER, "linux", "x64", "tar.gz"),
		},
		OSX = {
			arm64 = make_url(SERVICE_LAYER, "osx", "arm64", "tar.gz"),
			x64 = make_url(SERVICE_LAYER, "osx", "x64", "tar.gz")
		},
	}
	local sha256sums = {
		Windows = {
			arm64 = "4fb6d2a5a6a7c304bdffaca65f80dfae76010d22ef6d09fc3fedab8393e7b50a",
			x64 = "44e4197de678c856254a832adbc18703bfdea984d2cd1efccacb25b5f8343c71",
			x86 = "3456ac726c77a8e5e6f925d287be2f3c5f99f0f6b1ddeeb67d5a960238fc7189",
		},
		Linux = {
			arm64 = "c872ff665f847beddd9f37f98ba52f255b0f1a6700c64e29d2e230bcae5fc183",
			x64 = "47d3d758b529e72cac0519a2d6bb9c9e046f60d2008e048fdd9b8d3de3d28461"
		},
		OSX = {
			arm64 = "83dbab91f26b37fa166b76dd7b998a14878f9dfe379da2db933bb07f90249e65",
			x64 = "ae48b70623c493c9366bafb79ab6f577f6a2726079b53351ce395df8b7974a1a"
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

	---@return string?
	local get_hash = function()
		if target_sha256 and target_sha256 ~= "" then
			return target_sha256
		elseif sts_ver == default_ver then
			return sha256sums[os] and sha256sums[os][arch]
		else
			return nil
		end
	end

	return url, get_hash()
end

-- Delete any existing download folder, download, unzip and write the most recent url to the config
M.download_tools_async = function(url, data_folder)
	local target_folder = joinpath(data_folder, "sqltools")
	local _, expected_hash = M.get_tools_download_url()
	local raw_hash = (expected_hash or ""):lower()

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
          curl -sSL --fail "%s" -o "%s"
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
	local stderr_lines = {}

	vim.fn.jobstart(download_job, {
		on_exit = function(_, code)
			if code ~= 0 then
				local err_msg = "Sql tools download failed with exit code " .. code
				if #stderr_lines > 0 then
					err_msg = err_msg .. ": " .. table.concat(stderr_lines, "\n")
				end
				utils.log_error(err_msg)
				utils.try_resume(co, false, err_msg)
			else
				utils.log_info("Downloaded successfully")
				utils.try_resume(co, true, nil)
			end
		end,
		stderr_buffered = true,
		on_stderr = function(_, data)
			if data then vim.list_extend(stderr_lines, data) end
		end,
	})
	local success, err = coroutine.yield()
	if not success then
		error(err or "Failed to download SQL tools", 0)
	end
end

return M
