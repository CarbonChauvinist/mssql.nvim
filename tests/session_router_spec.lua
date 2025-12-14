-- test(spec): add session_router_spec
--
-- - Add `tests/session_router_spec.lua` to verify that rapid calls to `initialise_cache_async(true)` (spamming refresh) do not break the LSP handler registration.
-- - Ensures the new Session Router logic correctly manages multiple concurrent (cancelling) sessions without deregistering the master handler prematurely.
local test_utils = require("tests.utils")

return {
    test_name = "Session Router should handle rapid cache refresh spam",
    run_test_async = function()
        -- 1. Setup connection (Triggers automatic Refresh #1)
        local _, _, qm, cleanup = test_utils.test_scaffold({ target_db = "TestDbA" })

        -- 2. Simulate "Spamming" the refresh command
        -- We trigger 5 forced refreshes in rapid succession.
        -- Failure Mode (Prevention):
        --   In the old implementation, canceling Refresh #1 would unregister the
        --   global LSP handler, rendering Refresh #5 (the active one) deaf to responses.
        print("Simulating rapid refresh spam (5x)...")
        for _ = 1, 5 do
            qm:initialise_cache_async(true)
            -- Small wait to ensure the async request is sent but not completed
            vim.wait(50)
        end

        -- 3. Verification
        -- We expect the cache to eventually settle and populate with data from the final session.
        local found = test_utils.wait_for_cache_content("dbo.Person", {
            type = "Table",
            timeout = 30000
        })

        assert(found, "Cache did not populate after spamming refresh. The LSP handler was likely deregistered prematurely.")

        cleanup()
    end,
}
