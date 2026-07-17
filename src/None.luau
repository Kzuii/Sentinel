--!strict

--[[
    None
    @kzui
]]

-- Unique sentinel value representing "key removal" in patches.
-- Distinguishes "set to nil" from "untouched" in sparse patch tables.
-- Identity-comparable: value == None is true only for this exact instance.
-- typeof(None) is "userdata", which is distinct from all state value types.

local None = newproxy(true)

local metatable = getmetatable(None) :: { [string]: any }
metatable.__tostring = function()
	return "sentinel.None"
end
metatable.__metatable = "The metatable is locked"

return None
