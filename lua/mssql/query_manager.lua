local utils = require("mssql.utils")
local finder = require("mssql.find_object")

---@alias MssqlQueryManagerState "connected"|"disconnected"|"executing a query"|"cancelling a query"|"connecting"

---@class MssqlExecutionInfo
---@field rows_affected? number
---@field elapsed_time? number

---@class MssqlQueryManager
---@field bufnr integer
---@field client vim.lsp.Client
---@field state MssqlQueryManagerState
---@field states table<string, MssqlQueryManagerState>
---@field last_connect_params table
---@field owner_uri string
---@field execution_timer uv.uv_timer_t?
---@field last_execution_info MssqlExecutionInfo
---@field start_time number
---@field query_timeout number?
local QueryManager = {}
QueryManager.__index = QueryManager

QueryManager.states = {
	Disconnected = "disconnected",
	Cancelling = "cancelling a query",
	Connecting = "connecting",
	Connected = "connected",
	Executing = "executing a query",
}

--- Constructor
---@param bufnr integer
---@param client vim.lsp.Client
---@param opts MssqlConfig
---@return MssqlQueryManager
function QueryManager.new(bufnr, client, opts)
	local self = setmetatable({}, QueryManager)

	self.bufnr = bufnr
	self.client = client
	self.state = QueryManager.states.Disconnected
	self.last_connect_params = {}
	self.owner_uri = utils.lsp_file_uri(bufnr) or ""
	self.execution_timer = nil
	self.last_execution_info = { rows_affected = nil, elapsed_time = nil }
	self.start_time = 0
	self.query_timeout = opts.query_timeout

	vim.api.nvim_buf_attach(bufnr, false, {
		on_detach = function()
			self:cleanup_timer()
		end
	})

	return self
end

--- Validates the current state before performing an action.
---@param self MssqlQueryManager
---@param expected_state MssqlQueryManagerState
---@param action string Name of the action being attempted.
local function validate_state(self, expected_state, action)
	if self.state ~= expected_state then
		error(("Cannot %s: currently %s"):format(action, self.state), 0)
	end
end

--- Converts passed timeout in seconds to milliseconds.
---@param timeout_seconds? integer Timeout in seconds.
---@return integer? Timeout in milliseconds.
local function calculate_timeout_ms(timeout_seconds)
	return timeout_seconds and timeout_seconds > 0 and (timeout_seconds * 1000) or nil
end

--- Sets the internal state and redraws the statusline.
---@param new_state MssqlQueryManagerState
function QueryManager:set_state(new_state)
	self.state = new_state
	vim.cmd("redrawstatus")
end

---@return MssqlQueryManagerState
function QueryManager:get_state()
	return self.state
end

--- Stops and cleans up the execution timer.
function QueryManager:cleanup_timer()
	if self.execution_timer and not self.execution_timer:is_closing() then
		self.execution_timer:stop()
		self.execution_timer:close()
		self.execution_timer = nil
	end
end

--- Stops timer and calculates final time.
function QueryManager:stop_execution_timer()
	if self.execution_timer then
		if self.start_time > 0 then
			self.last_execution_info.elapsed_time = (vim.loop.now() - self.start_time) / 1000
		end
		self:cleanup_timer()
		self.start_time = 0
		vim.cmd("redrawstatus")
	end
end

--- Starts the timer loop for execution tracking.
function QueryManager:start_execution_timer()
	self:stop_execution_timer()
	self.last_execution_info.elapsed_time = 0
	self.last_execution_info.rows_affected = nil
	self.start_time = vim.loop.now()

	self.execution_timer = vim.loop.new_timer()
	if self.execution_timer then
		self.execution_timer:start(0, 1000, vim.schedule_wrap(function()
			if self.state == QueryManager.states.Executing then
				self.last_execution_info.elapsed_time = (vim.loop.now() - self.start_time) / 1000
				vim.cmd("redrawstatus")
			else
				self:stop_execution_timer()
			end
		end))
	end
end

--- Initiates an async connection request.
---@param connect_params table
function QueryManager:connect_async(connect_params)
	validate_state(self, QueryManager.states.Disconnected, "connect")

	connect_params.ownerUri = self.owner_uri
	self:set_state(QueryManager.states.Connecting)

	local _, err = utils.lsp_request_async(self.client, "connection/connect", connect_params)
	if err then
		self:set_state(QueryManager.states.Disconnected)
		error("Could not connect: " .. err.message, 0)
	end

	local result
	result, err = utils.wait_for_notification_async(self.bufnr, self.client, "connection/complete", 10000)

	if err or (result and result.errorMessage and result.errorMessage ~= vim.NIL) then
		self:set_state(QueryManager.states.Disconnected)
		error("Error in connecting: " .. (err and err.message or result.errorMessage), 0)
	end

	if result and result.connectionSummary then
		connect_params.connection.options.database = result.connectionSummary.databaseName
		connect_params.connection.options.DatabaseDisplayName = result.connectionSummary.databaseName
	end

	self:set_state(QueryManager.states.Connected)
	self.last_connect_params = connect_params
end

--- Disconnects the current session.
function QueryManager:disconnect_async()
	validate_state(self, QueryManager.states.Connected, "disconnect")
	utils.lsp_request_async(self.client, "connection/disconnect", { ownerUri = self.owner_uri })
	self:set_state(QueryManager.states.Disconnected)
	self.last_connect_params = {}
	self.last_execution_info = { rows_affected = nil, elapsed_time = nil }
end

--- Executes an SQL query string.
---@param query string
---@return table? result The query result object.
function QueryManager:execute_async(query)
	validate_state(self, QueryManager.states.Connected, "execute")
	self:set_state(QueryManager.states.Executing)
	self:start_execution_timer()

	local result, err = utils.lsp_request_async(self.client, "query/executeString", {
		query = query,
		ownerUri = self.owner_uri
	})

	if err or not result then
		self:stop_execution_timer()
		self:set_state(QueryManager.states.Connected)
		error(err and ("Error executing query: " .. err.message) or "Could not execute query", 0)
	end

	return self:wait_for_query_completion()
end

--- Internal helper to wait for completion notification.
---@return table? result
function QueryManager:wait_for_query_completion()
	local timeout_ms = calculate_timeout_ms(self.query_timeout)
	local result, err = utils.wait_for_notification_async(
		self.bufnr, self.client, "query/complete", timeout_ms
	)

	self:stop_execution_timer()
	vim.cmd("redrawstatus")
	if self.state == QueryManager.states.Cancelling then
		self:set_state(QueryManager.states.Connected)
		utils.log_info("Query was cancelled.")
		return
	end

	if err and err.code == -32001 then
		return self:handle_timeout()
	end

	self:set_state(QueryManager.states.Connected)
	return result
end

--- Handles execution timeout by attempting to cancel.
---@param timeout_ms? integer
function QueryManager:handle_timeout(timeout_ms)
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

	self:set_state(QueryManager.states.Connected)
	error("Query execution connection timed out.", 0)
end

--- Cancels the currently running query.
function QueryManager:cancel_async()
	validate_state(self, QueryManager.states.Executing, "cancel")
	self:set_state(QueryManager.states.Cancelling)
	utils.lsp_request_async(self.client, "query/cancel", { ownerUri = self.owner_uri })
end

--- Parses a query/message string to find the number of rows affected.
--- NOTE: Relies on the specific "(N rows affected)" format from the LSP.
---@param message string
function QueryManager:parse_rows_affected_message(message)
	local row_count = string.match(message, "%((%d+) rows? affected%)")
	if row_count then
		self.last_execution_info.rows_affected = tonumber(row_count)
	end
end

--- Sets the final query elapsed time and row count from server results.
--- Prioritizes DML row counts if they exist, otherwise uses the SELECT row count.
---@param final_time number? The precise final execution time in seconds.
---@param select_row_count number The row count returned by the SELECT statement.
function QueryManager:set_final_execution_stats(final_time, select_row_count)
	self.last_execution_info.elapsed_time = final_time
	if self.last_execution_info.rows_affected == nil then
		self.last_execution_info.rows_affected = select_row_count
	end
end

---@return table params
function QueryManager:get_connect_params()
	return vim.tbl_deep_extend("keep", self.last_connect_params, {})
end

---@return vim.lsp.Client
function QueryManager:get_lsp_client()
	return self.client
end

---@return MssqlExecutionInfo
function QueryManager:last_execution()
	return self.last_execution_info
end

--- Updates connection parameters based on notification result.
---@param result table
---@return boolean success True if parameters were updated.
function QueryManager:update_connection_params(result)
	if not (result and result.ownerUri == self.owner_uri and result.connection) then
		return false
	end

	self.last_connect_params = vim.tbl_deep_extend("force", self.last_connect_params, {
		connection = {
			options = {
				user = result.connection.userName,
				database = result.connection.databaseName,
				server = result.connection.serverName,
			},
		},
	})
	return true
end

--- Handler for connectionchanged notification.
---@param result table
function QueryManager:connectionchanged_async(result)
	if self:update_connection_params(result) then
		self:initialise_cache_async()
	end
end

-- Passthroughs to Finder (passing client/params explicility)

function QueryManager:initialise_cache_async(force)
	return finder.initialise_cache_async(self.client, self.last_connect_params.connection.options, force)
end

function QueryManager:find_async()
	return finder.find_async(self.last_connect_params.connection.options, self.client)
end

function QueryManager:is_refreshing()
	return finder.is_refreshing(self.last_connect_params.connection.options)
end

--- Handlers (called by LSP callbacks)

---@param result table
function QueryManager:handle_query_complete(result)
	local batch_summary = result.batchSummaries and result.batchSummaries[#result.batchSummaries]
	if not batch_summary then
	  return
	end

	local elapsed_str = batch_summary.executionElapsed
	local hours, minutes, seconds = elapsed_str:match("(%d+):(%d+):([%d.]+)")
	local final_elapsed_time = (tonumber(hours) or 0) * 3600
	  + (tonumber(minutes) or 0) * 60
	  + (tonumber(seconds) or 0)

	-- Get total row count for SELECT statements only
	local total_row_count = 0
	if batch_summary.resultSetSummaries and #batch_summary.resultSetSummaries > 0 then
	  total_row_count = batch_summary.resultSetSummaries[#batch_summary.resultSetSummaries].rowCount
	end

	self:set_final_execution_stats(final_elapsed_time, total_row_count)
end

---@param result table
function QueryManager:handle_query_message(result)
	local ok, err = pcall(function()
		self:parse_rows_affected_message(result.message.message)
	end)
	if not ok then
		utils.log_warn("Failed to parse rows affected: " .. err)
	end
end

return QueryManager
