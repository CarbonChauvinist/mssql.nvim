local state = require("mssql.state")
local utils = require("mssql.utils")
local ui = require("mssql.ui")

local M = {}

---@param opts MssqlOptions
M.new_default_query_async = function(opts)
	utils.wait_for_schedule_async()

	local connections = utils.get_connections(opts)
	if not (connections and connections.default) then
		utils.log_info("Add a connection called 'default'")
		utils.edit_connections(opts)
		return
	end
	local connection = connections.default

	local buf = ui.new_query_async()
	local query_manager = state.get_query_manager(buf)
	if not query_manager then
		error("CRITICAL: Lsp attached without query manager")
	end

	if connection.promptForPassword then
		connection.password = vim.fn.inputsecret("password for " .. (connection.server or ""))
	end

	local connectParams = {
		connection = {
			options = connection,
		},
	}

	query_manager:connect_async(connectParams)

	if connection.promptForDatabase then
		M.switch_database_async(buf)
	else
		utils.log_info("Connected")
	end
	query_manager:initialise_explorer_cache_async({ is_background = true })
end

---@param query_manager MssqlQueryManager
M.backup_database_async = function(query_manager)
	if query_manager:get_state() ~= query_manager.states.connected then
		error("Connect to a database first", 0)
	end
	local connect_params = query_manager:get_connect_params()
	if
		not (
			connect_params
			and connect_params.connection
			and connect_params.connection.options
			and connect_params.connection.options.database
		)
	then
		error("No connection found", 0)
	end
	local database = connect_params.connection.options.database
	local dir = vim.fs.joinpath(vim.fn.getcwd(), database .. ".bak")
	local query = string.format(
		[[BACKUP DATABASE [%s]
-- Change to your backup location
TO DISK = N'%s'
WITH
INIT, -- Remove if not overwriting
STATS = 25]],
		database,
		dir
	)

	ui.insert_query_into_buffer(query)
end

---@param query_manager MssqlQueryManager
M.restore_database_async = function(query_manager)
	if query_manager:get_state() ~= query_manager.states.connected then
		error("Connect to a server first", 0)
	end

	local file = vim.fn.input("Enter .bak file path:", "", "file")
	if not file or file == "" then
		error("No file chosen", 0)
	end

	local internal_files = utils.get_query_result_async(query_manager:execute_async("RESTORE FILELISTONLY FROM DISK = '" .. file .. "'"))
	local headers = utils.get_query_result_async(query_manager:execute_async("RESTORE HEADERONLY FROM DISK = '" .. file .. "'"))[1]

	local database = headers.DatabaseName
	local size = tonumber(headers.BackupSize)
	local stats = size <= 2000000000 and 25 or 10 -- <= 2GB

	local data_path = utils.get_query_result_async(
		query_manager:execute_async("SELECT SERVERPROPERTY('InstanceDefaultDataPath') AS DefaultDataPath")
	)[1].DefaultDataPath

	local moves = vim.iter(internal_files)
		:map(function(f)
			return "MOVE N'"
				.. f.LogicalName
				.. "' TO N'"
				.. vim.fs.joinpath(data_path, vim.fs.basename(f.PhysicalName))
				.. "',"
		end)
		:join("\n")

	local query = string.format(
		[[-- WARNING: Read and understand this before executing!
USE [master]
ALTER DATABASE [%s] SET SINGLE_USER WITH ROLLBACK IMMEDIATE -- drop connections
RESTORE DATABASE [%s] FROM  DISK = N'%s' WITH
FILE = 1,
%s
REPLACE, -- overwrite existing
STATS = %s
ALTER DATABASE [%s] SET MULTI_USER]],
		database,
		database,
		file,
		moves,
		stats,
		database
	)

	ui.insert_query_into_buffer(query)
end

---@param result_info any
M.save_query_results_async = function(result_info)
	utils.wait_for_schedule_async()
	local success, lsp_client = pcall(utils.get_lsp_client, result_info.ownerUri)
	if not success then
		error("The buffer with the sql query has been closed, can't save query results")
	end

	local file = vim.fn.input("Save query results (.csv/.json/.xls/.xlsx/.xml)", "", "file")
	if not file or file == "" then
		utils.log_error("No file path given")
		return
	end

	local params = {
		FilePath = file,
		BatchIndex = result_info.batchIndex,
		ResultSetIndex = result_info.resultSetIndex,
		OwnerUri = result_info.ownerUri,
		IncludeHeaders = true,
		Formatted = true,
	}

	local method
	local openAfterSave = true
	if file:match("%.csv$") then method = "query/saveCsv"
	elseif file:match("%.json$") then method = "query/saveJson"
	elseif file:match("%.xml$") then method = "query/saveXml"
	elseif file:match("%.xlsx?$") then
		method = "query/saveExcel"
		openAfterSave = false
	else
		utils.log_error("File extension not recognised. Enter a file with extension .csv/.json/.xls/.xlsx/.xml")
		return
	end

	local _, err = utils.lsp_request_async(lsp_client, method, params)

	if err then
		utils.log_error("Error saving query results")
		utils.log_error(vim.inspect(err))
		return
	end

	utils.log_info("File saved")

	if openAfterSave then
		vim.cmd("edit " .. file)
	end
end


---@overload fun()
---@overload fun(bufnr: integer)
---@param bufnr? integer
M.switch_database_async = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local qm = state.get_query_manager(bufnr)
	if not qm then
		error("No mssql lsp is attached. Create a new query or open an existing one.", 0)
	end
	if qm:get_state() ~= qm.states.connected then
		error("You need to connect first", 0)
	end

	local client = qm:get_lsp_client()
	local result, err = utils.lsp_request_async(client, "connection/listdatabases", { ownerUri = vim.uri_from_bufnr(bufnr) })

	if err then
		error("Error listing databases: " .. err.message, 0)
	elseif not (result and result.databaseNames) then
		error("Could not list databases", 0)
	end

	-- get the connect_params first because they are set to nil when we disconnect
	local connect_params = qm:get_connect_params()
	if not connect_params then
		error("Internal Error: Connection parameters are missing despite being in Connected state.", 0)
	end
	if not (connect_params.connection and connect_params.connection.options) then
		error("Internal Error: Connection parameters are malformed.", 0)
	end

	local db_list = result.databaseNames
	local conn_options = connect_params.connection.options
	local allow_list = conn_options and conn_options.databaseAllowList
	local deny_list = conn_options and conn_options.databaseDenyList

	local db = utils.ui_select_async(
		utils.filter_list(
			db_list,
			allow_list,
			deny_list
		)
		, { prompt = "Choose database" }
	)
	if not db then return end


	qm:disconnect_async()
	connect_params.connection.options.database = db
	qm:connect_async(connect_params)
	utils.log_info("Connected")
end

---@param opts MssqlOptions
---@param query_manager MssqlQueryManager
---@param bufnr integer
---@return boolean? success
---@return string? err
M.perform_connect_async = function(opts, query_manager, bufnr)
	local json = utils.get_connections(opts)
	if not json then
		utils.edit_connections(opts)
		return false
	end

	local con_name = utils.ui_select_async(vim.tbl_keys(json), { prompt = "Choose connection" })
	if not con_name then
		utils.log_info("No connection chosen")
		return false
	end

	local con = json[con_name]

	if con.promptForPassword then
		con.password = vim.fn.inputsecret("password for " .. (con.server or ""))
	end

	-- disconnect first to clean up old connection and state
	if query_manager:get_state() == query_manager.states.connected then
		query_manager:disconnect_async()
	end

	local connectParams = {
		connection = {
			options = con,
		},
	}

	local ok, err = query_manager:connect_async(connectParams)
	if not ok then
		utils.log_error(err or "Failed to connect")
		return false, err
	end

	if con.promptForDatabase then
		M.switch_database_async(bufnr)
	else
		utils.log_info("Connected")
	end
	return true
end

return M
