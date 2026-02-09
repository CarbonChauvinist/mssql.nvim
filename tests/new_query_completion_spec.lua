local test_utils = require("tests.utils")

return {
	test_name = "Autocomplete should work after new_query()",
	run_test_async = function()
		require("mssql").new_query()
		local buf = vim.api.nvim_get_current_buf()
		---@type vim.lsp.Client
		local client = test_utils.wait_for_lsp_attach(buf)
		local statement = "se * from TestTable"
		assert(client, "No lsp clients attached.")

		-- move to the first E in SELECT
		test_utils.wait_for_completion_item(buf, "SELECT", { text = statement, cursor = {1, 1}})

		test_utils.safe_buf_delete(buf, {force = true})
	end,
}
