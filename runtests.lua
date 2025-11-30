local function setup_env()
	vim.opt.rtp:prepend(vim.loop.cwd())

	vim.opt.swapfile = false
	vim.opt.shadafile = "NONE"
	vim.o.completeopt = "menu,menuone,noselect,noinsert"
	vim.opt.shortmess:append("c")

	vim.lsp.log.set_level(vim.log.levels.DEBUG)
end

local function print_msg(msg)
	io.stdout:write(msg .. "\n")
end

local function copy_state_folder()
	if vim.env.GITHUB_ACTIONS ~= "true" then return end

	local src = vim.fn.stdpath("state")
	local dst = "nvim-state-dump"
	print_msg("Dumping nvim state from: " .. src)

	if vim.fn.has("win32") == 1 then
		vim.fn.system({ "xcopy", "/E", "/I", "/Y", src, dst })
	else
		vim.fn.system({ "cp", "-r", src, dst })
	end
end

--- Extract filter string from CLI args
--- Usage: nvim -u runtests.lua --headless -- "hover"
local function get_test_filter()
	for i = #vim.v.argv, 1, -1 do
		local arg = vim.v.argv[i]
		if not arg:match("^-") and not arg:match("runtests.lua") and not arg:match("nvim") then
			return arg
		end
	end
	return nil
end

--- Automatically find all the spec files in tests/
---@return table
local function discover_tests()
	local tests = {}
	local tests_path = vim.fs.joinpath(vim.loop.cwd(), "tests")

	for name, type in vim.fs.dir(tests_path) do
		if type == "file" and name:match("_spec%.lua$") then
			local require_path = "tests." .. name:gsub("%.lua$", "")
			table.insert(tests, require_path)
		end
	end

	table.sort(tests)

	local filter = get_test_filter()
	if filter then
		print_msg(">>> Filtering tests by: '" .. filter .. "'")
	end

	-- allows for specific ordering where needed
	local ordered = {}
	local others = {}

	for _, t in ipairs(tests) do
		if t:find("download_spec") then
			table.insert(ordered, 1, t)
		elseif t:find("edit_connections_spec") then
			table.insert(ordered, #ordered + 1, t)
		else
			if not filter or t:find(filter) then
				table.insert(others, t)
			end
		end
	end

	for _, t in ipairs(others) do table.insert(ordered, t) end

	return ordered
end

local function run_suite()
	setup_env()
	local test_files = discover_tests()
	local failures = {}

	coroutine.resume(coroutine.create(function()
		print_msg("=== Starting Test Suite ( " .. #test_files .. " files) ===")

		for _, import_path in ipairs(test_files) do
			local test_module = require(import_path)

			if test_module.run_test_async then
				print_msg("\n--- Running: ".. (test_module.test_name or import_path) .. " ---")
				local success, err = pcall(test_module.run_test_async)

				if not success then
					print_msg("\nFAILED: " .. tostring(err))
					table.insert(failures, import_path)
				else
					print_msg("\nPASSED")
				end
			end

			collectgarbage("collect")
			local co = coroutine.running()
			vim.defer_fn(function() coroutine.resume(co) end, 20)
			coroutine.yield()
		end

		print_msg("\n=== Suite Completed ===")
		if #failures > 0 then
			print_msg("Failure (" .. tostring(#failures) .. "):")
			for _, failed_test in ipairs(failures) do
				print_msg("  - " .. failed_test)
			end
		else
			print_msg("All (" .. tostring(#test_files) .. ") tests passed.")
		end

		local clients = vim.lsp.get_clients({ name = "mssql_ls" })
		if #clients > 0 then
			print_msg("Shutting down " .. #clients .. " LSP client(s)...")
			for _, client in ipairs(clients) do
				client:stop(true)
			end
		end

		if #failures > 0 then
			copy_state_folder()
			vim.cmd("cquit")
		else
			vim.cmd("qa!")
		end
	end))
end

run_suite()
