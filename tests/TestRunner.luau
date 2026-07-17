--!strict

--[[
    TestRunner
    @kzui
]]

local TestRunner = {}

function TestRunner.run(suiteName: string, tests: { [string]: () -> () }): (number, number)
	local passed = 0
	local failed = 0

	print(string.format("\n=== %s ===", suiteName))

	for testName, testFn in tests do
		local ok, err = pcall(testFn)
		if ok then
			passed += 1
			print(string.format("  PASS: %s", testName))
		else
			failed += 1
			print(string.format("  FAIL: %s — %s", testName, tostring(err)))
		end
	end

	print(string.format("  %d passed, %d failed", passed, failed))
	return passed, failed
end

return TestRunner
