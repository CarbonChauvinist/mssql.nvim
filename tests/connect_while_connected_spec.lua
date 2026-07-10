local mssql = require("mssql")
local explorer = require("mssql.explorer")
local test_utils = require("tests.utils")

return {
  test_name = "Connect when already connected should disconnect cleanly first and refresh cache",

  run_test_async = function()
    local buf, _client, qm, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

    assert(qm:get_state() == qm.states.connected, "Should be connected initially")
    qm:initialise_cache_async("database", true)

    local tempdb_cached = test_utils.poll(function()
      local cache = explorer.get_cache()
      return vim.iter(pairs(cache)):any(function(key)
        return key:lower():find("tempdb")
      end)
    end)
    assert(tempdb_cached, "Cache was not populated for tempdb")

    local json = [[
    {
      "TestConnection": {
        "server": "localhost",
        "database": "tempdb",
        "authenticationType": "SqlLogin",
        "user": "sa",
        "password": "Test_Password_123",
        "trustServerCertificate": true
      },
      "TestConnectionB": {
        "server": "localhost",
        "database": "TestDbB",
        "authenticationType": "SqlLogin",
        "user": "sa",
        "password": "Test_Password_123",
        "trustServerCertificate": true
      }
    }
    ]]

    test_utils.write_connections_file(json)

    test_utils.ui_select_fake("TestConnectionB")
    mssql.connect(buf)
    -- test_utils.wait_for_connected(buf)
    -- test_utils.wait_for_intellisenseReady(buf, client)
    -- qm = mssql.get_query_manager(buf)
    -- assert(qm, "Query manager not present")

    -- local current_db = qm:get_database_name()
    -- assert(current_db == "TestDB", "Database name did not update to TestDbB. Current: " .. tostring(current_db))
    local switch_success = test_utils.poll(function()
      return qm:get_database_name() == "TestDbB" and qm:get_state() == qm.states.connected
    end, { timeout_ms = 10000 })
    assert(switch_success, "Failed to switch database connection to TestConnectionB")
    local current_db = qm:get_database_name()
    assert(qm:get_state() == qm.states.connected, "Query Manager should be connected to the new database")
    -- qm:initialise_cache_async("database", true)

    -- verify old cache was cleaned
    local tempdb_cleared = test_utils.poll(function()
      local cache = explorer.get_cache()
      return not vim.iter(pairs(cache)):any(function(key)
        return key:lower():find("tempdb")
      end)
    end, { timeout_ms = 5000 })
    assert(tempdb_cleared, "Old cache entry for 'tempdb' was not removed after reconnecting")

    cleanup()
  end,
}
