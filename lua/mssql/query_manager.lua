local utils = require("mssql.utils")
local finder = require("mssql.find_object")
require("mssql.default_opts")

---@alias MssqlQueryManagerState
---| "disconnected"
---| "connecting"
---| "connected"
---| "executing"
---| "cancelling"

---@class MssqlExecutionInfo
---@field rows_affected? number
---@field elapsed_time? number

---@class MssqlConnectionOptions
---@field server? string
---@field database? string
---@field databaseAllowList? string[]
---@field databaseDenyList? string[]
---@field user? string
---@field password? string
---@field authentication? string
---@field trustServerCertificate? boolean
---@field [string] any Allow extra fields passed by config

---@class MssqlConnectionSummary
---@field databaseName string
---@field serverName? string
---@field userName? string
---@field connectionId? string

---@class MssqlConnectionWrapper
---@field options MssqlConnectionOptions
---@field summary? MssqlConnectionSummary

---@class MssqlConnectParams
---@field ownerUri? string The URI of the buffer owning this connection.
---@field connection MssqlConnectionWrapper

---@class MssqlQueryCompleteResult
---@field ownerUri string
---@field batchSummaries MssqlBatchSummary[]

---@class MssqlBatchSummary
---@field executionElapsed? string
---@field resultSetSummaries? MssqlResultSetSummary[]
---@field rowCount? integer

---@class MssqlResultSetSummary
---@field rowCount integer
---@field columnInfo? table

---@class MssqlQueryMessageResult
---@field ownerUri string
---@field message MssqlQueryMessage

---@class MssqlQueryMessage
---@field message string
---@field isError? boolean
---@field batchId? integer

---@class MssqlConnectionChangedResult
---@field ownerUri string
---@field connection MssqlConnectionSummary

---@class MssqlQueryManager
---@field bufnr integer
---@field client vim.lsp.Client
---@field state MssqlQueryManagerState
---@field states MssqlQueryManagerStates
---@field last_connect_params MssqlConnectParams
---@field owner_uri string
---@field execution_timer MssqlTimer
---@field last_execution_info MssqlExecutionInfo
---@field start_time number
---@field query_timeout number?
local MssqlQueryManager = {}
MssqlQueryManager.__index = MssqlQueryManager

---@class MssqlQueryManagerStates
---@field disconnected MssqlQueryManagerState
---@field connecting MssqlQueryManagerState
---@field connected MssqlQueryManagerState
---@field executing MssqlQueryManagerState
---@field cancelling MssqlQueryManagerState

MssqlQueryManager.states = {
	disconnected = "disconnected",
	connecting = "connecting",
	connected = "connected",
	executing = "executing",
	cancelling = "cancelling",
}

--- State transition definition type
---@alias StateTransitionTable table<MssqlQueryManagerState, MssqlQueryManagerState[]>

---@type StateTransitionTable
local STATE_TRANSITIONS = {
	disconnected = { "connecting" },
	connecting = { "connected", "disconnected" },
	connected = { "connecting", "executing", "disconnected" },
	executing = { "connected", "cancelling" },
	cancelling = { "connected" },
}

--- Constructor
---@param bufnr integer
---@param client vim.lsp.Client
---@param opts MssqlConfig
---@return MssqlQueryManager
function MssqlQueryManager.new(bufnr, client, opts)
	local self = setmetatable({}, MssqlQueryManager)

	self.bufnr = bufnr
	self.client = client
	self.state = MssqlQueryManager.states.disconnected
	self.last_connect_params = nil
	self.execution_timer = utils.Timer.new()
	self.last_execution_info = { rows_affected = nil, elapsed_time = nil }
	self.start_time = 0
	self.query_timeout = opts.query_timeout

	local attached = vim.api.nvim_buf_attach(bufnr, false, {
		on_detach = function()
			self:cleanup()
		end
	})

	if not attached then
		utils.log_warn("Failed to attach buffer detachment handler")
	end

	return self
end

--- Validates state transition
---@param self MssqlQueryManager
---@param new_state MssqlQueryManagerState
---@param action string
---@return boolean can_transition
---@return string? error_message
local function validate_state_transition(self, new_state, action)
	-- allow "no-op" transititions, if we are already in target state it's valid
	if self.state == new_state then
		return true
	end

	local valid_transitions = STATE_TRANSITIONS[self.state]
	if not valid_transitions then
		return false, ("Invalid current state %s"):format(self.state)
	end

	if not vim.tbl_contains(valid_transitions, new_state) then
		return false, ("Cannot %s from state '%s' to '%s'"):format(
			action, self.state, new_state
		)
	end

	return true
end

--- Converts passed timeout in seconds to milliseconds.
---@param timeout_seconds? number Timeout in seconds.
---@return integer? timeout_ms Returns nil for no timeout
local function calculate_timeout_ms(timeout_seconds)
	if timeout_seconds == nil then return nil end
	if type(timeout_seconds) ~= "number" then
		error("timeout_seconds must be a number")
	end
	if timeout_seconds <= 0 then return nil end
	return math.floor(timeout_seconds * 1000)
end

--- Safely extracts time components from SQL Server elapsed time string
---@param elapsed_str? string Format: "HH:MM:SS.sss"
---@return number? seconds Total seconds
local function parse_sql_elapsed_time(elapsed_str)
	if not elapsed_str or type(elapsed_str) ~= "string" then
		return nil
	end

	local hours, minutes, seconds = elapsed_str:match("(%d+):(%d+):([%d.]+)")
	if not hours or minutes or seconds then
		return nil
	end

	return (tonumber(hours) or 0) * 3600
		+ (tonumber(minutes) or 0) * 60
		+ (tonumber(seconds) or 0)
end

---@param result any
---@return boolean is_MssqlQueryCompleteResult
local function is_valid_query_complete_result(result)
	return type(result) == "table"
		and type(result.batchSummaries) == "table"
		and #result.batchSummaries > 0
		and type(result.ownerUri) == "string"
end

---@param result any
---@return  boolean is_MssqlConnectionChangedResult
local function is_valid_connection_changed_result(result)
	return type(result) == "table"
		and type(result.ownerUri) == "string"
		and type(result.connection) == "table"
end

--- Dynamically calculate the URI every time
---@return string
function MssqlQueryManager:get_owner_uri()
	return utils.lsp_file_uri(self.bufnr) or ""
end

---@return string? database_name Returns nil if not connected
function MssqlQueryManager:get_database_name()
	local params = self:get_connect_params()

	if params and params.connection and params.connection.options then
		return params.connection.options.database
	end

	return nil
end

--- Sets the internal state, with validation, and redraws the statusline.
---@param new_state MssqlQueryManagerState
---@return boolean success
function MssqlQueryManager:set_state(new_state)
	local can, err = validate_state_transition(self, new_state, "change state")
	if not can then
		utils.log_warn(err)
		return false
	end

	self.state = new_state
	vim.schedule(function()
		if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
			vim.cmd("redrawstatus")
		end
	end)
	return true
end

---@return MssqlQueryManagerState
function MssqlQueryManager:get_state()
	return self.state
end

--- Stops and cleans up the execution timer.
function MssqlQueryManager:cleanup_timer()
	self.execution_timer:close()
end

--- Stops timer and calculates final time.
function MssqlQueryManager:stop_execution_timer()
	if self.start_time > 0 then
		self.last_execution_info.elapsed_time = (vim.loop.now() - self.start_time) / 1000
	end

	self.execution_timer:stop()

	self.start_time = 0
	vim.schedule(function()
		if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
			vim.cmd("redrawstatus")
		end
	end)

end

--- Starts the timer loop for execution tracking.
---@return boolean success
function MssqlQueryManager:start_execution_timer()
	self:stop_execution_timer()

	self.last_execution_info = {
		rows_affected = nil,
		elapsed_time = 0
	}
	self.start_time = vim.loop.now()
	local bufnr = self.bufnr

	self.execution_timer:start(1000, function()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			self:cleanup_timer()
			return
		end

		if self.state == MssqlQueryManager.states.executing then
			self.last_execution_info.elapsed_time = (vim.loop.now() - self.start_time) / 1000
			vim.cmd("redrawstatus")
		else
			self:stop_execution_timer()
		end
	end)

	return true
end

--- Initiates an async connection request.
---@param connect_params MssqlConnectParams
---@return boolean success
---@return string? error_message
function MssqlQueryManager:connect_async(connect_params)
	if not self:is_valid() then return false, "Object is invalid" end
	if not self:set_state(MssqlQueryManager.states.connecting) then
		return false, "Cannot transition to connecting state"
	end

	connect_params.ownerUri = self:get_owner_uri()

	local _, err = utils.lsp_request_async(self.client, "connection/connect", connect_params)
	if err then
		self:set_state(MssqlQueryManager.states.disconnected)
		return false, ("Could not connect: %s"):format(err.message)
	end

	local timeout_ms = 10000
	local result, wait_err = utils.wait_for_notification_async(
		self.bufnr, self.client, "connection/complete", timeout_ms
	)

	if wait_err or (result and result.errorMessage and result.errorMessage ~= vim.NIL) then
		self:set_state(MssqlQueryManager.states.disconnected)
		return false, "Error in connecting: " .. (wait_err and wait_err.message or result.errorMessage)
	end

	if result and result.connectionSummary then
		if not connect_params.connection then
			connect_params.connection = { options = {} }
		end
		connect_params.connection.summary = result.connectionSummary
		connect_params.connection.options.database = result.connectionSummary.databaseName
		connect_params.connection.options.DatabaseDisplayName = result.connectionSummary.databaseName
	end

	self.last_connect_params = connect_params
	return self:set_state(MssqlQueryManager.states.connected)
end

--- Disconnects the current session.
---@return boolean success
function MssqlQueryManager:disconnect_async()
	if not self:is_valid() then return false end
	if not self:set_state(MssqlQueryManager.states.disconnected) then
		return false
	end
	utils.lsp_request_async(self.client, "connection/disconnect", { ownerUri = self:get_owner_uri() })
	self.last_connect_params = nil
	self.last_execution_info = { rows_affected = nil, elapsed_time = nil }
	return true
end

--- Executes an SQL query string.
---@param query string
---@return table? result The query result object.
---@return string? error_message
function MssqlQueryManager:execute_async(query)
	if not self:is_valid() then return nil, "Object is invalid." end
	if not self:set_state(MssqlQueryManager.states.executing) then
		return nil, "Cannot transition to executing state"
	end
	if not self:start_execution_timer() then
		self:set_state(MssqlQueryManager.states.connected)
		return nil, "Failed to start execution timer"
	end

	local result, err = utils.lsp_request_async(self.client, "query/executeString", {
		query = query,
		ownerUri = self:get_owner_uri()
	})

	if err or not result then
		self:stop_execution_timer()
		self:set_state(MssqlQueryManager.states.connected)
		return nil, err and ("Error executing query: " .. (err.message or vim.inspect(err))) or "Could not execute query"
	end

	return self:wait_for_query_completion()
end

--- Internal helper to wait for completion notification.
---@return table? result
---@return string? error_message
function MssqlQueryManager:wait_for_query_completion()
	local timeout_ms = calculate_timeout_ms(self.query_timeout)
	local result, err = utils.wait_for_notification_async(
		self.bufnr, self.client, "query/complete", timeout_ms
	)

	self:stop_execution_timer()
	vim.cmd("redrawstatus")
	if self.state == MssqlQueryManager.states.cancelling then
		self:set_state(MssqlQueryManager.states.connected)
		utils.log_info("Query was cancelled.")
		return nil, "cancelled"
	end

	if err and err.code == -32001 then
		return nil, self:handle_timeout()
	end

	if err then
		self:set_state(MssqlQueryManager.states.connected)
		return nil, "Query failed: " .. (err.message or "unknown error")
	end

	self:set_state(MssqlQueryManager.states.connected)
	return result
end

--- Handles execution timeout by attempting to cancel.
---@param timeout_ms? integer
---@return string error_message
function MssqlQueryManager:handle_timeout(timeout_ms)
	timeout_ms = timeout_ms or 10000
	utils.log_error("Query execution timed out...")
	self:cancel_async()

	local _, err = utils.wait_for_notification_async(
		self.bufnr, self.client, "query/complete", timeout_ms
	)

	if err then
		utils.log_error("Did not receive cancel confirmation within timeout: " .. timeout_ms / 1000 .. "s")
	else
		utils.log_info("Cancellation confirmed.")
	end

	self:set_state(MssqlQueryManager.states.connected)
	return "Query execution connection timed out."
end

--- Cancels the currently running query.
---@return boolean success
function MssqlQueryManager:cancel_async()
	if not self:is_valid() then return false end
	if not self:set_state(MssqlQueryManager.states.cancelling) then
		return false
	end

	local _, err = utils.lsp_request_async(self.client, "query/cancel", { ownerUri = self:get_owner_uri() })
	if err then
		self:set_state(MssqlQueryManager.states.connected)
		return false
	end

	return true
end

--- Parses a query/message string to find the number of rows affected.
--- NOTE: Relies on the specific "(N rows affected)" format from the LSP.
---@param message string
---@return integer? row_count
function MssqlQueryManager:parse_rows_affected_message(message)
	if type(message) ~= "string" then
		return nil
	end

	local row_count = string.match(message, "%((%d+) rows? affected%)")
	if row_count then
		return tonumber(row_count)
	end

	return nil
end

--- Sets the final query elapsed time and row count from server results.
--- Prioritizes DML row counts if they exist, otherwise uses the SELECT row count.
---@param final_time? number The precise final execution time in seconds.
---@param select_row_count? number The row count returned by the SELECT statement.
function MssqlQueryManager:set_final_execution_stats(final_time, select_row_count)
	if final_time then
		self.last_execution_info.elapsed_time = final_time
	end

	if self.last_execution_info.rows_affected == nil and select_row_count then
		self.last_execution_info.rows_affected = select_row_count
	end
end

---@return MssqlConnectParams? params Returns nil if not connected
function MssqlQueryManager:get_connect_params()
	if not self.last_connect_params then
		return nil
	end
	return vim.tbl_deep_extend("keep", self.last_connect_params, {})
end

--- Safely retrieves the inner connection options (server, db, user)
---@return MssqlConnectionOptions? options Returns nil if not connected or configured
function MssqlQueryManager:get_connection_options()
	if self.last_connect_params and self.last_connect_params.connection then
		return self.last_connect_params.connection.options
	end
	return nil
end

---@return vim.lsp.Client
function MssqlQueryManager:get_lsp_client()
	return self.client
end

---@return MssqlExecutionInfo
function MssqlQueryManager:last_execution()
	return vim.deepcopy(self.last_execution_info)
end

--- Updates connection parameters based on notification result.
---@param result MssqlConnectionChangedResult
---@return boolean success True if parameters were updated.
function MssqlQueryManager:update_connection_params(result)
	if not is_valid_connection_changed_result(result) then
		return false
	end

	if result.ownerUri ~= self:get_owner_uri() then
		return false
	end


	if not self.last_connect_params then
		self.last_connect_params = {
			connection = { options = {} }
		}
	end

	if not self.last_connect_params.connection then
		self.last_connect_params.connection = { options = {} }
	end

	self.last_connect_params.connection.summary = result.connection
	self.last_connect_params.connection.options.user = result.connection.userName
	self.last_connect_params.connection.options.database = result.connection.databaseName
	self.last_connect_params.connection.options.server = result.connection.serverName

	return true
end

--- Handler for connectionchanged notification.
---@param result MssqlConnectionChangedResult
function MssqlQueryManager:connectionchanged_async(result)
	if self:update_connection_params(result) then
		self:initialise_cache_async()
	end
end

-- Passthroughs to Finder (passing client/params explicility)

--- Initialize cache for finder
---@param force boolean? Get a new cache and overwrite.
---@return boolean success
function MssqlQueryManager:initialise_cache_async(force)
	local options = self:get_connection_options()
	if not options then
		utils.log_warn("Cannot initialize cache: not connected")
		return false
	end

	return finder.initialise_cache_async(
		self.client,
		self.last_connect_params.connection.options,
		force
	)
end

---@return { script: string, select: boolean }?
function MssqlQueryManager:find_async()
	local options = self:get_connection_options()
	if not options then
		utils.log_warn("Cannot find objects: not connected")
		return
	end

	return finder.find_async(
		self.last_connect_params.connection.options,
		self.client
	)
end

---@return boolean? is_refreshing Returns nil if not connected
function MssqlQueryManager:is_refreshing()
	local options = self:get_connection_options()
	if not options then return nil end

	return finder.is_refreshing(options)
end

--- Handlers (called by LSP callbacks)

---@param result table
function MssqlQueryManager:handle_query_complete(result)
	if not is_valid_query_complete_result(result) then
		utils.log_warn("Invalid query complete result received")
		return
	end

	local batch_summary = result.batchSummaries[#result.batchSummaries]
	if not batch_summary then
	  return
	end

	local final_elapsed_time = parse_sql_elapsed_time(batch_summary.executionElapsed)

	-- Get total row count for SELECT statements only
	local total_row_count = 0
	if batch_summary.resultSetSummaries and #batch_summary.resultSetSummaries > 0 then
		local last_result_set = batch_summary.resultSetSummaries[#batch_summary.resultSetSummaries]
		total_row_count = last_result_set.rowCount or 0
	end

	self:set_final_execution_stats(final_elapsed_time, total_row_count)
end

---@param result MssqlQueryMessageResult
function MssqlQueryManager:handle_query_message(result)
	if not result or not result.message or type(result.message.message) ~= "string" then
		return
	end

	local row_count = self:parse_rows_affected_message(result.message.message)
	if row_count then
		self.last_execution_info.rows_affected = row_count
	end
end

--- Stop activity but preserve state needed for reloads (i.e. :edit)
function MssqlQueryManager:cleanup()
	self:cleanup_timer()

	self.state = MssqlQueryManager.states.disconnected
	self.last_execution_info = { rows_affected = nil, elapsed_time = nil }
	self.start_time = 0

	self.client = nil
end

--- Validates if the QueryManager instances is still usable
---@return boolean is_valid
function MssqlQueryManager:is_valid()
	return self.client ~= nil
		and self.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(self.bufnr)
		and self.client.id ~= nil
end

return MssqlQueryManager
