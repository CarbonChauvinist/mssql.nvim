local utils = require("mssql.utils")

local M = {}

---@type integer?
local mssql_window

---@param table string[][]
---@param limit integer
local function sanitise(tbl, limit)
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

---@param column_header string
---@param rows string[][]
---@param column_index integer
---@return integer
local function column_width(column_header, rows, column_index)
	local row_max = vim.iter(rows)
		:map(function(record)
			return vim.fn.strdisplaywidth(record[column_index])
		end)
		:fold(0, math.max)

	return math.max(vim.fn.strdisplaywidth(column_header), row_max)
end

---@param column_headers string[]
---@param rows string[][]
---@return integer[]
local function column_widths(column_headers, rows)
	if not column_headers then
		return {}
	end

	return vim.iter(ipairs(column_headers))
		:map(function(column_index, column_header)
			return column_width(column_header, rows, column_index)
		end)
		:totable()
end

---@param str string
---@param len integer
---@param char string
---@return string
local function right_pad(str, len, char)
	if vim.fn.strdisplaywidth(str) >= len then
		return str
	end
	return str .. string.rep(char, len - vim.fn.strdisplaywidth(str))
end

---@param row string[]
---@param widths integer[]
---@return string
local function row_to_string(row, widths)
	local padded_cells = vim.iter(ipairs(row))
		:map(function(column_index, value)
			return right_pad(value, widths[column_index], " ")
		end)
		:totable()
	return "| " .. table.concat(padded_cells, " | ") .. " |"
end

---@param widths integer[]
---@return string
local function header_divider(widths)
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

---@param column_headers string[]
---@param rows string[][]
---@param max_width integer
---@return string[]
local function pretty_print(column_headers, rows, max_width)
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

---@param lines string[]
---@param bufnr integer
local function display_markdown(lines, bufnr)
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

--- Fetches rows to render in results buffer. Accounts for offset allowing pagination.
---@param bufnr? integer The buffer number to render in (optional, uses current buffer if invalid)
---@param new_offset? integer The new row offset for pagination (optional, clamped to valid range)
---@return nil
local function fetch_and_render_page(bufnr, new_offset)
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

---@param result_set_summary MssqlResultSetSummary
---@param subset_params SubsetParams
---@param opts MssqlOptions
local function show_result_set_async(result_set_summary, subset_params, opts)
	local column_headers = vim.iter(result_set_summary.columnInfo)
		:map(function(i)
			return i.columnName
		end)
		:totable()

	local rows = utils.get_rows_async(subset_params)
	local lines = pretty_print(column_headers, rows, opts.max_column_width)
	local extension = opts.results_buffer_extension
	extension = extension or ""
	if extension ~= "" then
		extension = "." .. extension
	end

	local owner_buf = vim.fn.bufnr(vim.uri_to_fname(subset_params.ownerUri))
	local qm = require("mssql.state").get_query_manager(owner_buf)

	local orig_name = vim.api.nvim_buf_get_name(owner_buf)
	local short_name = vim.fn.fnamemodify(orig_name, ":t")
	if short_name == "" then short_name = tostring(owner_buf) end

	local name = string.format("results %d-%d [%s]%s",
		subset_params.batchIndex + 1,
		subset_params.resultSetIndex + 1,
		short_name,
		extension
	)

	local buf = create_buffer({
		name = name,
		filetype = opts.results_buffer_filetype,
		qm = qm,
	})

	---@type QueryResultInfo
	local info = {
		ownerUri = subset_params.ownerUri,
		batchIndex = subset_params.batchIndex,
		resultSetIndex = subset_params.resultSetIndex,
		totalRows = result_set_summary.rowCount or 0,
		rowsPerQuery = opts.max_rows,
		currentRowsOffset = 0,
		columnInfo = result_set_summary.columnInfo,
		max_column_width = opts.max_column_width,
	}
	vim.b[buf].query_result_info = info

	display_markdown(lines, buf)
	opts.open_results_in(buf)

	-- set buffer local keymaps for pagination
	local maps = opts.results_keymaps or {}
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

---Helper to open a buffer in a split (horizontal/vertical) window, reusing it if valid.
---@param bufnr integer
---@param split_command "split"|"vsplit"
local open_in_split = function(bufnr, split_command)
	local original_window = vim.api.nvim_get_current_win()

	-- open a split if we haven't already
	if not (mssql_window and vim.api.nvim_win_is_valid(mssql_window)) then
		vim.cmd(split_command)
		mssql_window = vim.api.nvim_get_current_win()
	end

	vim.api.nvim_set_option_value("buflisted", true, { buf = bufnr })
	vim.api.nvim_win_set_buf(mssql_window, bufnr)
	vim.api.nvim_set_current_win(original_window)
end

---Navigate pages in query results buffer
---@param direction "next" | "prev" | "first" | "last"
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
function M.get_pagination_status(bufnr)
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

M.show_results_buffer_options = {
	current_window = function(bufnr)
		vim.api.nvim_set_option_value("buflisted", true, { buf = bufnr })
		vim.api.nvim_set_current_buf(bufnr)
	end,
	split = function(bufnr)
		open_in_split(bufnr, "split")
	end,
	vsplit = function(bufnr)
		open_in_split(bufnr, "vsplit")
	end,
}

-- If the open_results_in is a string, sets it to the appropriate function
---@param opts? MssqlConfig
M.set_show_results_option = function(opts)
	opts = opts or {}
	if type(opts.open_results_in) == "string" and M.show_results_buffer_options[opts.open_results_in] then
		opts.open_results_in = M.show_results_buffer_options[opts.open_results_in]
	elseif type(opts.open_results_in) == "function" then
		return
	else
		utils.log_error(
			vim.inspect(opts.open_results_in)
				.. " is not a valid option for open_results_in. Must be one of: "
				.. table.concat(vim.tbl_keys(M.show_results_buffer_options), ", ")
				.. ", or a function"
		)
	end
end

---@param opts MssqlOptions
---@param result MssqlQueryExecuteSubsetResult
M.display = function(opts, result)
	if utils.is_empty(result) or utils.is_empty(result.batchSummaries) then return end
	local owner_buf = vim.fn.bufnr(vim.uri_to_fname(result.ownerUri))
	local qm = require("mssql.state").get_query_manager(owner_buf)

	-- delete existing result buffers
	if qm then qm:clear_result_buffers() end

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
					rowsCount = math.min(result_set_summary.rowCount or 0, opts.max_rows),
				}
				-- fetch and show all results at once
				vim.schedule(function()
					utils.try_resume(coroutine.create(function()
						show_result_set_async(result_set_summary, subset_params, opts)
					end))
				end)
			end
		end
	end
end

return M
