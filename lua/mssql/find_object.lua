local utils = require("mssql.utils")
local state = require("mssql.state")

local M = {}

---@class MssqlNode
---@field nodePath string
---@field label string
---@field nodeType string
---@field objectType string
---@field parentNodePath string
---@field isLeaf boolean
---@field metadata? table
---@field picker_path? string
---@field text? string

---@class MssqlSession
---@field sessionId string
---@field success boolean
---@field errorMessage? string
---@field rootNode MssqlNode
---@field target_path? string

---@class GlobalCacheEntry
---@field cache? MssqlNode[]
---@field cancellation_token? { cancel: boolean }
---@field refresh_coroutine? thread

---@alias ConnectionKey string

---@param client vim.lsp.Client
---@param connection_options MssqlConnectionOptions
---@param timeout_ms? integer Optional timeout in milliseconds (default: 10000)
---@return MssqlSession? | boolean?
---@return string? msg
local get_session_async = function(client, connection_options, timeout_ms)
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

	-- setup event listener
	local dispose = state.on_event("objectexplorer/sessioncreated", function(err, result, ctx)
		if ctx and ctx.client_id == client.id then
			if not resumed and result and result.rootNode then
				resumed = true
				utils.try_resume(co, result, err)
			end
		end
	end)

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

---@class NodeTypeDef
---@field scriptCreateDrop string "ScriptCreate" | "ScriptSelect"
---@field operation integer

---@type table<string, NodeTypeDef>
local nodeTypes = {
	AggregateFunctionPartitionFunction = {
		scriptCreateDrop = "ScriptCreate",
		operation = 6,
	},
	ScalarValuedFunction = {
		scriptCreateDrop = "ScriptCreate",
		operation = 6,
	},
	StoredProcedure = {
		scriptCreateDrop = "ScriptCreate",
		operation = 6,
	},
	TableValuedFunction = {
		scriptCreateDrop = "ScriptCreate",
		operation = 6,
	},
	Table = {
		scriptCreateDrop = "ScriptSelect",
		operation = 0,
	},
	View = {
		scriptCreateDrop = "ScriptSelect",
		operation = 0,
	},
}

-- SESSION ROUTER
-- Tracks active callbacks by Session ID so multiple sessions don't clobber each other's handlers
---@type table<string, function>
local active_sessions = {}

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

state.on_event("objectexplorer/expandCompleted", main_expand_handler)

---@param lsp_client vim.lsp.Client
---@param connection_options MssqlConnectionOptions
---@param cancellation_token { cancel: boolean }
---@param timeout_ms? integer Optional timeout in milliseconds (default: 10000)
---@return MssqlNode[] | boolean? result Returns false or nil on failure/timeout
---@return string? msg
local get_object_cache_async = function(lsp_client, connection_options, cancellation_token, timeout_ms)
    utils.wait_for_schedule_async()
    if type(timeout_ms) ~= "number" or timeout_ms <= 0 then
        timeout_ms = 10000
    end
	local start_time = vim.uv.hrtime()
    local session, err = get_session_async(lsp_client, connection_options, timeout_ms)

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
    local root_path = session.rootNode.nodePath
    local cache = {}
    local expand_count = 0
    local co = coroutine.running()
	local timeout_timer

    -- (Server Root -> Database) traversal
    local db_node_path = session.target_path or root_path
    local target_database_name = connection_options.database
    local found_db_node = false
	local expand

    local clean_up_and_return = function(return_value, cleanup_err)
		if timeout_timer then
			local timer_to_close = timeout_timer
			timeout_timer = nil
			if not timer_to_close:is_closing() then
				timer_to_close:close()
			end
		end

        if session_id then
				active_sessions[session_id] = nil
        end

        ---@diagnostic disable-next-line: param-type-mismatch
        lsp_client:request("objectexplorer/closeSession", {
            sessionId = session_id,
        }, function(close_err, result, _, _)
            session_id = nil
            return result, close_err
        end)

        if coroutine.status(co) == "suspended" then
            if cleanup_err then
                local ok, resume_err = coroutine.resume(co, nil, cleanup_err)
                if not ok then
                    utils.log_error("Failed to resume coroutine: " .. tostring(resume_err))
                end
            else
                coroutine.resume(co, return_value)
            end
        end
    end

    local on_expand_result = function(_, expand_result, _)
		-- ignore boolean acks or empty results
		if type(expand_result) ~= "table" or not expand_result.nodes then
			return
		end

        for _, node in ipairs(expand_result.nodes) do
            if nodeTypes[node.objectType] then
                local path = node.parentNodePath

                if not vim.startswith(path, db_node_path) then
                    goto continue
                end

                local root_path_length = #db_node_path
                node.picker_path = string.sub(path, root_path_length + 2, #path) .. "/"
                node.text = node.picker_path .. node.label
                table.insert(cache, node)

            elseif not node.nodePath then
                utils.log_info("no node path")
            elseif session.target_path and not found_db_node then
                if target_database_name and node.label:lower() == target_database_name:lower() and node.objectType == "Database" then
                    found_db_node = true
                    db_node_path = node.nodePath
                    expand(db_node_path)

                elseif (node.label:lower() == "databases" or node.label:lower() == "system databases") then
                    expand(node.nodePath)
                end

            elseif found_db_node or not session.target_path then
                local current_base = found_db_node and db_node_path or root_path
                if vim.startswith(node.nodePath, current_base) then
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
            }, function(expand_err, result)
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

                if result then
					on_expand_result(nil, result, { client_id = lsp_client.id })
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

    state.on_event("objectexplorer/expandcompleted", main_expand_handler)

    timeout_timer = vim.defer_fn(function()
        if coroutine.status(co) == "suspended" then
            clean_up_and_return(nil, "Operation timed out waiting for object explorer expansion")
        end
    end, math.floor(remaining_ms))

    expand(session.rootNode.nodePath)
    local result, cr_err = coroutine.yield()
    if cr_err then
        return nil, cr_err
    end

    return result
end

---@param item MssqlNode
---@param client vim.lsp.Client
---@return { script: string, select: boolean }
local generate_script_async = function(item, client)
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
			scriptCreateDrop = nodeTypes[item.objectType].scriptCreateDrop,
			typeOfDataToScript = "SchemaOnly",
			scriptStatistics = "ScriptStatsNone",
		},
		ownerURI = utils.lsp_file_uri(0),
		operation = nodeTypes[item.objectType].operation,
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
		select = scripting_params.operation == 0,
	}
end

-- one cache per server and db (ie per connect opts)
---@type table<ConnectionKey, GlobalCacheEntry>
local global_cache = {}

-- Picker
local picker_icons = {
	AggregateFunctionPartitionFunction = "󰡱",
	ScalarValuedFunction = "󰡱",
	StoredProcedure = "󰯁",
	TableValuedFunction = "󰡱",
	Table = "",
	View = "󱂬",
}

---@param cache MssqlNode[]
---@param title string
---@return MssqlNode?
local pick_item_async = function(cache, title)
	local co = coroutine.running()

	local success, snacks = pcall(require, "snacks")
	if not success then
		return utils.ui_select_async(cache, {
			prompt = title,
			format_item = function(item)
				return table.concat({
					picker_icons[item.nodeType],
					" ",
					item.picker_path,
					item.label,
				})
			end,
		})
	end

	snacks.picker.pick({
		title = title,
		layout = "select",
		items = cache,
		format = function(item)
			return {
				{ picker_icons[item.nodeType], "SnacksPickerIcon" },
				{ " " },
				{ item.label },
				{ " " },
				{ item.picker_path, "SnacksPickerComment" },
			}
		end,
		confirm = function(picker, item)
			picker:close()
			coroutine.resume(co, item)
		end,
		cancel = function(picker)
			picker:close()
			coroutine.resume(co, nil)
		end,
	})
	return coroutine.yield()
end

-- Initialises the cache, unless it already exists
-- If force is true, then gets a new cache and overwrites
---@param lsp_client vim.lsp.Client
---@param connection_options MssqlConnectionOptions
---@param force? boolean
---@param timeout_ms? integer Optional timeout in milliseconds (default: 10000)
---@return boolean success
M.initialise_cache_async = function(lsp_client, connection_options, force, timeout_ms)
	if type(timeout_ms) ~= "number" or timeout_ms <= 0 then
		timeout_ms = 10000
	end

	if type(force) ~= "boolean" or not force then
		force = false
	end

	local key = vim.json.encode(connection_options) --[[@as ConnectionKey]]
	if not global_cache[key] then
		global_cache[key] = {}
	end

	-- don't refresh if we are already refreshing or have refreshed previously
	if (global_cache[key].cache or M.is_refreshing(key)) and not force then
		return false
	end

	-- cancel any currently running
	if global_cache[key].cancellation_token then
		global_cache[key].cancellation_token.cancel = true
	end
	local cancellation_token = { cancel = false }
	global_cache[key].cancellation_token = cancellation_token

	global_cache[key].refresh_coroutine = coroutine.running()
	vim.cmd("redrawstatus")
	local new_cache, err = get_object_cache_async(lsp_client, connection_options, cancellation_token, timeout_ms)
	if err then
		utils.log_warn("Cache initialization failed: " .. tostring(err))
		return false
	end

	if not cancellation_token.cancel and type(new_cache) == "table" then
		global_cache[key].cache = new_cache
	end
	return true
end

---@param connection_options MssqlConnectionOptions
---@param lsp_client vim.lsp.Client
---@return { script: string, select: boolean }?
M.find_async = function(connection_options, lsp_client)
	local title = "Find"
	if connection_options and connection_options.database and connection_options.server then
		title = connection_options.server .. " | " .. connection_options.database
	end
	local key = vim.json.encode(connection_options)
	---@type MssqlNode[]
	local cache = {}
	if global_cache[key] and global_cache[key].cache then
		cache = global_cache[key].cache --[[@as MssqlNode[] ]]
	end

	local item = pick_item_async(cache, title)
	if not item then
		return
	end
	return generate_script_async(item, lsp_client)
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

---TESTING ONLY: Cancels background jobs and wipes state.
M.reset_all_state = function()
	for _, entry in ipairs(global_cache) do
		if entry.cancellation_token then
			entry.cancellation_token.cancel = true
		end
	end

	global_cache = {}

	active_sessions = {}
end

return M
