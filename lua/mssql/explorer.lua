local utils = require("mssql.utils")
local state = require("mssql.state")

local M = {}

-- one cache per server and db (ie per connect opts)
---@type table<ConnectionKey, GlobalCacheEntry>
local global_cache = {}

-- SESSION ROUTER
-- Tracks active callbacks by Session ID so multiple sessions don't clobber each other's handlers
---@type table<string, function>
local active_sessions = {}

-- internal mapping groups all variations of node.objectType and node.label
local category_mappings = {
	tables = { "Tables", "Table" },
	views = { "Views", "View" },
	stored_procedures = { "StoredProcedures", "StoredProcedure", "Stored Procedures" },
	functions = {
		"Functions", "Function",
		"TableValuedFunctions", "TableValuedFunction", "Table-valued Functions",
		"ScalarValuedFunctions", "ScalarValuedFunction", "Scalar-valued Functions",
		"AggregateFunctions", "AggregateFunction", "Aggregate Functions"
	},
}

local type_to_category = {
	Programmability = "programmability",
}

for category, types in pairs(category_mappings) do
	for _, type_name in ipairs(types) do
		type_to_category[type_name] = category
	end
end

---@param err lsp.ResponseError?
---@param result { sessionId: string }?
---@param ctx table
local function main_expand_handler(err, result, ctx)
	if not result or utils.is_empty(result) or utils.is_empty(result.sessionId) then return end

	local session_callback = active_sessions[result.sessionId]
	if session_callback then
		session_callback(err, result, ctx)
	end
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
	connection_options.databaseDisplayName = connection_options.databaseDisplayName or connection_options.database

	local co = coroutine.running()
	local resumed = false
	local timeout_timer

	if cancellation_token and cancellation_token.cancel then
		return nil, "Cancelled"
	end

	-- setup event listener
	local bufnr = 0
	state.register_waiting_coroutine(bufnr, "objectexplorer/sessioncreated", co, client.id)


	-- attach cancellation handler for duration of this call
	if cancellation_token then
		cancellation_token.cleanup_callback = function()
			if not resumed then
				resumed = true
				state.clear_waiting_coroutine(bufnr, "objectexplorer/sessioncreated")
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
				state.clear_waiting_coroutine(bufnr, "objectexplorer/sessioncreated")
				if timeout_timer then timeout_timer:close() end
				utils.try_resume(co, nil, err)
			end
			return
		end

		-- guard against cancelled while createsession request in-flight
		if not utils.is_empty(result) and not utils.is_empty(result.sessionId) then
			if cancellation_token and cancellation_token.cancel then
				pcall(function()
					---@diagnostic disable-next-line:param-type-mismatch
					client:request("objectexplorer/closeSession", { sessionId = result.sessionId })
				end)
				return
			end
		end

		if not utils.is_empty(result) and not utils.is_empty(result.rootNode) then
			if not resumed then
				resumed = true
				state.clear_waiting_coroutine(bufnr, "objectexplorer/sessioncreated")
				if timeout_timer then timeout_timer:close() end
				utils.try_resume(co, result, nil)
			end
		end
	end)

	timeout_timer = vim.defer_fn(function()
		if not resumed then
			resumed = true
			state.clear_waiting_coroutine(bufnr, "objectexplorer/sessioncreated")
			utils.try_resume(co, nil, "Timeout waiting for session created")
		end
	end, timeout_ms)

	local result, err = coroutine.yield()

	if err then return nil, err end
	if not result or result.success == false or utils.is_empty(result.rootNode) then
		local msg = "Session creation failed"
		if result then
			if not utils.is_empty(result.errorMessage) then
				msg = msg .. ": " .. result.errorMessage
			end
			if result.errorCode == "CREATE_SESSION_TIMEOUT" then
				msg = msg .. " (Server Connection Timed Out)"
			end
		end
		if not _G.dummy_buf_id then
			utils.log_error(msg)
		end
		return nil, msg
	end

	if result.rootNode.objectType == "Server" then
		result.target_path = result.rootNode.nodePath
	end

	return result
end

---@param lsp_client vim.lsp.Client
---@param connection_options MssqlConnectionOptions
---@param cancellation_token { cancel: boolean, cleanup_callback: function }
---@param opts? FindObjectOpts
---@return MssqlNode[] | boolean? result Returns false or nil on failure/timeout
---@return string? msg
local get_object_cache_async = function(lsp_client, connection_options, cancellation_token, opts)
	opts = opts or {}
	local scope = utils.normalize_findobject_scope(opts.scope)
	local timeout_ms = opts.timeout_ms or 10000

	local config = state.get_config() or {}
	local user_categories = config.explorer_categories or { "stored_procedures" }

	local active_categories = {
		programmability = true, --always expand structural parent folders
	}
	for _, category in ipairs(user_categories) do
		active_categories[category] = true
	end

	local db_allow_list = connection_options and connection_options.databaseAllowList
	local db_deny_list = connection_options and connection_options.databaseDenyList

    utils.wait_for_schedule_async()
    if type(timeout_ms) ~= "number" or timeout_ms <= 0 then
        timeout_ms = 10000
    end
	local start_time = vim.uv.hrtime()

	-- prepare session options
	-- if scope is 'server', we MUST NOT bind the Object Explorer session to the specific database
	-- we need to connect to the server Root (default/master) to see the "Databases" folder
	-- and navigate to siblings
	local session_opts = vim.deepcopy(connection_options)
	if scope == "server" then
		session_opts.database = nil
		session_opts.databaseDisplayName = nil
	end
    local session, err = get_session_async(lsp_client, session_opts, timeout_ms, cancellation_token)

    if not session or utils.is_empty(session) or utils.is_empty(session.sessionId) or utils.is_empty(session.rootNode) then
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
	local retried_paths = {}
	local cleanup_done = false

	-- setup traversal paths
	-- Note: session.target_path might be nil if we connected to Root (server scope)
    local target_database_name = connection_options.database

	-- if session root is already the database (DB scope), mark it found immediately
	-- if we are in Server scope (Root), this will be false, and we will find DBs via expansion
    local found_db_node = (session.rootNode.objectType == "Database")
	local expand

	local clean_up_and_return = function(return_value, cleanup_err)
		-- guarantee idempotency during tree traversal, prevents double-teardown and dead coroutine resumes
		if cleanup_done then return end
		cleanup_done = true

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
		if expand_result and not utils.is_empty(expand_result.errorMessage) then
			local msg = expand_result.errorMessage
			local is_timeout = expand_result.errorCode == "EXPAND_TIMEOUT"
			if is_timeout then
				msg = msg .. " (Server Expansion Timed Out)"
			end

			-- Retry logic for server-side expansion timeouts (one attempt per node path)
			if is_timeout and expand_result.nodePath and not retried_paths[expand_result.nodePath] then
				retried_paths[expand_result.nodePath] = true
				utils.log_info("Timeout expanding " .. tostring(expand_result.nodePath) .. " . Retrying...")
				expand(expand_result.nodePath)
				expand_count = expand_count - 1 -- cancel out double-increment from expand() call
				return
			end

			utils.log_warn("Object Explorer expansion failure: " .. tostring(msg))
			clean_up_and_return(nil, msg)
			return
		end

		local nodes = (not utils.is_empty(expand_result.nodes) and expand_result.nodes) or {}

		for _, node in ipairs(nodes) do
			-- capture: add valid objects (Tables, Views, SProcs) to cache
			local type_key = M.OBJECT_TYPE_MAP[node.objectType]

			if type_key then
				-- filter our system schemas present in every db
				local schema = ""
				if not utils.is_empty(node.metadata) then
					schema = node.metadata.schema or ""
				end
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
				local is_nav_folder = (node.label == "Databases" or node.label == "System Databases")

				if is_nav_folder then
					-- always traverse structure folders
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
					local category = type_to_category[node.objectType] or type_to_category[node.label]
					if category and active_categories[category] then
						should_expand = true
					end
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

--- Checks if a cached connection is currently in use by any active buffer.
---@param cache_opts MssqlConnectionOptions The connection options stored in the cache.
---@param in_use_connections MssqlConnectionOptions[] List of connection options currently active.
---@param scope? FindObjectScope The scope of the cache entry.
---@return boolean in_use True if the cached connection matches any active connection.
local is_connection_in_use = function(cache_opts, in_use_connections, scope)
	for _, conn in ipairs(in_use_connections) do
		local server_match = conn.server == cache_opts.server
			and conn.user == cache_opts.user
			and conn.authenticationType == cache_opts.authenticationType

		if server_match then
			if scope == "server" then
				return true
			elseif scope == "database" and conn.database == cache_opts.database then
				return true
			end
		end
	end
	return false
end

-- lookup table mapping ObjectType strings to Config Key strings
---@type table<string, string>
M.OBJECT_TYPE_MAP = {
	AggregateFunctionPartitionFunction = "f",
	ScalarValuedFunction = "f",
	StoredProcedure = "sp",
	TableValuedFunction = "f",
	Table = "t",
	View = "v",
}

-- Initialises the cache, unless it already exists
-- If force is true, then gets a new cache and overwrites
---@param lsp_client vim.lsp.Client
---@param conn_opts MssqlConnectionOptions
---@param opts? FindObjectOpts
---@return boolean success
M.initialise_explorer_cache_async = function(lsp_client, conn_opts, opts)
	opts = opts or {}
	local scope = utils.normalize_findobject_scope(opts.scope)
	local force = opts.force or false

	local config = state.get_config()

	if opts.is_background and config and config.auto_init_explorer == false then
		return true
	end

	local timeouts = config and config.object_explorer_timeouts
	local timeout_sec = (timeouts and timeouts[scope]) or ((scope == "server") and 180 or 90)
	local timeout_ms = timeout_sec * 1000

	local key = M.create_cache_key(conn_opts, scope) --[[@as ConnectionKey]]
	if not global_cache[key] then
		global_cache[key] = {
			connection_options = vim.deepcopy(conn_opts),
			scope = scope,
		}
	end

	global_cache[key].is_initializing = true

	-- don't refresh if we are already refreshing or have refreshed previously
	if (global_cache[key].cache or M.is_refreshing(key)) and not force then
		global_cache[key].is_initializing = nil
		return true
	end

	-- cancel any currently running
	M.cancel_refresh(conn_opts, scope)

	local cancellation_token = { cancel = false }
	global_cache[key].cancellation_token = cancellation_token

	global_cache[key].refresh_coroutine = coroutine.running()
	vim.cmd("redrawstatus")
	local new_cache, err = get_object_cache_async(
		lsp_client,
		conn_opts,
		cancellation_token,
		{ scope = scope, timeout_ms = timeout_ms } --[[@as FindObjectOpts]]
	)
	if global_cache[key] then
		global_cache[key].is_initializing = nil
	end

	if err then
		if global_cache[key] then
			global_cache[key].cancellation_token = nil
			global_cache[key].refresh_coroutine = nil
		end
		if not tostring(err):match("Cancelled") then
			utils.log_warn("Cache initialization failed: " .. tostring(err))
		end
		return false
	end

	if not cancellation_token.cancel and type(new_cache) == "table" then
		global_cache[key].cache = new_cache
	end

	if global_cache[key] then
		global_cache[key].cancellation_token = nil
		global_cache[key].refresh_coroutine = nil
	end
	return true
end

M.handle_expand_completed = function(err, result, ctx)
	main_expand_handler(err, result, ctx)
end

--- Generates a deterministic lookup key for connection options.
--- This prevents key collisions between server and database scopes.
---@param opts MssqlConnectionOptions
---@param scope? FindObjectScope
---@return ConnectionKey
M.create_cache_key = function(opts, scope)
	local server = opts.server or "localhost"
	local user = opts.user or ""
	local auth = opts.authenticationType or "SqlLogin"
	scope = utils.normalize_findobject_scope(scope)

	-- append scope to global-cache-key to prevent collisions
	-- e.g. connecting and not specifying a database, which defaults to master,
	-- would lead to server-scope cache overwriting database-scoped cache
	-- as each would have same key (server|master|user|auth)
	if scope == "server" then
		return string.format("%s|%s|%s|server", server, user, auth)
	else
		local db = opts.database or "master"
		return string.format("%s|%s|%s|%s|database", server, db, user, auth)
	end
end

---@param in_use_connections MssqlConnectionOptions[]
M.delete_unused_cache = function(in_use_connections)

	for cache_key, entry in pairs(global_cache) do
		local in_use = false
		if entry.connection_options and entry.scope then
			in_use = is_connection_in_use(entry.connection_options, in_use_connections, entry.scope)
		end
		if not in_use and not entry.is_initializing then
			if entry.cancellation_token then
				entry.cancellation_token.cancel = true
			end
			global_cache[cache_key] = nil
		end
	end
end

---@param connection_options MssqlConnectionOptions|ConnectionKey
---@param scope? FindObjectScope
---@return boolean?
M.is_refreshing = function(connection_options, scope)
	local key = connection_options
	if type(key) == "table" then
		scope = utils.normalize_findobject_scope(scope)
		key = M.create_cache_key(connection_options --[[@as MssqlConnectionOptions]], scope)
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
---@param scope FindObjectScope
M.cancel_refresh = function(connection_options, scope)
	scope = utils.normalize_findobject_scope(scope)
	local key = M.create_cache_key(connection_options, scope)

	if global_cache[key] and global_cache[key].cancellation_token then
		local token = global_cache[key].cancellation_token
		token.cancel = true

		-- force the running coroutine to wake up and cancel immediately
		if token and token.cleanup_callback then
			token.cleanup_callback()
		end
	end
end

---TESTING ONLY: Cancels background jobs, closes sessions, and wipes explorer cache.
M.reset_explorer_state = function()
	for _, entry in pairs(global_cache) do
		if entry.cancellation_token then
			entry.cancellation_token.cancel = true
		end
	end

	local success, client = pcall(utils.get_lsp_client)
	if success and client then
		for session_id, _ in pairs(active_sessions) do
			pcall(function() client:request("objectexplorer/closeSession", { sessionId = session_id }) end)
		end
	end

	global_cache = {}

	active_sessions = {}
end

return M
