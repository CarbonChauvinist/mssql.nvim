local lsp = require("mssql.lsp")
local state = require("mssql.state")

return {
	test_name = "LSP handler table resolves keys case-insensitively via metatable",
	run_test_async = function()
		state._reset_all_state()

		-- mock vim.lsp.start to capture the config it receives
		local original_start = vim.lsp.start
		local captured_config = nil

		---@diagnostic disable-next-line: duplicate-set-field
		vim.lsp.start = function(config)
			captured_config = config
			return 1
		end

		-- mock filetype/opts needed for enable() to run
		vim.bo.filetype = "sql"
		lsp.enable()
		vim.lsp.start = original_start

		if not captured_config then
			error("M.enable() did not call vim.lsp.start")
		end

		local handlers = captured_config.handlers
		if not handlers then
			error("LSP config is missing 'handlers' table")
		end

		-- access using the official LSP CamelCase name
		-- the file defines it as ["textdocument/intellisenseready"] (lowercase)
		-- request ["textDocument/intelliSenseReady"] (camelcase)
		local handler = handlers["textDocument/intelliSenseReady"]
		assert(handler, "Metatable lookup failed! Could not find handler for 'textDocument/intelliSenseReady'")
		assert(type(handler) == "function", "Returned handler is not  a function")

		-- verify it's not just a raw key (it must be via metatable/normalization)
		-- ensures not accidentally adding CamelCase key to the table directly
		local raw_val = rawget(handlers, "textDocument/intelliSenseReady")
		assert(raw_val == nil, "Test invalid: The key actually exists in the table. It should only exist via __index.")

		-- verify fallback behavior (Dynamic Routing)
		-- "query/complete" is not explicitly defined, so should hit the dynamic router in __index
		local dynamic_handler = handlers["query/complete"]
		assert(dynamic_handler, "Dynamic routing for 'query/complete' failed")
	end,
}
