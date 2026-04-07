return {
  test_name = "Picker Adapter Logic",
  run_test_async = function()
    local picker -- Declare once here
    local items = {
      { label = "Table A", nodeType = "Table", picker_path = "Tables/" },
      { label = "Table B", nodeType = "Table", picker_path = "Tables/" },
    }
    local opts = {
      title = "Test Picker",
      keymaps = { ["<M-c>"] = "create" }, -- Intent "create"
    }
    local original_select = vim.ui.select

    -- helper to reset state between tests
    local function cleanup_mocks()
      package.loaded["snacks"] = nil
      package.preload["snacks"] = nil
      package.loaded["fzf-lua"] = nil
      package.preload["fzf-lua"] = nil
      package.loaded["mssql.picker"] = nil -- Force reload the module under test
      vim.ui.select = original_select
    end

    print("--- Test 1: Snacks Path ---")
    cleanup_mocks()

    local snacks_spy_called = false
    local mock_snacks = {
      picker = {
        pick = function(config)
          snacks_spy_called = true
          assert(config.title == "Test Picker", "Snacks: Wrong title")
          local action_def = config.win.input.keys["<M-c>"]
          assert(action_def, "Snacks: Keymap <M-c> not registered")
          local action_name = action_def[1]
          local callback = config.actions[action_name]
          local mock_picker_obj = { close = function() end }
          callback(mock_picker_obj, items[1])
        end,
      },
    }
    package.preload["snacks"] = function()
      return mock_snacks
    end
    package.loaded["snacks"] = mock_snacks

    -- Load the module AFTER mocks are in place
    picker = require("mssql.picker")
    local result_item, result_intent
    picker.pick(items, opts, function(item, intent)
      result_item = item
      result_intent = intent
    end)

    assert(snacks_spy_called, "Snacks picker was not called")
    assert(result_item.label == "Table A", "Snacks: Wrong item returned")
    assert(result_intent == "create", "Snacks: Wrong intent returned")

    print("--- Test 2: Fzf-Lua Path ---")
    cleanup_mocks()

    local fzf_spy_called = false
    local mock_fzf = {
      fzf_exec = function(lines, config)
        fzf_spy_called = true
        assert(lines[1]:match("^1|.*Table A"), "Fzf: Malformed line format: " .. lines[1])
        local callback = config.actions["alt-c"]
        assert(callback, "Fzf: Action 'alt-c' not registered")
        callback({ lines[2] })
      end,
    }
    package.preload["fzf-lua"] = function()
      return mock_fzf
    end
    package.loaded["fzf-lua"] = mock_fzf

    picker = require("mssql.picker")
    result_item, result_intent = nil, nil
    picker.pick(items, opts, function(item, intent)
      result_item = item
      result_intent = intent
    end)

    assert(fzf_spy_called, "Fzf-Lua picker was not called")
    assert(result_item and result_item.label == "Table B", "Fzf: Wrong item returned")
    assert(result_intent == "create", "Fzf: Wrong intent returned")

    print("--- Test 3: Native (Fallback) Path ---")
    cleanup_mocks()

    local select_spy_called = false
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(list, _config, on_choice)
      select_spy_called = true
      assert(#list == 2, "Native: Wrong list size")
      on_choice(list[1])
    end

    -- mock schedule to run immediately for this test
    local original_schedule = vim.schedule
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.schedule = function(fn)
      fn()
    end

    picker = require("mssql.picker")
    result_item, result_intent = nil, nil
    picker.pick(items, opts, function(item, intent)
      result_item = item
      result_intent = intent
    end)

    assert(select_spy_called, "vim.ui.select was not called")
    assert(result_item and result_item.label == "Table A", "Native: Wrong item")
    assert(result_intent == nil, "Native: Intent should be nil")

    -- Final Cleanup
    vim.schedule = original_schedule
    cleanup_mocks()
  end,
}
