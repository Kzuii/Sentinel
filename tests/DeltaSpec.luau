--!strict

--[[
    DeltaSpec
    @kzui
]]

local Sentinel = require(game:GetService("ReplicatedStorage").sentinel)
local Delta = Sentinel.Delta
local None = Sentinel.None

local function deepClone(value: any): any
	if typeof(value) == "table" then
		local copy = {}
		for k, v in value do
			copy[k] = deepClone(v)
		end
		return copy
	end
	return value
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if typeof(a) ~= typeof(b) then
		return false
	end
	if typeof(a) == "table" then
		for k, v in a do
			if not deepEqual(v, b[k]) then
				return false
			end
		end
		for k in b do
			if a[k] == nil and b[k] ~= nil then
				return false
			end
		end
		return true
	end
	return false
end

return {
	["round-trip: apply(diff(old, new)) equals new"] = function()
		local old = { a = 1, b = "hello", c = { x = 10, y = 20 } }
		local new = { a = 2, b = "hello", c = { x = 10, y = 30 }, d = true }
		local patch = Delta.diff(old, new)
		local result = Delta.apply(deepClone(old), patch)
		assert(deepEqual(result, new), "round-trip should converge to new state")
	end,

	["minimal patch: identical states produce empty patch"] = function()
		local state = { a = 1, b = "hello", c = { x = 10, y = 20 } }
		local patch = Delta.diff(state, deepClone(state))
		assert(next(patch) == nil, "patch should be empty for identical states")
	end,

	["nested diff: changing a deep leaf produces only that path"] = function()
		local old = { a = { b = { c = 1, d = 2 } } }
		local new = { a = { b = { c = 99, d = 2 } } }
		local patch = Delta.diff(old, new)
		-- patch should be { a = { b = { c = 99 } } }
		assert(patch.a ~= nil, "patch should contain key a")
		assert(patch.a.b ~= nil, "patch.a should contain key b")
		assert(patch.a.b.c == 99, "patch.a.b.c should be 99")
		assert(patch.a.b.d == nil, "patch.a.b should not contain unchanged key d")
	end,

	["None/nil-removal: removing a key produces None in patch"] = function()
		local old = { a = 1, b = 2 }
		local new = { a = 1 }
		local patch = Delta.diff(old, new)
		assert(patch.b == None, "removed key should map to None in patch")
	end,

	["None/nil-removal: applying None removes the key"] = function()
		local state = { a = 1, b = 2 }
		local patch = { b = None }
		Delta.apply(state, patch)
		assert(state.a == 1, "unchanged key should remain")
		assert(state.b == nil, "removed key should be nil after apply")
	end,

	["type change: table to scalar produces full replacement"] = function()
		local old = { a = { x = 1, y = 2 } }
		local new = { a = 42 }
		local patch = Delta.diff(old, new)
		assert(patch.a == 42, "type change should produce full replacement, not recursive diff")
		assert(typeof(patch.a) == "number", "replacement value should be the scalar")
	end,

	["type change: scalar to table produces full replacement"] = function()
		local old = { a = 42 }
		local new = { a = { x = 1, y = 2 } }
		local patch = Delta.diff(old, new)
		assert(typeof(patch.a) == "table", "scalar to table should produce full table in patch")
		assert(patch.a.x == 1, "replacement table should have correct values")
		assert(patch.a.y == 2, "replacement table should have correct values")
	end,

	["empty sub-patch: unchanged nested table is omitted from parent patch"] = function()
		local old = { a = { x = 1 }, b = 2 }
		local new = { a = { x = 1 }, b = 3 }
		local patch = Delta.diff(old, new)
		assert(patch.a == nil, "unchanged nested table should not appear in patch")
		assert(patch.b == 3, "changed scalar should appear in patch")
	end,

	["adding a key produces the value in patch"] = function()
		local old = { a = 1 }
		local new = { a = 1, b = "new" }
		local patch = Delta.diff(old, new)
		assert(patch.b == "new", "added key should appear in patch with its value")
	end,

	["adding a nested table produces the full table in patch"] = function()
		local old = { a = 1 }
		local new = { a = 1, b = { x = 10, y = 20 } }
		local patch = Delta.diff(old, new)
		assert(typeof(patch.b) == "table", "added table should appear as full table in patch")
		assert(patch.b.x == 10, "added table should have correct values")
		assert(patch.b.y == 20, "added table should have correct values")
	end,

	["round-trip with removal and addition simultaneously"] = function()
		local old = { a = 1, b = 2, c = { x = 10 } }
		local new = { a = 1, c = { x = 10, y = 20 }, d = "new" }
		local patch = Delta.diff(old, new)
		local result = Delta.apply(deepClone(old), patch)
		assert(deepEqual(result, new), "round-trip with mixed operations should converge")
	end,

	["empty old state: all keys are additions"] = function()
		local old = {}
		local new = { a = 1, b = "hello" }
		local patch = Delta.diff(old, new)
		assert(patch.a == 1, "all keys should be additions from empty old")
		assert(patch.b == "hello", "all keys should be additions from empty old")
	end,

	["empty new state: all keys are removals"] = function()
		local old = { a = 1, b = "hello" }
		local new = {}
		local patch = Delta.diff(old, new)
		assert(patch.a == None, "all keys should be removals to empty new")
		assert(patch.b == None, "all keys should be removals to empty new")
	end,

	["Vector3 values are compared by components"] = function()
		local old = { pos = Vector3.new(1, 2, 3) }
		local new = { pos = Vector3.new(1, 2, 99) }
		local patch = Delta.diff(old, new)
		assert(patch.pos == Vector3.new(1, 2, 99), "changed Vector3 should appear in patch")
	end,

	["Vector3 unchanged: omitted from patch"] = function()
		local old = { pos = Vector3.new(1, 2, 3), a = 1 }
		local new = { pos = Vector3.new(1, 2, 3), a = 2 }
		local patch = Delta.diff(old, new)
		assert(patch.pos == nil, "unchanged Vector3 should not appear in patch")
		assert(patch.a == 2, "changed scalar should appear in patch")
	end,

	["boolean values are compared correctly"] = function()
		local old = { flag = true }
		local new = { flag = false }
		local patch = Delta.diff(old, new)
		assert(patch.flag == false, "changed boolean should appear in patch")
	end,

	["boolean unchanged: omitted from patch"] = function()
		local old = { flag = true, a = 1 }
		local new = { flag = true, a = 2 }
		local patch = Delta.diff(old, new)
		assert(patch.flag == nil, "unchanged boolean should not appear in patch")
	end,
}
