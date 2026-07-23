local mssql = require("mssql")
local picker = require("mssql.picker")
local utils = require("mssql.utils")
local test_utils = require("tests.utils")
local ui = require("mssql.ui")
local state = require("mssql.state")

return {
	test_name = "Generated scripts from find_object are named after the object label",
	run_test_async = function()
		local buf, _client, qm, cleanup = test_utils.test_scaffold( { target_db = "tempdb" })

		-- mock picker to auto-select a fake object
		local original_pick = picker.pick
		local fake_item = {
			label = "dbo.CustomSproc",
			objectType = "StoredProcedure",
			metadata = { schema = "dbo", name = "CustomSproc" },
		}

		---@diagnostic disable-next-line: duplicate-set-field
		picker.pick = function(_items, _opts, on_select)
			vim.schedule(function()
				on_select(fake_item, nil)
			end)
		end

		-- mock LSP scripting request to return a fake sproc
		local original_lsp_request_async = utils.lsp_request_async
		---@diagnostic disable-next-line: duplicate-set-field
		utils.lsp_request_async = function(lsp_client, method, params)
			if method == "scripting/script" then
				return { script = "SELECT 1 FROM [dbo].[CustomTable];"}, nil
			end
			return original_lsp_request_async(lsp_client, method, params)
		end

		-- case 1: current buffer is empty --> should populate and rename empty buffer
		mssql.find_object({ scope = "database" })

		local renamed1 = test_utils.poll(function()
			local buf1_name = vim.api.nvim_buf_get_name(buf)
			return buf1_name:match("dbo%.CustomSproc%.sql$")
		end, { timeout_ms = 5000 })

		assert(renamed1, "Case 1: Empty buffer should be renamed to 'dbo.CustomSproc.sql' but was: " .. vim.api.nvim_buf_get_name(buf))
		assert(vim.b[buf].is_temp_name == nil, "Case 1: is_temp_name should be cleared after naming")
		-- wait for background reconnect to complete before starting case 2
		test_utils.wait_for_connected(buf)

		-- case 2: run find_object when active buffer has content --> should open a new buffer named after object
		fake_item.label = "dbo.AnotherSproc"
		mssql.find_object({ scope = "database" })

		local created_and_focused = test_utils.poll(function()
			local cur_buf = vim.api.nvim_get_current_buf()
			return cur_buf ~= buf and vim.api.nvim_buf_get_name(cur_buf):match("dbo%.AnotherSproc%.sql$")
		end, { timeout_ms = 5000})

		local active_buf2 = vim.api.nvim_get_current_buf()
		local buf2_name = vim.api.nvim_buf_get_name(active_buf2)
		assert(created_and_focused, "Case 2: Expected a new buffer named 'dbo.AnotherSproc.sql', but active buffer was: " .. buf2_name)
		assert(active_buf2 ~= buf, "Case 2: Should create a new buffer when current buffer is not empty")

		picker.pick = original_pick
		utils.lsp_request_async = original_lsp_request_async

		cleanup()
		if vim.api.nvim_buf_is_valid(active_buf2) then
			vim.api.nvim_buf_delete(active_buf2, { force = true })
		end
	end,
}
