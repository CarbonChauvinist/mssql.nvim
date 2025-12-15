local filter = require("mssql.utils").filter_list

return {
	test_name = "Utils: Filter list should respect Allow/Deny precedence",
	run_test_async = function()
		local items = {
			"master", "model", "msdb", "tempdb",
			"ProjectA_Dev", "ProjectA_Prod", "ProjectA_Backup",
			"ProjectB_Dev"
		}

		local res1 = filter(items, nil, nil)
		assert(#res1 == 8, "Should return all items")

		local res2 = filter(items, { "^ProjectA" }, nil)
		assert(#res2 == 3, "Should only return ProjectA items")

		local res3 = filter(items, nil, { "master", "model", "msdb", "tempdb" })
		assert(#res3 == 4, "Should hide system DBs")
		assert(not vim.tbl_contains(res3, "master"))

		-- give me ProjectA, but not the backup
		local res4 = filter(items, { "^ProjectA" }, { "Backup$" })
		assert(#res4 == 2, "Should return 2 items")
		assert(vim.tbl_contains(res4, "ProjectA_Dev"))
		assert(vim.tbl_contains(res4, "ProjectA_Prod"))
		assert(not vim.tbl_contains(res4, "ProjectA_Backup"), "Deny should override Allow")

		local res5 = filter(items, {}, nil)
		assert(#res5 == 0, "Empty allow list should return nothing")

		local res6 = filter(items, {}, { "master" })
		assert(#res6 == 0, "Empty allow list should still return nothing even if deny list exists")
	end,
}
