local test_utils = require("tests.utils")

return {
	test_name = "LSP should be configured so that autocomplete works on saved sql files",
	run_test_async = function()
		vim.cmd.edit({ args = { "tests/completion.sql" } })
		local buf = vim.api.nvim_get_current_buf()

		-- move to the first E in SELECT test for "SELECT"
		test_utils.wait_for_completion_item(buf, "SELECT", { cursor = {1,1}})

		test_utils.safe_buf_delete(buf, {force = true})
	end,
}
