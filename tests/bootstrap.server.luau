--!strict

--[[
    bootstrap
    @kzui
]]

local TestRunner = require(script.TestRunner)

local totalPassed = 0
local totalFailed = 0

local suites = {
	{ name = "None", tests = require(script.NoneSpec) },
	{ name = "Delta", tests = require(script.DeltaSpec) },
	{ name = "Serializer", tests = require(script.SerializerSpec) },
}

for _, suite in suites do
	local passed, failed = TestRunner.run(suite.name, suite.tests)
	totalPassed += passed
	totalFailed += failed
end

print(string.format("\n=== TOTAL: %d passed, %d failed ===", totalPassed, totalFailed))

if totalFailed > 0 then
	error("Test suite failed!")
end
