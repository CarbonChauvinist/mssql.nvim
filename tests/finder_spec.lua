local mssql = require("mssql")
local picker = require("mssql.picker")
local test_utils = require("tests.utils")
local explorer = require("mssql.explorer")

-- mock picker allows to intercept call to pick and immediately trigger callback
local original_pick = picker.pick
local next_intent = nil

local spec_pick = function(items, _opts, on_select)
	local target
	for _, item in ipairs(items) do
		if item.label == "dbo.Car" then target = item break end
	end

	vim.schedule(function()
		on_select(target, next_intent)
	end)
end

return {
	test_name = "Finder integration: script generation",
	run_test_async = function()
		local buf, _, qm, cleanup = test_utils.test_scaffold({ target_db = "TestDbB" })
		local status, _ = pcall(test_utils.wait_for_cache_content, "dbo.Car", { type = "Table", timeout = 15000})
		if not status then
			print("    [INFO] Cache cold/empty. Retrying initialization...")
			qm:initialise_cache_async({ scope = "database", force = true })

			-- even though we clear the refresh_coroutines in test_scaffold
			-- must still clear refresh_coroutine explicitly here after call to qm:initialise_cache_async
			-- since tests run directly inside test runners coroutine, any coroutine.running() calls return the test runner's coroutine
			for _, entry in pairs(require("mssql.explorer").get_cache()) do
				entry.refresh_coroutine = nil
			end

			test_utils.wait_for_cache_content("dbo.Car", { type = "Table", timeout = 30000 })
		end
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

		---@diagnostic disable-next-line: duplicate-set-field
		picker.pick = spec_pick

		-- helper to wipe buffer so we can reuse it
		local wipe_buf = function(bufnr)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
		end

		-- test 1 - default action - intent = nil
		wipe_buf(buf)
		next_intent = nil

		mssql.find_object({bufnr = buf})
		local res_buf, _, results = test_utils.res_buf_catcher()
		assert(results:lower():find("hyundai"), "Failed to execute SELECT query")
		test_utils.cleanup_results_buffer(res_buf)

		-- test 2 - select action - intent = select
		wipe_buf(buf)
		next_intent = "create"

		mssql.find_object({bufnr = buf})
		local create_success = test_utils.poll(function()
			local content = test_utils.get_buffer_content(buf)
			return content:lower():match("create table")
		end)
		assert(create_success, "Failed to generate CREATE script (Default action)")

		-- test 3 - drop action - intent = drop
		wipe_buf(buf)
		next_intent = "drop"

		mssql.find_object({bufnr = buf})
		local drop_success = test_utils.poll(function()
			local content = test_utils.get_buffer_content(buf)
			return content:lower():match("drop table")
		end)
		assert(drop_success, "Failed to generate DROP script")

		-- test 4 - menu action - intent menu picks drop
		wipe_buf(buf)
		next_intent = "menu"

		mssql.find_object({bufnr = buf})
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

		local status, err = pcall(function() mssql.find_object({bufnr = buf}) end)
		assert(status, "Find object crashed on cancellation: " .. tostring(err))


		-- test 6 - user config override
		wipe_buf(buf)
		next_intent = nil
		res_buf = nil
		picker.pick = spec_pick

		local state = require("mssql.state")
		local original_config = state.get_config()
		local new_config = vim.deepcopy(original_config or {})
		new_config.find_object_actions = {
			t = {
				default = "select",
				actions = {
					{ action = "select" },
					{ action = "create" }
				}
			}
		}
		state.set_config(new_config)

		mssql.find_object({bufnr = buf})
		local override_success = test_utils.poll(function()
			local content = test_utils.get_buffer_content(buf)
			return content:lower():match("select top %(1000%)")
		end)
		res_buf = test_utils.res_buf_catcher()

		assert(override_success, "Failed to respect User Configuration Override (Default -> Select)")
		if res_buf then
			assert(test_utils.get_buffer_content(res_buf):lower():match("hyundai"), "Results not as expected")
			test_utils.cleanup_results_buffer(res_buf)
		end
		wipe_buf(buf)

		state.set_config(original_config)

		-- test 7 - unknown intent graceful fallback
		wipe_buf(buf)
		next_intent = "unknown thing"

		local unknown_intent_status, unknown_intent_err = pcall(function() mssql.find_object({bufnr = buf}) end)
		assert(unknown_intent_status, "Plugin crashed on unknown intent: " .. tostring(unknown_intent_err))
		local content = test_utils.get_buffer_content(buf)
		assert(content == "", "Should not generate script for unknown intent. Got: " .. content)

		vim.ui.select = original_select
		picker.pick = original_pick
		cleanup()
	end,
}
