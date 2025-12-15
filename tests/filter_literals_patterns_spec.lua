local filter = require("mssql.utils").filter_list

return {
	test_name = "Utils: Filter list should discern between literals and patterns",
	run_test_async = function()
		local items = { "TestDb", "TestDb_Backup", "my-db", "my.db", "OtherDb" }

		local res1 = filter(items, { "TestDb" }, nil)
		assert(#res1 == 1, "Should be exact match only")
		assert(res1[1] == "TestDb")

		local res2 = filter(items, { "TestDb.*"}, nil)
		assert(#res2 == 2, "'TestDb.*' should pattern match both TestDb variants")

		-- exact match with special chars
		-- we do not treat `-` or `.` as special characters
		local res3 = filter(items, { "my-db" }, nil)
		assert(#res3 == 1)
		assert(res3[1] == "my-db", "'-' should not be treated as a special character.")

		local res4 = filter(items, { "my.db" }, nil)
		assert(#res4 == 1)
		assert(res4[1] == "my.db", "'.' should not be treated as a special character")

		local res5 = filter(items, { "^Other" }, nil)
		assert(#res5 == 1)
		assert(res5[1] == "OtherDb", "Special characters should engage lua pattern matching")

		local res6 = filter(items, { "testdb" }, nil)
		assert(#res6 == 1)
		assert(res6[1] == "TestDb", "String literal matches should be case-insensitive.")

		local res7 = filter(items, { "oth.*" }, nil)
		assert(#res7 == 0, "Pattern matches should be case-sensitive")

	end,
}
