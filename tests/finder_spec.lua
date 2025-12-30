local mssql = require("mssql")
local picker = require("mssql.picker")
local test_utils = require("tests.utils")

return {
	test_name = "Finder integration: script generation",
	run_test_async = function()
		local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })
		test_utils.wait_for_cache_content("dbo.Car", { type = "Table" })

		-- mock select
		local original_select = vim.ui.select

		---@diagnostic disable-next-line: duplicate-set-field
		vim.ui.select = function(items, opts, on_choice)
			if opts.prompt:match("Action for") then
				local idx
				for i, label in ipairs(items) do
					if label:lower():match("drop") then idx = i break end
				end
				vim.schedule(function()
					on_choice(items[idx], idx)
				end)
			else
				original_select(items, opts, on_choice)
			end
		end

		-- mock picker allows to intercept call to pick and immediately trigger callback
		local original_pick = picker.pick
		local next_intent = nil

		---@diagnostic disable-next-line: duplicate-set-field
		picker.pick = function(items, _opts, on_select)
			local target
			for _, item in ipairs(items) do
				if item.label == "dbo.Car" then target = item break end
			end

			vim.schedule(function()
				on_select(target, next_intent)
			end)
		end

		-- helper to wipe buffer so we can reuse it
		local wipe_buf = function(bufnr)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
		end

		-- test 1 - default action - intent = nil
		wipe_buf(buf)
		next_intent = nil

		mssql.find_object(buf)
		local create_success = test_utils.poll(function()
			local content = test_utils.get_buffer_content(buf)
			return content:lower():match("create table")
		end)
		assert(create_success, "Failed to generate CREATE script (Default action)")

		-- test 2 - select action - intent = select
		wipe_buf(buf)
		next_intent = "select"

		mssql.find_object(buf)

		local res_buf, _, results = test_utils.res_buf_catcher()
		assert(results:lower():find("hyundai"), "Failed to execute SELECT query")
		test_utils.cleanup_results_buffer(res_buf)

		-- test 3 - drop action - intent = drop
		wipe_buf(buf)
		next_intent = "drop"

		mssql.find_object(buf)
		local drop_success = test_utils.poll(function()
			local content = test_utils.get_buffer_content(buf)
			return content:lower():match("drop table")
		end)
		assert(drop_success, "Failed to generate DROP script")

		-- test 4 - menu action - intent menu picks drop
		wipe_buf(buf)
		next_intent = "menu"

		mssql.find_object(buf)
		local menu_success = test_utils.poll(function()
			local content = test_utils.get_buffer_content(buf)
			return content:lower():match("drop table")
		end)
		assert(menu_success, "Failed to generate a DROP script via menu flow")

		-- test 5 - cancellation - ensure pressing escape (item is nil) doesn't throw error
		wipe_buf(buf)

		---@diagnostic disable-next-line: duplicate-set-field
		picker.pick = function(_, _, on_select)
			vim.schedule(function() on_select(nil, nil) end)
		end

		local status, err = pcall(function() mssql.find_object(buf) end)
		assert(status, "Find object crashed on cancellation: " .. tostring(err))

		vim.ui.select = original_select
		picker.pick = original_pick
		cleanup()
	end,
}
