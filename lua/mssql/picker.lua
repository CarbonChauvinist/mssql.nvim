local state = require("mssql.state")

local M = {}

---@Type MssqlIconsFindObject
local fallback_default_picker_icons = {
	AggregateFunctionPartitionFunction = "󰡱",
	ScalarValuedFunction = "󰡱",
	StoredProcedure = "󰯁",
	TableValuedFunction = "󰡱",
	Table = "",
	View = "󱂬",
}

---@param items MssqlNode[] List of items to pick from
---@param opts PickerOptions Configuration options
---@param on_select fun(item: any, intent: string?) Callback when selection is made
M.pick = function(items, opts, on_select)
	local config = state.get_config() or {}
	local user_icons = (config.icons and config.icons.find_object) or {}
	local icons = setmetatable(user_icons, { __index = fallback_default_picker_icons })

	local title = opts.title or "Select Item"
	local keymaps = opts.keymaps or {}
	local has_snacks, snacks = pcall(require, "snacks")

	if has_snacks then
		local snacks_keys = {}
		local snacks_actions = {}
		for key, intent in pairs(keymaps) do
			local action_name = "mssql_action_" .. intent
			snacks_actions[action_name] = function(picker, item)
				picker:close()
				on_select(item, intent)
			end
			snacks_keys[key] = { action_name, mode = { "n", "i" } }
		end

		snacks.picker.pick({
			title = title,
			layout = "select",
			items = items,
			format = function(item)
				return {
					{ icons[item.nodeType], "SnacksPickerIcon" },
					{ " " },
					{ item.label },
					{ " " },
					{ item.picker_path, "SnacksPickerComment" },
				}
			end,
			actions = snacks_actions,
			win = { input = { keys = snacks_keys } },
			confirm = function(picker, item)
				picker:close()
				on_select(item, nil)
			end,
			cancel = function(picker)
				picker:close()
				on_select(nil, nil)
			end,
		})
		return
	end

	-- fzf-lua path
	if package.loaded["fzf-lua"] then
		local fzf = require("fzf-lua")

		-- prepare display lines with index prefix (to map back to cache items)
		-- Format: "1|  Tables/dbo.Car"
		local fzf_lines = {}
		for i, item in ipairs(items) do
			local icon = icons[item.nodeType]
			local display = string.format("%s %s%s", icon, item.picker_path or "", item.label)
			table.insert(fzf_lines, string.format("%d| %s", i, display))
		end

		-- helper to resolve selection back to item
		local resolve = function(selected)
			if not selected or not selected[1] then return nil end
			local idx = tonumber(selected[1]:match("^(%d+)|"))
			return items[idx]
		end

		local fzf_actions = {
			["default"] = function(selected)
				on_select(resolve(selected), nil)
			end
		}

		for key, intent in pairs(keymaps) do
			local fzf_key = key:lower():gsub("<m%-", "alt-"):gsub("<c%-", "ctrl-"):gsub(">", "")
			fzf_actions[fzf_key] = function(selected)
				on_select(resolve(selected), intent)
			end
		end

		fzf.fzf_exec(fzf_lines, {
			prompt = title,
			-- hide the "1|" prefix from the user
			fzf_opts = { ["--delimiter"] = "|", ["--with-nth"] = "2.." },
			actions = fzf_actions
		})
		return
	end

	-- vim.ui.select fallback
	vim.ui.select(items, {
		prompt = title,
		format_item = function(item)
			local icon = icons[item.nodeType]
			return string.format("%s %s%s", icon, item.picker_path or "", item.label)
		end,
	}, function(item)
		vim.schedule(function()
			on_select(item, nil)
		end)
	end)
end


return M
