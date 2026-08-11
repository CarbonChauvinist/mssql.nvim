local utils = require("mssql.utils")

local M = {}

---Truncates long cells and replaces literal newlines with formatted string representations.
---@param tbl string[][]
---@param limit integer
local sanitise = function(tbl, limit)
	for _, record in ipairs(tbl) do
		for index, value in ipairs(record) do
			local str = tostring(value)
			-- truncate
			if vim.fn.strdisplaywidth(str) > limit then
				str = str:sub(1, limit) .. "..."
			end
			-- replace newline chars with `\n`. Backticks to look good in markdown
			str = str:gsub("\n", "`\\n`")
			record[index] = str
		end
	end
end

---Calculates the maximum display width required for a given column.
---@param column_header string
---@param rows string[][]
---@param column_index integer
---@return integer
local column_width = function(column_header, rows, column_index)
	local row_max = vim.iter(rows)
		:map(function(record)
			return vim.fn.strdisplaywidth(record[column_index])
		end)
		:fold(0, math.max)

	return math.max(vim.fn.strdisplaywidth(column_header), row_max)
end

---Calculates the display widths for all columns.
---@param column_headers string[]
---@param rows string[][]
---@return integer[]
local column_widths = function(column_headers, rows)
	if not column_headers then
		return {}
	end

	return vim.iter(ipairs(column_headers))
		:map(function(column_index, column_header)
			return column_width(column_header, rows, column_index)
		end)
		:totable()
end

---Appends padding characters to the right side of a string up to the specified display width.
---@param str string
---@param len integer
---@param char string
---@return string
local right_pad = function(str, len, char)
	if vim.fn.strdisplaywidth(str) >= len then
		return str
	end
	return str .. string.rep(char, len - vim.fn.strdisplaywidth(str))
end

---Converts a row of cells into a formatted Markdown table row.
---@param row string[]
---@param widths integer[]
---@return string
local row_to_string = function(row, widths)
	local padded_cells = vim.iter(ipairs(row))
		:map(function(column_index, value)
			return right_pad(value, widths[column_index], " ")
		end)
		:totable()
	return "| " .. table.concat(padded_cells, " | ") .. " |"
end

---Generates a Markdown table header divide line.
---@param widths integer[]
---@return string
local header_divider = function(widths)
	if not widths then
		return ""
	end

	local dashes_row = vim.iter(widths)
		:map(function(width)
			return string.rep("-", width)
		end)
		:totable()
	return row_to_string(dashes_row, widths)
end

---Formats column headers and rows into printable Markdown lines.
---@param column_headers string[]
---@param rows string[][]
---@param max_width integer
---@return string[]
local pretty_print = function(column_headers, rows, max_width)
	if not column_headers then
		return { "" }
	end

	sanitise(rows, max_width)

	local widths = column_widths(column_headers, rows)
	local divider = header_divider(widths)

	local lines = { row_to_string(column_headers, widths), divider }
	for _, row in ipairs(rows) do
		table.insert(lines, row_to_string(row, widths))
	end

	return lines
end

---Creates a new unlisted buffer for query results and sets its filetype.
---param opts? { name: string, filetype:? string, qm:? MssqlQueryManager }
---@return integer bufnr
local function create_buffer(opts)
	opts = opts or {}
	local name = opts.name
	local filetype = opts.filetype
	local bufnr = vim.api.nvim_create_buf(false, false)
	local qm = opts.qm

	vim.api.nvim_buf_set_name(bufnr, name)
	if filetype and filetype ~= "" then
		vim.api.nvim_set_option_value("filetype", filetype, { buf = bufnr })
	end
	if qm then
		table.insert(qm.result_buffers, bufnr)
	end
	return bufnr
end

---Writes formatted lines to the result buffer and configures read-only buffer options.
---@param lines string[]
---@param bufnr integer
local display_markdown = function(lines, bufnr)
	-- due to pagination need to make writeable/modifiable at first
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_set_option_value("readonly", false, { buf = bufnr })

	-- then set the results buffer contents and set desired option values
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
	vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
end

---Fetches a subset of rows from the query dataset and renders them in the results buffer.
---Accounts for offset allowing pagination.
---@param bufnr? integer The buffer number to render in (defaults to current buffer)
---@param new_offset? integer The new row offset for pagination (optional, clamped to valid range)
---@return nil
local fetch_and_render_page = function(bufnr, new_offset)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		bufnr = vim.api.nvim_get_current_buf()
	end

	---@type QueryResultInfo?
	local original_info = vim.b[bufnr].query_result_info
	if not original_info then
		utils.log_error("Not a query result buffer")
		return
	end

	---@type QueryResultInfo
	local info = vim.deepcopy(original_info)

	-- store the originally requested offset before clamping
	local requested_offset = new_offset

	local last_page_start = 0
	if info.totalRows > 0 and info.rowsPerQuery > 0 then
		last_page_start = math.floor((info.totalRows - 1) / info.rowsPerQuery) * info.rowsPerQuery
	end
	new_offset = math.max(0, math.min(new_offset or 0, last_page_start))

	if new_offset == info.currentRowsOffset then
		-- compare requested offset with current one to know the direction
		if requested_offset and requested_offset < info.currentRowsOffset then
			utils.log_info("Already at first page")
		else
			utils.log_info("Already at last page")
		end
		return
	end

	info.currentRowsOffset = new_offset

	---@type SubsetParams
	local new_subset_params = {
		ownerUri = info.ownerUri,
		batchIndex = info.batchIndex,
		resultSetIndex = info.resultSetIndex,
		rowsStartIndex = info.currentRowsOffset,
		rowsCount = math.min(info.rowsPerQuery, info.totalRows - info.currentRowsOffset)
	}

	local rows = utils.get_rows_async(new_subset_params)

	vim.schedule(function()
		vim.b[bufnr].query_result_info = info
		local column_headers = vim.iter(info.columnInfo)
			:map(function(i) return i.columnName end)
			:totable()

		local lines = pretty_print(column_headers, rows, info.max_column_width)

		display_markdown(lines, bufnr)
		utils.request_redrawstatus()
		utils.log_info(string.format(
			"Showing rows %d-%d of %d",
			info.currentRowsOffset + 1,
			info.currentRowsOffset + #rows,
			info.totalRows
			)
		)
	end)
end

---Formats query results as a classic space-aligned CLI text table (like sqlcmd)
---@param column_headers string[]
---@param rows string[][]
---@param max_width integer
---@return string[] lines
local format_as_text = function(column_headers, rows, max_width)
	if not column_headers then return { "" } end

	sanitise(rows, max_width)
	local widths = column_widths(column_headers, rows)

	-- headers: "ID   Make     PersonId"
	local header_cells = {}
	local divider_cells = {}
	for idx, col in ipairs(column_headers) do
		table.insert(header_cells, right_pad(col, widths[idx], " "))
		table.insert(divider_cells, string.rep("-", widths[idx]))
	end

	local lines = {
		table.concat(header_cells, "  "),
		table.concat(divider_cells, "  ")
	}

	for _, row in ipairs(rows) do
		local row_cells = {}
		for idx, val in ipairs(row) do
			table.insert(row_cells, right_pad(val, widths[idx], " "))
		end
		table.insert(lines, table.concat(row_cells, "  "))
	end

	return lines
end


---Escapes a value for safe CSV representation
---@params val any
---@return string
local csv_escape = function(val)
	val = tostring(val or "")
	if val:find('[,"\n\r]') then
		return '"' .. val:gsub('"', '""') .. '"'
	end
	return val
end

---Formats query results as comma-separated values (CSV)
---@param column_headers string[]
---@param rows string[][]
---@return string[] lines
local format_as_csv = function(column_headers, rows)
	if not column_headers then return { "" } end

	local lines = {}

	-- headers: "ID,Make,PersonId"
	local header_cells = {}
	for _, col in ipairs(column_headers) do
		table.insert(header_cells, csv_escape(col))
	end
	table.insert(lines, table.concat(header_cells, ","))

	-- rows: "1,Merc,1"
	for _, row in ipairs(rows) do
		local row_cells = {}
		for _, val in ipairs(row) do
			table.insert(row_cells, csv_escape(val))
		end
		table.insert(lines, table.concat(row_cells, ","))
	end

	return lines
end

---Converts columns and rows into a formatted JSON string
---@param column_headers string[]
---@param rows string[][]
---@return string[] lines
local format_as_json = function(column_headers, rows)
	local objects = {}
	for _, row in ipairs(rows) do
		local obj = {}
		for idx, col in ipairs(column_headers) do
			obj[col] = row[idx]
		end
		table.insert(objects, obj)
	end

	local raw_json = vim.json.encode(objects)

	local success, formatted = pcall(function()
		if vim.fn.executable("jq") == 1 then
			return vim.fn.system("jq .", raw_json)
		end
		error("jq not available")
	end)

	if success and formatted and formatted ~= "" then
		return vim.split(formatted:gsub("\r", ""), "\n")
	else
		return { raw_json }
	end
end

---Asynchronously fetches and displays a specific result set in a new results buffer.
---@param ctx ShowResultSetContext
local show_result_set_async = function(ctx)
	local result_set_summary = ctx.result_set_summary
	local batch_summary = ctx.batch_summary
	-- resolve selection: prefer batchstart capture (guaranteed per-batch)
	-- fall back to query/complete's selection if no batchstart data, then cursor position
	local selection = nil
	if batch_summary then
		local owner_buf_tmp = vim.fn.bufnr(vim.uri_to_fname(ctx.subset_params.ownerUri))
		local qm = require("mssql.state").get_query_manager(owner_buf_tmp)
		selection = qm and qm._batch_selections and qm._batch_selections[batch_summary.id]
	end
	if not selection then
		selection = batch_summary and batch_summary.selection
	end
	local subset_params = ctx.subset_params
	local config = ctx.config
	local exec_opts = ctx.exec_opts or {}

	if not result_set_summary then return end

	local column_headers = vim.iter(result_set_summary.columnInfo)
		:map(function(i)
			return i.columnName
		end)
		:totable()

	local rows = utils.get_rows_async(subset_params)
	local want_virt = config.display_scalar_as_virtual_text or exec_opts.virtual_text

	-- only show virtual text when the result set has a unique position
	-- within a single batch (i.e. no GO batch separators) all results share
	-- the same batch_summary.selection, so virtual text would collide
	local result_set_count = batch_summary and batch_summary.resultSetSummaries and #batch_summary.resultSetSummaries or 0
	if want_virt and result_set_count <= 1 and #rows == 1 and #column_headers == 1 then
		local owner_buf = vim.fn.bufnr(vim.uri_to_fname(subset_params.ownerUri))
		local target_line
		if selection and selection.endLine then
			target_line = math.max(0, selection.endLine - 1)
		else
			target_line = vim.api.nvim_win_get_cursor(0)[1] - 1
		end

		local scalar_val = tostring(rows[1][1] or "NULL")
		require("mssql.ui").set_virtual_text(owner_buf, target_line, scalar_val)
		return
	end

	local extension, filetype, lines
	if config.results_output_format == "json" then
		extension = "json"
		filetype = "json"
		lines = format_as_json(column_headers, rows)
	elseif config.results_output_format == "csv" then
		extension = "csv"
		filetype = "csv"
		lines = format_as_csv(column_headers, rows)
	elseif config.results_output_format == "text" then
		extension = "txt"
		filetype = ""
		lines = format_as_text(column_headers, rows, config.max_column_width)
	elseif config.results_output_format == "markdown" then
		extension = "md"
		filetype = "markdown"
		lines = pretty_print(column_headers, rows, config.max_column_width)
	end

	local owner_buf = vim.fn.bufnr(vim.uri_to_fname(subset_params.ownerUri))
	local qm = require("mssql.state").get_query_manager(owner_buf)

	local orig_name = vim.api.nvim_buf_get_name(owner_buf)
	local short_name = vim.fn.fnamemodify(orig_name, ":t:r")
	if short_name == "" then short_name = tostring(owner_buf) end

	local name = string.format("results %d-%d [%s].%s",
		subset_params.batchIndex + 1,
		subset_params.resultSetIndex + 1,
		short_name,
		extension
	)

	local buf = create_buffer({
		name = name,
		filetype = filetype,
		qm = qm,
	})

	---@type QueryResultInfo
	local info = {
		ownerUri = subset_params.ownerUri,
		batchIndex = subset_params.batchIndex,
		resultSetIndex = subset_params.resultSetIndex,
		totalRows = result_set_summary.rowCount or 0,
		rowsPerQuery = config.max_rows,
		currentRowsOffset = 0,
		columnInfo = result_set_summary.columnInfo,
		max_column_width = config.max_column_width,
	}
	vim.b[buf].query_result_info = info

	display_markdown(lines, buf)
	config.open_results_in(buf)

	-- set buffer local keymaps for pagination
	local maps = config.results_keymaps or {}
	if maps.prev_page then
		vim.keymap.set("n", maps.prev_page, M.prev_page, { buffer = buf, nowait = true})
	end
	if maps.first_page then
		vim.keymap.set("n", maps.first_page, M.first_page, { buffer = buf, nowait = true})
	end
	if maps.next_page then
		vim.keymap.set("n", maps.next_page, M.next_page, { buffer = buf, nowait = true})
	end
	if maps.last_page then
		vim.keymap.set("n", maps.last_page, M.last_page, { buffer = buf, nowait = true})
	end
end


---Navigate pages in query results buffer
---@param direction "next" | "prev" | "first" | "last"
---@return nil
M.navigate_page = function(direction)
	utils.try_resume(coroutine.create(function()
		local buf = vim.api.nvim_get_current_buf()
		---@type QueryResultInfo?
		local info = vim.b[buf].query_result_info
		if not info then return end

		local target_offset = 0
		if direction == "next" then
			target_offset = info.currentRowsOffset + info.rowsPerQuery
		elseif direction == "prev" then
			target_offset = info.currentRowsOffset - info.rowsPerQuery
		elseif direction == "first" then
			target_offset = 0
		elseif direction == "last" then
			if info.totalRows > 0 then
				target_offset = math.floor((info.totalRows - 1) / info.rowsPerQuery) * info.rowsPerQuery
			end
		end

		fetch_and_render_page(buf, target_offset)
	end))
end

function M.next_page() M.navigate_page("next") end
function M.prev_page() M.navigate_page("prev") end
function M.first_page() M.navigate_page("first") end
function M.last_page() M.navigate_page("last") end

---Get pagination status string for display in statusline
---@param bufnr? integer
---@return string
M.get_pagination_status = function(bufnr)
	-- need to sanitize, for e.g. heirline passes component table as first argument
	if type(bufnr) ~= "number" then
		bufnr = vim.api.nvim_get_current_buf()
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return ""
	end
	---@type QueryResultInfo?
	local info = vim.b[bufnr].query_result_info
	if not info then
		return ""
	end

	local start_row = info.currentRowsOffset + 1
	local end_row = info.currentRowsOffset + math.min(info.rowsPerQuery, info.totalRows - info.currentRowsOffset)

	return string.format("  Rows %d-%d of %d  ", start_row, end_row, info.totalRows)
end

---Asynchronously displays all result sets for a completed query execution.
---@param config MssqlOptions
---@param result MssqlQueryExecuteSubsetResult
---@param exec_opts? MssqlExecutionOptions
---@return nil
M.display = function(config, result, exec_opts)
	exec_opts = exec_opts or {}
	if utils.is_empty(result) or utils.is_empty(result.batchSummaries) then return end
	local owner_buf = vim.fn.bufnr(vim.uri_to_fname(result.ownerUri))
	local qm = require("mssql.state").get_query_manager(owner_buf)

	-- delete existing result buffers
	if qm then qm:clear_result_buffers() end
	local want_virt = config.display_scalar_as_virtual_text or (exec_opts and exec_opts.virtual_text)
	if want_virt then require("mssql.ui").clear_virtual_text(owner_buf) end

	if utils.is_empty(result) or utils.is_empty(result.batchSummaries) then
		return
	end

	for batch_index, batch_summary in ipairs(result.batchSummaries) do
		if not utils.is_empty(batch_summary) and not batch_summary.hasError and not utils.is_empty(batch_summary.resultSetSummaries) then
			for result_set_index, result_set_summary in ipairs(batch_summary.resultSetSummaries) do
				local subset_params = {
					ownerUri = result.ownerUri,
					batchIndex = batch_index - 1,
					resultSetIndex = result_set_index - 1,
					rowsStartIndex = 0,
					rowsCount = math.min(result_set_summary.rowCount or 0, config.max_rows),
				}
				-- fetch and show all results at once
				local captured_batch_summary = batch_summary
				local captured_result_set_summary = result_set_summary
				vim.schedule(function()
					utils.try_resume(coroutine.create(function()
						show_result_set_async({
							result_set_summary = captured_result_set_summary,
							batch_summary = captured_batch_summary,
							subset_params = subset_params,
							config = config,
							exec_opts = exec_opts,
						})
					end))
				end)
			end
		end
	end
end

return M
