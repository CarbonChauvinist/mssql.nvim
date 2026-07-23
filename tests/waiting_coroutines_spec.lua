local state = require("mssql.state")

return {
  test_name = "Waiting coroutines registry works correctly and respects client ID isolation",
  run_test_async = function()
    state._reset_all_state({ force_all = true })

    local co = coroutine.running()
    local bufnr = 999
    local client_id = 12345
    local method = "query/complete"

    -- Register a waiting coroutine
    state.register_waiting_coroutine(bufnr, method, co, client_id)

    local expected_result = { data = "matched" }

    vim.defer_fn(function()
      -- 1. Try to resume with mismatched client ID (should be ignored)
      state.resume_waiting_coroutine(bufnr, method, { data = "mismatched" }, nil, 54321)

      -- 2. Resume with correct client ID
      state.resume_waiting_coroutine(bufnr, method, expected_result, nil, client_id)
    end, 10)

    -- Yield the coroutine and wait for the resume
    local result, err = coroutine.yield()

    assert(result == expected_result, "Coroutine resumed with incorrect result")
    assert(err == nil, "Coroutine resumed with error")


	-- 3. Verify remove_query_manager purges all pending coroutines for bufnr
	local dummy_co = coroutine.create(function() end)
	state.register_waiting_coroutine(bufnr, "query/complete", dummy_co, client_id)
	state.register_waiting_coroutine(bufnr, "connection/complete", dummy_co, client_id)

	state.remove_query_manager(bufnr)

	state.resume_waiting_coroutine(bufnr, "query/complete", "ignored", nil, client_id)
	assert(coroutine.status(dummy_co) == "suspended", "Coroutines should have been purged by remove_query_manager")
  end,
}
