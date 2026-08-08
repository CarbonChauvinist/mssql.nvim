local utils = require("mssql.utils")
local joinpath = vim.fs.joinpath
local M = {}

---Formats a clear error message from a failed vim.system command
---@param cmd_name string
---@param result { code: integer, stdout: string, stderr: string }
---@return string
local function format_cmd_error(cmd_name, result)
	local details = vim.trim(result.stderr or "")
	if details == "" then
		details = vim.trim(result.stdout or "")
	end
	return string.format("Failed to download SQL tools (%s failed with exit code %d): %s", cmd_name, result.code, details)
end

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
		Linux = {
			arm64 = make_url(SERVICE_LAYER, "linux", "arm64", "tar.gz"),
			x64 = make_url(SERVICE_LAYER, "linux", "x64", "tar.gz"),
		},
	}
	local sha256sums = {
		Linux = {
			arm64 = "c872ff665f847beddd9f37f98ba52f255b0f1a6700c64e29d2e230bcae5fc183",
			x64 = "47d3d758b529e72cac0519a2d6bb9c9e046f60d2008e048fdd9b8d3de3d28461"
		},
	}

	local os = jit.os
	local arch = jit.arch

	if not urls[os] then
		error("Your OS " .. os .. " is not supported.", 0)
	end

	local url = urls[os][arch]
	if not url then
		error("Your system architecture " .. arch .. " is not supported.", 0)
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
	local temp_file = joinpath(data_folder, "/temp.gz")

	if vim.fn.isdirectory(target_folder) == 1 then
		vim.fn.delete(target_folder, "rf")
	end
	vim.fn.mkdir(target_folder, "p")

	local dl = vim.system({"curl", "-L", "-s", "-o", temp_file, url})
	utils.log_info("Downloading SQL tools...")
	local dl_result = dl:wait()
	if dl_result.code ~= 0 then
		error(format_cmd_error("curl", dl_result))
	else
		utils.log_info("SQL tools downloaded successfully")
	end

	if expected_hash and expected_hash ~= "" then
		local check_res = vim.system({ "sha256sum", temp_file }):wait()
		if check_res.code ~= 0 then
			error(format_cmd_error("sha256sum", check_res))
		end

		local actual_hash = check_res.stdout:match("^(%x+)")
		if not actual_hash or actual_hash:lower() ~= expected_hash:lower() then
				error(string.format("Checksum verification failed! Expected: %s, Got: %s", expected_hash, actual_hash))
		end
	end

	local tar_res = vim.system({ "tar", "-xzf", temp_file, "-C", target_folder}):wait()
	if tar_res.code ~=0 then
		error(format_cmd_error("tar", tar_res))
	end
end

return M
