local test_utils = require("tests.utils")

return {
    test_name = "Session Router should handle rapid cache refresh spam",
    run_test_async = function()
        -- setup connection (triggers automatic refresh #1)
        local _, _, qm, cleanup = test_utils.test_scaffold({ target_db = "TestDbA" })

        --   In the old implementation, canceling Refresh #1 would unregister the
        --   global LSP handler, rendering Refresh #5 (the active one) deaf to responses.
        print("Simulating rapid refresh spam (5x)...")
        for _ = 1, 5 do
            qm:initialise_cache_async("database", true)
            vim.wait(50)
        end

        -- expect the cache to eventually settle and populate with data from the final session.
        local found = test_utils.wait_for_cache_content("dbo.Person", {
            type = "Table",
            timeout = 30000
        })

        assert(found, "Cache did not populate after spamming refresh. The LSP handler was likely deregistered prematurely.")

        cleanup()
    end,
}
