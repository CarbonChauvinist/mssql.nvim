local downloader = require("mssql.tools_downloader")
local state = require("mssql.state")

return {
	test_name = "Tools Downloader: supports custom STS versions and SHA256 hashes",
	run_test_async = function()
		-- 1. Default version & checksum
		local default_url, default_hash = downloader.get_tools_download_url()
		assert(default_url:match("6%.0%.20260709%.1"), "Default URL should use 6.0.20260709.1")
		assert(default_hash ~= nil, "Default version should include SHA256 hash")

		-- 2. Direct parameter override with custom version & custom hash
		local custom_url1, custom_hash1 = downloader.get_tools_download_url({
			custom_version = "7.0.0",
			custom_version_sha256 = "dummy_sha256_hash",
		})
		assert(custom_url1:match("7%.0%.0"), "URL should use custom version 7.0.0 instead got: " .. custom_url1)
		assert(custom_hash1 == "dummy_sha256_hash", "Should return custom SHA256 hash")

		-- 3. Custom version without custom hash should omit default hash
		local custom_url2, custom_hash2 = downloader.get_tools_download_url({ custom_version = "7.0.0" })
		assert(custom_url2:match("7%.0%.0"), "URL should use custom version 7.0.0 instead got: " .. custom_url2)
		assert(custom_hash2 == nil, "Custom version without hash should return nil to skip mismatch")

		-- 4. Global config override via state.set_config() (bypasses network downloads)
		local orig_config = state.get_config()
		state.set_config({ sts_version = "8.1.0", sts_version_sha256 = "config_sha256" })
		local cfg_url, cfg_hash = downloader.get_tools_download_url()
		assert(cfg_url:match("8%.1%.0"), "Configured STS version 8.1.0 should be used instead got: " .. cfg_url)
		assert(cfg_hash == "config_sha256", "Configured SHA256 should be used")

		-- Restore original config
		state.set_config(orig_config)
	end,
}
