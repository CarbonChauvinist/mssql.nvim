local utils = require("mssql.utils")
local state = require("mssql.state")
local picker = require("mssql.picker")

local M = {}

-- one cache per server and db (ie per connect opts)
---@type table<ConnectionKey, GlobalCacheEntry>
local global_cache = {}

-- SESSION ROUTER
-- Tracks active callbacks by Session ID so multiple sessions don't clobber each other's handlers
---@type table<string, function>
local active_sessions = {}

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

-- lookup table mapping ObjectType strings to Config Key strings
---@type table<string, string>
local OBJECT_TYPE_MAP = {
	AggregateFunctionPartitionFunction = "f",
	ScalarValuedFunction = "f",
	StoredProcedure = "sp",
	TableValuedFunction = "f",
	Table = "t",
	View = "v",
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

--- Generates a consistent cache key.
--- For 'server' scope, strip the specific database name so the cache is shared
--- across all DBs on the same server instance.
---@param opts MssqlConnectionOptions
---@param scope string
---@return string
local function get_cache_key(opts, scope)
	local key_opts = vim.deepcopy(opts)
	if scope == "server" then
		key_opts.database = nil
		key_opts.DatabaseDisplayName = nil
	end
	return vim.json.encode(key_opts) .. "|" .. scope
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

---@param client vim.lsp.Client
---@param connection_options MssqlConnectionOptions
---@param timeout_ms? integer Optional timeout in milliseconds (default: 10000)
---@param cancellation_token? { cancel: boolean, cleanup_callback: function }
---@return MssqlSession? | boolean?
---@return string? msg
local get_session_async = function(client, connection_options, timeout_ms, cancellation_token)
	if type(timeout_ms) ~= "number" or timeout_ms <= 0 then
		timeout_ms = 10000
	end
	connection_options = vim.deepcopy(connection_options)
	connection_options.ServerName = connection_options.server
	connection_options.DatabaseName = connection_options.database
	connection_options.UserName = connection_options.user
	connection_options.EnclaveAttestationProtocol = connection_options.attestationProtocol

	-- For some reason, if there is no display name set on the connection parameters then
	-- the language server will treat this as a default/system database:
	-- https://github.com/microsoft/sqltoolsservice/blob/49036c6196e73c3791bca5d31e97a16afee00772/src/Microsoft.SqlTools.ServiceLayer/ObjectExplorer/ObjectExplorerService.cs#L537
	connection_options.DatabaseDisplayName = connection_options.DatabaseDisplayName or connection_options.database

	local co = coroutine.running()
	local resumed = false
	local timeout_timer

	if cancellation_token and cancellation_token.cancel then
		return nil, "Cancelled"
	end

	-- setup event listener
	local dispose
	dispose = state.on_event("objectexplorer/sessioncreated", function(err, result, ctx)
		if ctx and ctx.client_id == client.id then
			if not resumed and result and result.rootNode then
				resumed = true
				utils.try_resume(co, result, err)
			end
		end
	end)

	-- attach cancellation handler for duration of this call
	if cancellation_token then
		cancellation_token.cleanup_callback = function()
			if not resumed then
				resumed = true
				if dispose then dispose() end
				if timeout_timer then timeout_timer:close() end
				utils.try_resume(co, nil, "Cancelled")
			end
		end
	end

	-- send request
	---@diagnostic disable-next-line: param-type-mismatch
	client:request("objectexplorer/createsession", connection_options, function(err, result)
		if err then
			if not resumed then
				resumed = true
				if dispose then dispose() end
				if timeout_timer then timeout_timer:close() end
				utils.try_resume(co, nil, err)
			end
			return
		end

		if result and result.rootNode then
			if not resumed then
				resumed = true
				if dispose then dispose() end
				if timeout_timer then timeout_timer:close() end
				utils.try_resume(co, result, nil)
			end
		end
	end)

	timeout_timer = vim.defer_fn(function()
		if not resumed then
			resumed = true
			if dispose then dispose() end
			utils.try_resume(co, nil, "Timeout waiting for session created")
		end
	end, timeout_ms)

	local result, err = coroutine.yield()

	if err then return nil, err end

	if not (result and result.rootNode) then
		utils.log_error("Session created but missing rootNode. Result: " .. vim.inspect(result))
		return nil
	end

	if result.rootNode and result.rootNode.objectType == "Server" then
		result.target_path = result.rootNode.nodePath
	end

	return result
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

---@param err lsp.ResponseError?
---@param result { sessionId: string }?
---@param ctx table
local function main_expand_handler(err, result, ctx)
	if not result or not result.sessionId then return end

	local session_callback = active_sessions[result.sessionId]
	if session_callback then
		session_callback(err, result, ctx)
	end
end

---@param lsp_client vim.lsp.Client
---@param connection_options MssqlConnectionOptions
---@param cancellation_token { cancel: boolean, cleanup_callback: function }
---@param scope string? Optional ("server" | "database"). Defaults to "database".
---@param timeout_ms integer? Optional timeout in milliseconds (default: 10000)
---@return MssqlNode[] | boolean? result Returns false or nil on failure/timeout
---@return string? msg
local get_object_cache_async = function(lsp_client, connection_options, cancellation_token, scope, timeout_ms)

	if not scope or type(scope) ~= "string" or (scope ~= "database" and scope ~= "server") then
		scope = "database"
	end

	local db_allow_list = connection_options and connection_options.databaseAllowList
	local db_deny_list = connection_options and connection_options.databaseDenyList

    utils.wait_for_schedule_async()
    if type(timeout_ms) ~= "number" or timeout_ms <= 0 then
        timeout_ms = 10000
    end
	local start_time = vim.uv.hrtime()
	state.on_event("objectexplorer/expandcompleted", main_expand_handler, "mssql_find_object_global")

	-- prepare session options
	-- if scope is 'server', we MUST NOT bind the Object Explorer session to the specific database
	-- we need to connect to the server Root (default/master) to see the "Databases" folder
	-- and navigate to siblings
	local session_opts = vim.deepcopy(connection_options)
	if scope == "server" then
		session_opts.database = nil
		session_opts.DatabaseDisplayName = nil
	end
    local session, err = get_session_async(lsp_client, session_opts, timeout_ms, cancellation_token)

    if not session or not session.sessionId or not session.rootNode then
        return nil, err or "Session creation failed or returned invalid data (missing rootNode)"
    end
    ---@cast session -nil

	local elapsed_ns = vim.uv.hrtime() - start_time
	local elapsed_ms = elapsed_ns / 1000000
	local remaining_ms = timeout_ms - elapsed_ms

	if remaining_ms <= 0 then
		return nil, "Operation timed out after session creation"
	end

    ---@type string?
    local session_id = session.sessionId
    local cache = {}
    local expand_count = 0
    local co = coroutine.running()
	local timeout_timer

	-- setup traversal paths
	-- Note: session.target_path might be nil if we connected to Root (server scope)
    local target_database_name = connection_options.database

	-- if session root is already the database (DB scope), mark it found immediately
	-- if we are in Server scope (Root), this will be false, and we will find DBs via expansion
    local found_db_node = (session.rootNode.objectType == "Database")
	local expand

	local clean_up_and_return = function(return_value, cleanup_err)
		if timeout_timer and not timeout_timer:is_closing() then
			timeout_timer:close()
			timeout_timer = nil
		end

		if session_id then
				active_sessions[session_id] = nil
		end

		if session_id then
			---@diagnostic disable-next-line: param-type-mismatch
			lsp_client:request("objectexplorer/closeSession", {
				sessionId = session_id,
			}, function(close_err, result, _, _)
				session_id = nil
				return result, close_err
			end)
		end

        if coroutine.status(co) == "suspended" then
			local ok, resume_err
            if cleanup_err then
                ok, resume_err = coroutine.resume(co, nil, cleanup_err)
            else
                ok, resume_err = coroutine.resume(co, return_value)
            end

			if not ok then
				utils.log_error("Failed to resume coroutine: " .. tostring(resume_err))
			end
        end

    end

	-- attach cleanup trigger to token so we can abort from outside
	cancellation_token.cleanup_callback = function()
		clean_up_and_return(nil, "Cancelled by user/cleanup")
	end

	local on_expand_result = function(_, expand_result, _)
		local nodes = (type(expand_result) == "table" and expand_result.nodes) or {}

		for _, node in ipairs(nodes) do
			-- capture: add valid objects (Tables, Views, SProcs) to cache
			local type_key = OBJECT_TYPE_MAP[node.objectType]

			if type_key then
				-- filter our system schemas present in every db
				local schema = node.metadata and node.metadata.schema or ""
				if schema == "sys" or schema == "INFORMATION_SCHEMA" then
					goto continue
				end
				local name = node.metadata and node.metadata.name or ""
				local full_name = schema .. "." .. name

				-- extract database name from URN
				local db_name = "UNKNOWN"
				if node.metadata and node.metadata.urn then
					db_name = node.metadata.urn:match("Database%[@Name='([^']+)']") or db_name
				end
				node.db_name = db_name
				node.meta_info = string.format("(%s | %s)", db_name, node.objectType)

				-- fallback pre-formatted text (for vim.ui.select)
				-- FORMAT: "dbo.Car    (TestDbB | Table)"
				-- "[icon] schema.object_name    (database | objectType)"
				node.text = string.format("%-30s (%s | %s)", node.label, db_name, node.objectType)

				local filters =	connection_options.objectFilters and connection_options.objectFilters[type_key]
				local allowed = true

				if filters then
					local result = utils.filter_list({ full_name }, filters.allow, filters.deny)
					if #result == 0 then
						allowed = false
					end
				end
				if allowed then
					table.insert(cache, node)
				end

				-- navigation: what to expand next
			elseif node.nodePath then
				local should_expand = false
				local is_db = (node.objectType == "Database")
				local is_db_structure = (
				  node.objectType == "Tables"
				  or node.objectType == "Views"
				  or node.objectType == "StoredProcedures"
				  or node.objectType == "Functions"
				)
				local is_nav_folder = (node.label == "Databases" or node.label == "System Databases")

				if is_nav_folder then
					-- always traverse structure folders
					should_expand = true

				elseif is_db_structure and scope == "database" then
					should_expand = true

				elseif is_db then
					local allowed = #utils.filter_list({node.label}, db_allow_list, db_deny_list) > 0

					if allowed then
						if scope == "server" then
							-- expand all allowed databases
							should_expand = true
							found_db_node = true
						elseif target_database_name and node.label:lower() == target_database_name:lower() then
							-- only expand target database when in DB scope
							should_expand = true
							found_db_node = true
						end
					end

				elseif found_db_node or scope == "server" then
					-- these are child folders (e.g. "Tables", "Views") inside a Database
					-- if we're here, we are either in Server scope (expand everything we find)
					-- OR in DB scope and strictly inside the 'found' DB
					should_expand = true
				end

				if should_expand then
					expand(node.nodePath)
				end
			end
			::continue::
		end

		expand_count = expand_count - 1
		if expand_count == 0 then
			if not session.target_path or found_db_node then
				clean_up_and_return(cache)
			else
				clean_up_and_return(false)
			end
		end
	end

    expand = function(path)
        expand_count = expand_count + 1

        vim.schedule(function()
            if cancellation_token.cancel then
                clean_up_and_return(false)
                return
            end

            ---@diagnostic disable-next-line: param-type-mismatch
            local status, _request_id = lsp_client:request("objectexplorer/expand", {
                sessionId = session_id,
                nodePath = path,
            }, function(expand_err, _)
                if expand_err then
                    utils.log_warn("Expand request failed for " .. path .. ": " .. (expand_err.message or "unknown error"))

					expand_count = expand_count - 1
					if expand_count == 0 then
						if not session.target_path or found_db_node then
							clean_up_and_return(cache)
						else
							clean_up_and_return(false)
						end
					end
                    return
                end

            end)

            if not status then
				clean_up_and_return(nil, "LSP Request failed to send")
            end
        end)
		end

    if session_id then
        active_sessions[session_id] = on_expand_result
    end

	-- since it takes time to create the session
	-- give expansion phase own clean timer, or remaining time
	local expansion_timeout = math.max(remaining_ms, 5000)

    timeout_timer = vim.defer_fn(function()
        if coroutine.status(co) == "suspended" then
            clean_up_and_return(nil, "Operation timed out waiting for object explorer expansion")
        end
    end, math.floor(expansion_timeout))


    expand(session.rootNode.nodePath)
    local result, cr_err = coroutine.yield()
    if cr_err then
        return nil, cr_err
    end

    return result
end

---@param item MssqlNode
---@param client vim.lsp.Client
---@param action_def MssqlResolvedAction? The resolved action definition
---@return { script: string, select: boolean }
local generate_script_async = function(item, client, action_def)

	local config = state.get_config() or {}

	-- resolve default if no specific action passed
	if not action_def then
		local type_key = OBJECT_TYPE_MAP[item.objectType]
		local type_config = config.find_object_actions and config.find_object_actions[type_key]
		action_def = resolve_action(type_config and type_config.default)
	end

	-- local def = action_def or resolve_action(type_config and type_config.default)
	if not action_def then
		local msg = "No script definition found for " .. tostring(item.objectType)
		utils.log_error(msg)
		error(msg, 0)
	end

	local scripting_params = {
		scriptDestination = "ToEditor",
		scriptingObjects = {
			{
				type = item.metadata.metadataTypeName,
				schema = item.metadata.schema,
				name = item.metadata.name,
			},
		},
		scriptOptions = {
			scriptCreateDrop = action_def.script_type,
			typeOfDataToScript = "SchemaOnly",
			scriptStatistics = "ScriptStatsNone",
		},
		ownerURI = utils.lsp_file_uri(0),
		operation = action_def.op,
	}

	local res, script_err = utils.lsp_request_async(client, "scripting/script", scripting_params)
	if script_err then
		error("Error generating script: " .. vim.inspect({ err = script_err, scripting_params = scripting_params }), 0)
	end

	if not (res and res.script) then
		error("Error generating script (no script returned from language server)", 0)
	end

	return {
		-- strip carriage returns
		script = res.script:gsub("\r", ""),
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

-- Initialises the cache, unless it already exists
-- If force is true, then gets a new cache and overwrites
---@param lsp_client vim.lsp.Client
---@param connection_options MssqlConnectionOptions
---@param scope? string
---@param force? boolean
---@param timeout_ms? integer Optional timeout in milliseconds (default: 30000 if server, 10000 if database)
---@return boolean success
M.initialise_cache_async = function(lsp_client, connection_options, scope, force, timeout_ms)
	if not scope or type(scope) ~= "string" or (scope ~= "server" and scope ~= "database") then
		scope = "database"
	end

	if not timeout_ms or type(timeout_ms) ~= "number" or timeout_ms <= 0 then
		timeout_ms = (scope == "server") and 30000 or 10000
	end


	if type(force) ~= "boolean" or not force then
		force = false
	end

	local key = get_cache_key(connection_options, scope) --[[@as ConnectionKey]]
	if not global_cache[key] then
		global_cache[key] = {}
	end

	-- don't refresh if we are already refreshing or have refreshed previously
	if (global_cache[key].cache or M.is_refreshing(key)) and not force then
		return true
	end

	-- cancel any currently running
	M.cancel_refresh(connection_options, scope)

	local cancellation_token = { cancel = false }
	global_cache[key].cancellation_token = cancellation_token

	global_cache[key].refresh_coroutine = coroutine.running()
	vim.cmd("redrawstatus")
	local new_cache, err = get_object_cache_async(lsp_client, connection_options, cancellation_token, scope, timeout_ms)
	if err then
		if not err:match("Cancelled") then
			utils.log_warn("Cache initialization failed: " .. tostring(err))
		end
		return false
	end

	if not cancellation_token.cancel and type(new_cache) == "table" then
		global_cache[key].cache = new_cache
	end
	return true
end

---@param connection_options MssqlConnectionOptions
---@param lsp_client vim.lsp.Client
---@param scope string? Optional scope ("server" | "database"). Defaults to "database".
---@return { script: string, select: boolean }?
M.find_async = function(connection_options, lsp_client, scope)
	local title = "Find"
	if connection_options and connection_options.database and connection_options.server then
		title = connection_options.server .. " | " .. connection_options.database
	end

	if not scope or type(scope) ~= "string" or (scope ~= "server" and scope ~= "database") then
		scope = "database"
	end

	local key = get_cache_key(connection_options, scope) --[[@as ConnectionKey]]
	---@type MssqlNode[]
	local cache = (global_cache[key] and global_cache[key].cache) or {}

	local item, intent = pick_item_async(cache, title)
	if not item then return end

	local config = state.get_config() or {}
	local config_key = OBJECT_TYPE_MAP[item.objectType]
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

	return generate_script_async(item, lsp_client, chosen_action)
end

---@param in_use_connections MssqlConnectionOptions[]
M.delete_unused_cache = function(in_use_connections)
	-- convert to keys first
	local in_use = {}
	for _, in_use_connection in ipairs(in_use_connections) do
		---@type ConnectionKey|MssqlConnectionOptions
		local key = in_use_connection
		if type(key) == "table" then
			key = vim.json.encode(key)
		end
		in_use[key] = true
	end

	for cache_key, entry in pairs(global_cache) do
		if not in_use[cache_key] then
			if entry.cancellation_token then
				entry.cancellation_token.cancel = true
			end
			global_cache[cache_key] = nil
		end
	end
end

---@param connection_options MssqlConnectionOptions|string
---@return boolean?
M.is_refreshing = function(connection_options)
	local key = connection_options
	if type(key) == "table" then
		key = vim.json.encode(connection_options)
	end

	return (
		global_cache[key]
		and global_cache[key].refresh_coroutine
		and type(global_cache[key].refresh_coroutine) == "thread"
		and coroutine.status(global_cache[key].refresh_coroutine) ~= "dead"
	)
end

---@return table<string, GlobalCacheEntry>
M.get_cache = function()
	return global_cache
end

---@param connection_options MssqlConnectionOptions
---@param scope string?
M.cancel_refresh = function(connection_options, scope)
	if not scope then scope = "database" end
	local key = get_cache_key(connection_options, scope)

	if global_cache[key] and global_cache[key].cancellation_token then
		local token = global_cache[key].cancellation_token
		token.cancel = true

		-- force the running coroutine to wake up and cancel immediately
		if token and token.cleanup_callback then
			token.cleanup_callback()
		end
	end
end

---TESTING ONLY: Cancels background jobs and wipes state.
M.reset_all_state = function()
	for _, entry in pairs(global_cache) do
		if entry.cancellation_token then
			entry.cancellation_token.cancel = true
		end
	end

	global_cache = {}

	active_sessions = {}
end

return M
