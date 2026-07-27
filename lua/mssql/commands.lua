local state = require("mssql.state")
local utils = require("mssql.utils")

local M = {}

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
		vim.cmd({ cmd = "edit", args = { file } })
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
