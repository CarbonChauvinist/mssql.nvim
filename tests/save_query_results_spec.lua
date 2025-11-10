local mssql = require("mssql")
local utils = require("mssql.utils")
local test_utils = require("tests/utils")

return {
	test_name = "save_query_results should call LSP with correct params",
	run_test_async = function()
		-- 1. Mocks and Captured State
		local captured_lsp_requests = {}
		local captured_logs = {}
		local captured_cmds = {}

		-- Store original functions to restore later
		local original_input = vim.fn.input
		local original_log_info = utils.log_info
		local original_log_error = utils.log_error
		local original_cmd = vim.cmd
		local original_get_lsp_client = utils.get_lsp_client

		-- Mock vim.fn.input
		local mock_input_value = ""
		---@diagnostic disable-next-line: duplicate-set-field
		vim.fn.input = function(prompt, text, completion)
			return mock_input_value
		end

		-- Mock log functions to capture output
		utils.log_info = function(msg)
			table.insert(captured_logs, "INFO: " .. msg)
		end
		utils.log_error = function(msg)
			table.insert(captured_logs, "ERROR: " .. msg)
		end

		-- Mock vim.cmd to capture commands
		vim.cmd = function(cmd)
			table.insert(captured_cmds, cmd)
		end

		-- Mock the LSP client
		local mock_client = {
			request = function(self, method, params, callback)
				table.insert(captured_lsp_requests, { method = method, params = params })

				-- Simulate a successful LSP response
				vim.schedule(function()
					callback(nil, { success = true })
				end)
		end,
		}

		-- Mock get_lsp_client to return our mock client
		utils.get_lsp_client = function(ownerUri)
			assert(ownerUri, "get_lsp_client was called with nil ownerUri")
			return mock_client
		end

		-- 2. Test Buffer Setup
		vim.cmd("enew")
		local results_buf = vim.api.nvim_get_current_buf()
		local mock_result_info = {
			ownerUri = "file:///path/to/dummy_query.sql",
			batchIndex = 0,
			resultSetIndex = 0,
			totalRows = 10,
			rowsPerQuery = 10,
			currentRowsOffset = 0,
			columnInfo = {},
			max_column_width = 100,
		}
		vim.b[results_buf].query_result_info = mock_result_info

		-- 3. Test successful CSV save
		mock_input_value = "test_save.csv"
		captured_lsp_requests = {}
		captured_logs = {}
		captured_cmds = {}

		mssql.save_query_results()
		test_utils.defer_async(100)

		assert(#captured_lsp_requests == 1, "Expected 1 LSP request for CSV save")
		assert(captured_lsp_requests[1].method == "query/saveCsv", "Called wrong LSP method")
		assert(captured_lsp_requests[1].params.FilePath == "test_save.csv", "Wrong FilePath param")
		assert(captured_lsp_requests[1].params.OwnerUri == mock_result_info.ownerUri, "Wrong OwnerUri param")
		assert(test_utils.log_contains_pattern(captured_logs, "File saved"), "Did not log success message")
		assert(test_utils.table_contains(captured_cmds, "edit test_save.csv"), "Did not edit CSV file after save")

		-- 4. Test successful XLSX Save (no edit)
		mock_input_value = "report.xlsx"
		captured_lsp_requests = {}
		captured_logs = {}
		captured_cmds = {}

		mssql.save_query_results()
		test_utils.defer_async(100)

		assert(#captured_lsp_requests == 1, "Expected 1 LSP request for XLSX save")
		assert(captured_lsp_requests[1].method == "query/saveExcel", "Called wrong LSP method")
		assert(test_utils.log_contains_pattern(captured_logs, "File saved"), "Did not log success message")
		assert(not test_utils.table_contains(captured_cmds, "edit report.xlsx"), "Should not edit Excel file after save")

		-- 5. Test bad file extension
		mock_input_value = "report.txt"
		captured_lsp_requests = {}
		captured_logs = {}
		captured_cmds = {}

		mssql.save_query_results()
		test_utils.defer_async(100)

		assert(#captured_lsp_requests == 0, "Should not call LSP for bad extension")
		assert(test_utils.log_contains_pattern(captured_logs, "File extension not recognised"), "Did not log bad extension error")

		-- 6. Test no file input (user cancel)
		mock_input_value = ""
		captured_lsp_requests = {}
		captured_logs = {}
		captured_cmds = {}

		mssql.save_query_results()
		test_utils.defer_async(100)

		assert(#captured_lsp_requests == 0, "Should not call LSP when input is empty")
		assert(test_utils.log_contains_pattern(captured_logs, "No file path given"), "Did not log no-file error")

		-- 7. Cleanup
		vim.fn.input = original_input
		utils.log_info = original_log_info
		utils.log_error = original_log_error
		vim.cmd = original_cmd
		utils.get_lsp_client = original_get_lsp_client
		vim.api.nvim_buf_delete(results_buf, { force = true })

		utils.log_info("save query_results_spec passed!")
	end,
}
