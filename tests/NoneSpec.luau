--!strict

--[[
    NoneSpec
    @kzui
]]

local Sentinel = require(game:GetService("ReplicatedStorage").sentinel)
local None = Sentinel.None

return {
	["None == None is true (identity)"] = function()
		assert(None == None, "None should equal itself")
	end,

	["None ~= nil"] = function()
		assert(None ~= nil, "None should not equal nil")
	end,

	["None ~= {}"] = function()
		assert(None ~= {}, "None should not equal an empty table")
	end,

	["None ~= 0"] = function()
		assert(None ~= 0, "None should not equal 0")
	end,

	["None ~= false"] = function()
		assert(None ~= false, "None should not equal false")
	end,

	["None ~= empty string"] = function()
		assert(None ~= "", "None should not equal empty string")
	end,

	["tostring(None) returns sentinel.None"] = function()
		assert(tostring(None) == "sentinel.None", "tostring should return sentinel.None")
	end,

	["typeof(None) is userdata"] = function()
		assert(typeof(None) == "userdata", "typeof should be userdata")
	end,

	["None is falsy in conditions"] = function()
		-- None is a userdata, which is truthy in Luau.
		-- This documents the behavior: you must use == None, not `if value then`.
		assert(not not None, "None is truthy — use explicit == None checks")
	end,
}
