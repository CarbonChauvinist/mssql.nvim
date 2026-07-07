local finder = require("mssql.find_object")
local state = require("mssql.state")
local test_utils = require("tests.utils")

return {
  test_name = "Object Filters (Tables, Views, Sprocs) respect Allow/Deny patterns",
  run_test_async = function()
    state._reset_all_state()

    local session_id = "sess_obj_filter_test"

    -- MOCK LSP CLIENT
    local mock_client = {
      id = 998877,
      request = function(_, method, params, cb)
        if method == "objectexplorer/createsession" then
          vim.defer_fn(function()
			state.resume_waiting_coroutine(0, "objectexplorer/sessioncreated", {
              sessionId = session_id,
              success = true,
              rootNode = { nodePath = "root", objectType = "Database" },
            }, nil)

            if cb then
              cb(nil, { sessionId = session_id })
            end
          end, 10)
          return true, 1
        elseif method == "objectexplorer/expand" then
          local nodes = {}

          if params.nodePath == "root" then
            -- Level 1: Folders
            nodes = {
              { label = "Tables", nodePath = "root/Tables", objectType = "Folder" },
              { label = "Views", nodePath = "root/Views", objectType = "Folder" },
              { label = "Stored Procedures", nodePath = "root/Sprocs", objectType = "Folder" },
            }
          elseif params.nodePath == "root/Tables" then
            -- Level 2: Tables (Real LSP returns label="dbo.MyTable")
            nodes = {
              -- ALLOWED
              { label = "dbo.User", objectType = "Table", metadata = { schema = "dbo", name = "User" } },
              -- DENIED (Explicitly)
              { label = "dbo.LegacyUser", objectType = "Table", metadata = { schema = "dbo", name = "LegacyUser" } },
              -- DENIED (Implicitly by allow list)
              { label = "sales.Order", objectType = "Table", metadata = { schema = "sales", name = "Order" } },
            }
          elseif params.nodePath == "root/Views" then
            -- Level 2: Views
            nodes = {
              -- ALLOWED (Implicitly)
              { label = "dbo.PublicData", objectType = "View", metadata = { schema = "dbo", name = "PublicData" } },
              -- DENIED (Explicitly)
              { label = "security.Secrets", objectType = "View", metadata = { schema = "security", name = "Secrets" } },
            }
          elseif params.nodePath == "root/Sprocs" then
            -- Level 2: Sprocs
            nodes = {
              -- ALLOWED
              {
                label = "api.GetThings",
                objectType = "StoredProcedure",
                metadata = { schema = "api", name = "GetThings" },
              },
              -- DENIED (Implicitly)
              {
                label = "dbo.DoInternal",
                objectType = "StoredProcedure",
                metadata = { schema = "dbo", name = "DoInternal" },
              },
            }
          end

          -- Trigger expansion event
          vim.defer_fn(function()
			finder.handle_expand_completed(nil, {
              sessionId = session_id,
              nodes = nodes,
            }, { client_id = 998877 })
          end, 10)

          return true, 2
        elseif method == "objectexplorer/closeSession" then
          cb(nil, {})
          return true, 3
        end
      end,
    }

    -- TEST CONFIGURATION
    local conn_opts = {
      server = "MyServer",
      database = "TestDb",
      objectFilters = {
        -- Case 1: Tables (Allow + Deny)
        t = {
          allow = { "dbo.*" },
          deny = { "dbo.Legacy.*" },
        },
        -- Case 2: Views (Deny Only -> Implicit Allow Others)
        v = {
          deny = { "security.*" },
        },
        -- Case 3: Sprocs (Allow Only -> Implicit Deny Others)
        sp = {
          allow = { "api.*" },
        },
      },
    } --[[@as MssqlConnectionOptions]]

    finder.initialise_cache_async(mock_client, conn_opts, { scope = "database", force = true })

    -- ASSERTIONS
    -- 1. Tables
    local found_user = test_utils.wait_for_cache_content("dbo.User", { type = "Table", timeout = 1000, debug = true })
    assert(found_user, "Should find 'dbo.User' (Allowed)")

    local status_legacy, err_legacy =
      pcall(test_utils.wait_for_cache_content, "dbo.LegacyUser", { type = "Table", timeout = 500, debug = true })
    assert(status_legacy == false, "Should have timed out (failed) finding 'dbo.LegacyUser'")
    assert(tostring(err_legacy):match("Timeout"), "Should NOT find 'dbo.LegacyUser' (Denied explicitly)")

    local status_sales, err_sales =
      pcall(test_utils.wait_for_cache_content, "sales.Order", { type = "Table", timeout = 500, debug = true })
    assert(status_sales == false, "Should have timed out (failed) finding 'sales.Order'")
    assert(tostring(err_sales):match("Timeout"), "Should NOT find 'sales.Order' (Denied implicitly)")

    -- 2. Views
    local found_view =
      test_utils.wait_for_cache_content("dbo.PublicData", { type = "View", timeout = 1000, debug = true })
    assert(found_view, "Should find 'dbo.PublicData' (Implicitly allowed)")

    local status_secret, err_secret =
      pcall(test_utils.wait_for_cache_content, "security.Secrets", { type = "View", timeout = 500, debug = true })
    assert(status_secret == false, "Should have timed out (failed) finding 'security.Secrets'")
    assert(tostring(err_secret):match("Timeout"), "Should NOT find 'security.Secrets' (Denied explicitly)")

    -- 3. Sprocs
    local found_api =
      test_utils.wait_for_cache_content("api.GetThings", { type = "StoredProcedure", timeout = 1000, debug = true })
    assert(found_api, "Should find 'api.GetThings' (Allowed)")

    local status_proc, err_proc = pcall(
      test_utils.wait_for_cache_content,
      "dbo.DoInternal",
      { type = "StoredProcedure", timeout = 500, debug = true }
    )
    assert(status_proc == false, "Should have timed out (failed) finding 'dbo.DoInternal'")
    assert(tostring(err_proc):match("Timeout"), "Should NOT find 'dbo.DoInternal' (Denied implicitly)")
  end,
}
