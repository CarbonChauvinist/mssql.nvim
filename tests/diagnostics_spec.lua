local test_utils = require("tests.utils")

return {
    test_name = "LSP should publish diagnostics for syntax errors",
    run_test_async = function()
        local buf, _, _, cleanup = test_utils.test_scaffold({ target_db = "tempdb" })

        local query = "SELEC * FROM SomeTable" -- Typo 'SELEC'
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query })

        local diags = {}
        local attempts = 0
        while attempts < 30 do -- Wait up to 3s
            diags = vim.diagnostic.get(buf)
            if #diags > 0 then break end
            test_utils.defer_async(100)
            attempts = attempts + 1
        end

        assert(#diags > 0, "No diagnostics found for invalid SQL")

        local found_error = false
        for _, d in ipairs(diags) do
            if d.message:find("Incorrect syntax near ") then
                found_error = true
                break
            end
        end
        assert(found_error, "Diagnostic message was incorrect. Got: " .. vim.inspect(diags))

        cleanup()
    end,
}
