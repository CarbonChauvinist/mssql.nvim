local utils = require("mssql.utils")

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

---Same as utils.wait_for_notification_async but ignores any owner uri
---@param client vim.lsp.Client
---@param method string
---@param timeout integer
---@return any result
---@return lsp.ResponseError? error
local wait_for_notification_async = function(client, method, timeout)
	local this = coroutine.running()
	local resumed = false
	local handler
	handler = function(err, result, _)
		if not resumed then
			resumed = true
			utils.unregister_lsp_handler(client, method, handler)
			utils.try_resume(this, result, err)
		end
		return result, err
	end
	utils.register_lsp_handler(client, method, handler)
	vim.defer_fn(function()
		if not resumed then
			resumed = true
			utils.unregister_lsp_handler(client, method, handler)
			utils.try_resume(
				this,
				nil,
				vim.lsp.rpc_response_error(
					vim.lsp.protocol.ErrorCodes.UnknownErrorCode,
					"Waiting for the lsp to call " .. method .. "timed out"
				)
			)
		end
	end, timeout)
	return coroutine.yield()
end

---@param client vim.lsp.Client
---@param connection_options MssqlConnectionOptions
---@return MssqlSession
local get_session_async = function(client, connection_options)
	connection_options = vim.deepcopy(connection_options)
	connection_options.ServerName = connection_options.server
	connection_options.DatabaseName = connection_options.database
	connection_options.UserName = connection_options.user
	connection_options.EnclaveAttestationProtocol = connection_options.attestationProtocol

	-- For some reason, if there is no display name set on the connection parameters then
	-- the language server will treat this as a default/system database:
	-- https://github.com/microsoft/sqltoolsservice/blob/49036c6196e73c3791bca5d31e97a16afee00772/src/Microsoft.SqlTools.ServiceLayer/ObjectExplorer/ObjectExplorerService.cs#L537
	connection_options.DatabaseDisplayName = connection_options.DatabaseDisplayName or connection_options.database

	utils.lsp_request_async(client, "objectexplorer/createsession", connection_options)
	local response, err = wait_for_notification_async(client, "objectexplorer/sessioncreated", 10000)

	-- Detect if we are connected to a Server root (e.g. if we connect to a system database, etc.)
	if response and response.rootNode and response.rootNode.objectType == "Server" then
		response.target_path = response.rootNode.nodePath
	end
	utils.safe_assert(not err, vim.inspect(err))
	return response
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

---@param lsp_client vim.lsp.Client
---@param connection_options MssqlConnectionOptions
---@param cancellation_token { cancel: boolean }
---@return MssqlNode[] | boolean
local get_object_cache_async = function(lsp_client, connection_options, cancellation_token)
	utils.wait_for_schedule_async()
	local session = get_session_async(lsp_client, connection_options)
	utils.safe_assert(session and session.sessionId)

	---@type string?
	local session_id = session.sessionId
	local root_path = session.rootNode.nodePath
	local cache = {}
	local expand_count = 0
	local co = coroutine.running()

	-- State for Phase 1 (Server Root -> Database) traversal
	local db_node_path = session.target_path or root_path
	local target_database_name = connection_options.database
	local found_db_node = false

	local clean_up_and_return = function(return_value)
		-- remove this session from the router
		if session_id then
			active_sessions[session_id] = nil
		end
		-- if NO sessions remain unregister the main handler
		if next(active_sessions) == nil then
			utils.unregister_lsp_handler(lsp_client, "objectexplorer/expandCompleted", main_expand_handler)
		end

		-- disconnect (close session on server)
		---@diagnostic disable-next-line: param-type-mismatch
		lsp_client:request("objectExplorer/closeSession", {
			sessionId = session_id,
		}, function(err, result, _, _)
			session_id = nil
			return result, err
		end)

		if coroutine.status(co) == "suspended" then
			coroutine.resume(co, return_value)
		end
	end

	local expand = function(path)
		expand_count = expand_count + 1
		vim.schedule(function()
			-- check for cancellation every time we expand a node in the tree
			if cancellation_token.cancel then
				clean_up_and_return(false)
				return
			end
			---@diagnostic disable-next-line: param-type-mismatch
			lsp_client:request("objectexplorer/expand", {
				sessionId = session_id,
				nodePath = path,
			}, function(err, result, _, _)
				return result, err
			end)
		end)
	end

	local on_expand_result = function(_, expand_result, _)
		for _, node in ipairs(expand_result.nodes) do
			if nodeTypes[node.objectType] then
				local path = node.parentNodePath

				-- Strict scoping: Ignore objects if we haven't confirmed we are in the right DB
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
				-- Phase 1: Traversing Server Root to find Database
				if target_database_name and node.label:lower() == target_database_name:lower() and node.objectType == "Database" then
					found_db_node = true
					db_node_path = node.nodePath
					expand(db_node_path)

				elseif (node.label:lower() == "databases" or node.label:lower() == "system databases") then
					expand(node.nodePath)
				end

			elseif found_db_node or not session.target_path then
				-- Phase 2: Standard expansion inside the database
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

	-- Register with the Session Router
	if session_id then
		active_sessions[session_id] = on_expand_result
	end

	-- ensure the main handler is registered (safe to call multiple times)
	utils.register_lsp_handler(lsp_client, "objectexplorer/expandCompleted", main_expand_handler)
	expand(session.rootNode.nodePath)
	return coroutine.yield()
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
---@return boolean success
M.initialise_cache_async = function(lsp_client, connection_options, force)
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
	local new_cache = get_object_cache_async(lsp_client, connection_options, cancellation_token)
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

return M
