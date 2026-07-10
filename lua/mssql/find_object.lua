local utils = require("mssql.utils")
local state = require("mssql.state")
local picker = require("mssql.picker")
local explorer = require("mssql.explorer")

local M = {}

-- Constants for Scripting Actions
---@enum MssqlScriptType
local ScriptType = {
	SELECT = "ScriptSelect", --[[@as MssqlScriptStrategy]]
	CREATE = "ScriptCreate", --[[@as MssqlScriptStrategy]]
	DROP = "ScriptDrop" --[[@as MssqlScriptStrategy]]
}

-- Operation Codes (matches SMO/ServiceLayer enums)
---@enum MssqlOpCode
local OpCode = {
	SELECT = 0, --[[@as MssqlOpCodeInteger]]
	CREATE = 1, --[[@as MssqlOpCodeInteger]]
	INSERT = 2, --[[@as MssqlOpCodeInteger]]
	UPDATE = 3, --[[@as MssqlOpCodeInteger]]
	DELETE = 4, --[[@as MssqlOpCodeInteger]]
	EXECUTE = 5, --[[@as MssqlOpCodeInteger]]
	ALTER = 6, --[[@as MssqlOpCodeInteger]]
}


-- internal registry
---@type table<MssqlActionId, { id: MssqlActionId, op: MssqlOpCodeInteger, script_type: MssqlScriptStrategy, default_label: string }>
local BUILTIN_ACTIONS = {
	select = {
		id = "select",
		op = OpCode.SELECT,
		script_type = ScriptType.SELECT,
		default_label = "Select (TOP 1000)",
	},
	create = {
		id = "create",
		op = OpCode.CREATE,
		script_type = ScriptType.CREATE,
		default_label = "Create",
	},
	drop = {
		id = "drop",
		op = OpCode.DELETE,
		script_type = ScriptType.DROP,
		default_label = "Drop"
	},
	alter = {
		id = "alter",
		op = OpCode.ALTER,
		script_type = ScriptType.CREATE,
		default_label = "Alter",
	},
	execute = {
		id = "execute",
		op = OpCode.EXECUTE,
		script_type = ScriptType.CREATE,
		default_label = "Execute"
	}
}

--- Helper to escape Lua magic characters (brackets, parens, dots, etc.)
---@param text string
local function escape_pattern(text)
	return text:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end


---Resolves a user config entry (string or table) to an internal action definition
---@param user_entry MssqlActionId|MssqlActionEntry
---@return MssqlResolvedAction?
local function resolve_action(user_entry)
	if not user_entry then return nil end

	if type(user_entry) == "string" then
		return BUILTIN_ACTIONS[user_entry]
	end

	local def = BUILTIN_ACTIONS[user_entry.action]
	if not def then return nil end
	return vim.tbl_extend("force", def, { label = user_entry.label })
end

--[[
			scriptOptions Possible values:
			  ScriptCreate
			  ScriptDrop
			  ScriptCreateDrop
			  ScriptSelect


		public enum ScriptingOperationType
		{
		    Select = 0,
		    Create = 1,
		    Insert = 2,
		    Update = 3,
		    Delete = 4,
		    Execute = 5,
		    Alter = 6
		}
--]]

---@param item MssqlNode
---@param client vim.lsp.Client
---@param opts? { action_def?: MssqlResolvedAction, owner_uri?: string, connect_params?: MssqlConnectParams }
---@return { script: string, select: boolean }
local generate_script_async = function(item, client, opts)
	opts = opts or {}
	local action_def = opts.action_def
	local connect_params = opts.connect_params
	local owner_uri = opts.owner_uri

	local config = state.get_config() or {}

	-- resolve default if no specific action passed
	if not action_def then
		local type_key = explorer.OBJECT_TYPE_MAP[item.objectType]
		local type_config = config.find_object_actions and config.find_object_actions[type_key]
		action_def = resolve_action(type_config and type_config.default)
	end

	if not action_def then
		local msg = "No script definition found for " .. tostring(item.objectType)
		utils.log_error(msg)
		error(msg, 0)
	end

	local target_db = item.metadata.urn and item.metadata.urn:match("Database%[@Name='(.-)'%]")
	if target_db and connect_params and connect_params.connection and connect_params.connection.options then
		local current_db = connect_params.connection.options.database
		if target_db ~= current_db then
			local temp_uri = "mssql://scripting/" .. connect_params.connection.options.server .. "/" .. target_db

			if not state.is_scripting_uri_connected(temp_uri) then
				local temp_params = vim.deepcopy(connect_params) --[[@as MssqlConnectParams]]
				temp_params.ownerUri = temp_uri
				temp_params.connection.options.database = target_db
				temp_params.connection.options.databaseDisplayName = target_db
				if temp_params.connection.summary then
					temp_params.connection.summary.databaseName = target_db
				end

				local _, connect_err = utils.lsp_request_async(client, "connection/connect", temp_params)
				if not connect_err then
					local result, wait_err = utils.wait_for_notification_async(0, client, "connection/complete", 10000)
					if not wait_err and (utils.is_empty(result) or utils.is_empty(result.errorMessage)) then
						state.mark_scripting_uri_connected(temp_uri)
					end
				end
			end

			if state.is_scripting_uri_connected(temp_uri) then
				owner_uri = temp_uri
			end
		end
	end

	local scripting_params = {
		scriptDestination = "ToEditor",
		scriptingObjects = {
			{
				type = item.metadata.metadataTypeName,
				schema = item.metadata.schema,
				name = item.metadata.name,
				urn = item.metadata.urn,
			},
		},
		scriptOptions = {
			scriptCreateDrop = action_def.script_type,
			typeOfDataToScript = "SchemaOnly",
			scriptStatistics = "ScriptStatsNone",
		},
		ownerURI = owner_uri or utils.lsp_file_uri(0),
		operation = action_def.op,
	}

	local res, script_err = utils.lsp_request_async(client, "scripting/script", scripting_params)
	if script_err then
		error("Error generating script: " .. vim.inspect({ err = script_err, scripting_params = scripting_params }), 0)
	end

	if utils.is_empty(res) or utils.is_empty(res.script) then
		error("Error generating script (no script returned from language server)", 0)
	end

	local script_content = res.script

	if item.objectType == "Table" and target_db then
		local schema = ""
		local name = ""
		if not utils.is_empty(item.metadata) then
			schema = escape_pattern(item.metadata.schema)
			name = escape_pattern(item.metadata.name)
		end

		local pattern = "((%[[^%]]+%])%.%[" .. schema .. "%]%.%[" .. name .. "%])"
		script_content, _ = string.gsub(script_content, pattern, function(full_match, db_name)
			if db_name ~= "[" .. target_db .. "]" then
				return "[" .. target_db.. "].[" .. schema .. "].[" .. name .. "]"
			end
			return full_match
		end)
	end

	return {
		-- strip carriage returns
		script = script_content:gsub("\r", ""),
		select = (scripting_params.operation == 0),
	}
end

---@param cache MssqlNode[]
---@param title string
---@return MssqlNode? item
---@return string? intent The action ID (e.g. "create", "drop", "menu") or nil for default
local pick_item_async = function(cache, title)
    local co = coroutine.running()
    local config = state.get_config()

	picker.pick(cache, {
		title = title,
		keymaps = (config and config.find_object_keymaps) or {}
	}, function(item, intent)
		utils.try_resume(co, item, intent)
	end)

	return coroutine.yield()
end

---@param connection_options MssqlConnectionOptions
---@param lsp_client vim.lsp.Client
---@param opts? FindObjectOpts
---@return { script: string, select: boolean }?
M.find_async = function(connection_options, lsp_client, opts)
	opts = opts or {}
	local scope = utils.normalize_findobject_scope(opts.scope)

	local title = "Find"
	if connection_options and connection_options.database and connection_options.server then
		title = connection_options.server .. " | " .. connection_options.database
	end
	scope = utils.normalize_findobject_scope(scope)

	local key = explorer.create_cache_key(connection_options, scope) --[[@as ConnectionKey]]
	---@type MssqlNode[]

	local cache = (explorer.get_cache()[key] and explorer.get_cache()[key].cache) or {}

	local items_to_show = cache

	if opts.object_type then
		items_to_show = vim.tbl_filter(function(node)
			local short_code = explorer.OBJECT_TYPE_MAP[node.objectType]
			return short_code == opts.object_type
		end, explorer.get_cache())
	end

	local item, intent = pick_item_async(items_to_show, title)
	if not item then return end

	local config = state.get_config() or {}
	local config_key = explorer.OBJECT_TYPE_MAP[item.objectType]
	local type_config = config.find_object_actions[config_key]

	local chosen_action = nil

	if intent and intent ~= "menu" then
		-- fast track direct selections (e.g. Alt-C, Alt-D)
		if type_config and type_config.actions then
			for _, act in ipairs(type_config.actions) do
				if act.action == intent then
					chosen_action = resolve_action(act)
					break
				end
			end
		end

		if not chosen_action then
			utils.log_warn("Action '" .. intent .. "' not found for object type " .. item.objectType)
			return
		end

	elseif intent == "menu" and type_config and type_config.actions and #type_config.actions > 1 then
		local co = coroutine.running()

		-- map to simple string to avoid UI crashes
		local action_labels = {}
		for _, act in ipairs(type_config.actions) do
			table.insert(action_labels, act.label or act.action)
		end

		vim.schedule(function()
			vim.ui.select(action_labels, {
				prompt = "Action for " .. item.objectType .. ":",
			}, function(choice, idx)
				if choice and idx then
					utils.try_resume(co, resolve_action(type_config.actions[idx]))
				else
					utils.try_resume(co, nil)
				end
			end)
		end)

		chosen_action = coroutine.yield()
		if not chosen_action then return end
	end

	return generate_script_async(item, lsp_client, { action_def = chosen_action, owner_uri = opts.owner_uri, connect_params = opts.connect_params })
end

return M
