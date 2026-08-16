local state = require("mssql.state")
local utils = require("mssql.utils")

local M = {}

---Maps a filename extension to the LSP save method and whether to
---open the file after saving. Returns nil, nil for unsupported extensions.
---@param fname string
---@return string? method
---@return boolean? open_after_save
local map_extension = function(fname)
	local icase = fname:lower()
	if icase:match("%.csv$") then return "query/saveCsv", true end
	if icase:match("%.json$") then return "query/saveJson", true end
	if icase:match("%.xml$") then return "query/saveXml", true end
	if icase:match("%.xlsx?$") then return "query/saveExcel", false end
	return nil, nil
end

---Resolves the save target: prompts for a filename,
---maps its extension, and confirms overwrite
---@return string? file
---@return string? method
---@return boolean? open_after_save
local get_file_saveas_target = function()
	local desired_fname = vim.fn.input("Save query results (.csv/.json/.xls/.xlsx/.xml)", "", "file")
	if not desired_fname or desired_fname == "" then
		utils.log_error("No file path given")
		return
	end

	local method, open_after_save = map_extension(desired_fname)
	if not method then
		utils.log_error("File extension not recognized. Enter a file with extension .csv/.json/.xls/.xlsx/.xml")
		return
	end

	if vim.uv.fs_stat(desired_fname) then
		local choice = vim.fn.confirm(
			string.format("File: %s already exists. Overwrite?", desired_fname),
			"&Yes\n&No\n&Cancel",
			2
		)
		if choice ~= 1 then return end
	end

	return desired_fname, method, open_after_save
end


---@param result_info any
M.save_query_results_async = function(result_info)
	utils.wait_for_schedule_async()
	local success, lsp_client = pcall(utils.get_lsp_client, result_info.ownerUri)
	if not success then
		error("The buffer with the sql query has been closed, can't save query results")
	end

	local file, method, open_after_save = get_file_saveas_target()
	if not file or not method then
		utils.log_error("No file or method chosen")
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

	local _, err = utils.lsp_request_async(lsp_client, method, params)

	if err then
		utils.log_error("Error saving query results")
		return
	end

	utils.log_info("File saved")

	if open_after_save then
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

M.map_extension = map_extension

return M
