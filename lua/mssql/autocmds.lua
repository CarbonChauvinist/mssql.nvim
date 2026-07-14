local state = require("mssql.state")
local explorer = require("mssql.explorer")

local M = {}

---@param opts MssqlOptions
M.setup = function(opts)
	vim.api.nvim_create_augroup("AutoNameSQL", { clear = true })

	-- Sends query/connectionUriChanged notification to STS on `:w` or `:saveas`
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = "AutoNameSQL",
		pattern = "*.sql",
		callback = function(args)
			local buf = args.buf
			local qm = state.get_query_manager(buf)

			if qm then
				if vim.b[buf].is_temp_name then
					vim.api.nvim_buf_set_name(buf, vim.fn.expand("<afile>:p"))
					vim.b[buf].is_temp_name = nil
				end
				qm:change_uri_async()
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

	-- Cleans up results buffers, timers and QM state on buffer close
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
					explorer.clean_cache()
				end)
			end

		end,
	})
end

return M
