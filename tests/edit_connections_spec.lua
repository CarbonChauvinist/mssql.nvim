local mssql = require("mssql")
local test_utils = require("tests.utils")

return {
	test_name = "Edit connections",
	run_test_async = function()
		mssql.edit_connections()

		local buf = vim.api.nvim_get_current_buf()
		-- this should be the default placeholder JSON created by plugin
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		-- just assert contents are valid JSON
		local content = table.concat(lines, "\n")
		local ok, result = pcall(vim.json.decode, content)
		assert(ok, "Invalid JSON: " .. vim.inspect(result))
		test_utils.safe_buf_delete(buf, {force = true})

		-- creates our default connections.json for our tests
		local connections = test_utils.create_connection_json()
		test_utils.write_connections_file(connections)
	end,
}
