local mssql = require("mssql")
local utils = require("mssql.utils")

local get_status = function()
  return mssql.statusline_components[1]()
end

return {
  test_name = "Query with delay should report elapsed time and row count.",
  run_test_async = function()
    local query = "WAITFOR DELAY '00:00:02' SELECT t.c FROM (VALUES (1), (2), (3), (4), (5), (6), (7), (8)) AS t(c)"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { query })

    local buf = vim.api.nvim_get_current_buf()
    local client = vim.lsp.get_clients({ name = "mssql_ls", bufnr = buf })[1]
    assert(client, "Could not get LSP client for the current buffer.")

    mssql.execute_query()
    local _, err = utils.wait_for_notification_async(buf, client, "query/complete", 3000)
    if err then
      error("Test failed while waiting for query/complete notification: " .. err.message)
    end
    utils.wait_for_schedule_async()

    local final_status = get_status()

    assert(
      final_status.status == "connected",
      "Status should be 'connected' after query completes, but was: " .. final_status.status
    )
    assert(final_status.server ~= nil, "Server should not be nil.")

    assert(final_status.elapsed_time ~= nil, "Final elapsed time should not be nil.")
    print("Final elapsed time: " .. final_status.elapsed_time)
    assert(
      string.find(final_status.elapsed_time, "00:02"),
      "Elapsed time should be approx. 2 seconds, but was" .. final_status.elapsed_time
    )

    assert(final_status.rows_affected ~= nil, "Rows affected should not be nil.")
    assert(
      string.find(final_status.rows_affected, "8 rows affected"),
      "Rows affected should contain '8 rows affected', but was: " .. final_status.rows_affected
    )

    vim.cmd("bdelete!")
  end,
}
