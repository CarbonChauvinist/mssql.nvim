local state = require("mssql.state")
local utils = require("mssql.utils")
local explorer = require("mssql.explorer")

local M = {}

---Scans active buffers and removes unused database entries from the cache
M.clean_cache = function()
	local active_managers = state.get_all_query_managers() or {}
	local in_use_connections = {}

	for _, bufnr in ipairs(active_managers) do
		local qm = state.get_query_manager(bufnr)
		if qm and qm:get_state() ~= qm.states.disconnected then
			local params = qm:get_connect_params()
			if params and params.connection and params.connection.options then
				table.insert(in_use_connections, params.connection.options)
			end
		end
	end

	explorer.delete_unused_cache(in_use_connections)
end

---@param opts MssqlOptions
M.setup = function(opts)
	vim.api.nvim_create_augroup("AutoNameSQL", { clear = true })

	-- Reset the buffer to the file name upon saving
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = "AutoNameSQL",
		pattern = "*.sql",
		callback = function(args)
			local buf = args.buf
			if vim.b[buf].is_temp_name then
				vim.api.nvim_buf_set_name(buf, vim.fn.expand("<afile>:p"))
				vim.b[buf].is_temp_name = nil

				local qm = state.get_query_manager(buf)
				local current_conf = state.get_config()
				if qm and qm:get_state() == qm.states.connected and current_conf and current_conf.auto_connect_on_rename then
					local success, err = utils.reconnect_session(qm, "Buffer renamed")
					if not success then
						utils.log_error(err)
					end
				end
			end
		end,
	})


	if opts.sql_buffer_options and opts.sql_buffer_options ~= {} then
		vim.api.nvim_create_autocmd("FileType", {
			group = "AutoNameSQL",
			pattern = "sql",
			callback = function()
				-- copy all properties
				for k, v in pairs(opts.sql_buffer_options) do
					vim.bo[k] = v
				end
			end,
		})
	end

	-- clean the sql object cache on buffer close
	vim.api.nvim_create_autocmd("BufDelete", {
		group = "AutoNameSQL",
		callback = function(args)
			local buf = args.buf

			local qm = state.get_query_manager(buf)
			if qm then
				qm:disconnect_async()
				qm:cleanup()
				state.remove_query_manager(buf)
				vim.schedule(function()
					M.clean_cache()
				end)
			end

		end,
	})

end

return M
