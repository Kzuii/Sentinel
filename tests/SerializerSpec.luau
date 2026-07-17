--!strict

--[[
    SerializerSpec
    @kzui
]]

local Sentinel = require(game:GetService("ReplicatedStorage").sentinel)
local Serializer = Sentinel.Serializer
local None = Sentinel.None

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
	["round-trip number"] = function()
		local buf = Serializer.serialize(42.5)
		local result = Serializer.deserialize(buf)
		assert(result == 42.5, "number should round-trip")
	end,

	["round-trip string"] = function()
		local buf = Serializer.serialize("hello world")
		local result = Serializer.deserialize(buf)
		assert(result == "hello world", "string should round-trip")
	end,

	["round-trip boolean true"] = function()
		local buf = Serializer.serialize(true)
		local result = Serializer.deserialize(buf)
		assert(result == true, "boolean true should round-trip")
	end,

	["round-trip boolean false"] = function()
		local buf = Serializer.serialize(false)
		local result = Serializer.deserialize(buf)
		assert(result == false, "boolean false should round-trip")
	end,

	["round-trip Vector3"] = function()
		-- Vector3 components are f32 internally, so f32 round-trip is lossless.
		local v = Vector3.new(1.5, 2.5, 3.5)
		local buf = Serializer.serialize(v)
		local result = Serializer.deserialize(buf)
		assert(result == v, "Vector3 should round-trip (f32 components are lossless)")
	end,

	["round-trip Vector3 with zero components"] = function()
		local v = Vector3.new(0, 0, 0)
		local buf = Serializer.serialize(v)
		local result = Serializer.deserialize(buf)
		assert(result == v, "Vector3 with zeros should round-trip")
	end,

	["round-trip None"] = function()
		local buf = Serializer.serialize(None)
		local result = Serializer.deserialize(buf)
		assert(result == None, "None should round-trip with identity preserved")
	end,

	["round-trip nested table"] = function()
		local state = {
			health = 100,
			name = "alice",
			alive = true,
			pos = Vector3.new(10, 20, 30),
			stats = {
				strength = 15,
				agility = 12,
				tags = {
					role = "tank",
					level = 5,
				},
			},
		}
		local buf = Serializer.serialize(state)
		local result = Serializer.deserialize(buf)
		assert(deepEqual(result, state), "nested table should round-trip")
	end,

	["round-trip empty table"] = function()
		local buf = Serializer.serialize({})
		local result = Serializer.deserialize(buf)
		assert(typeof(result) == "table", "empty table should deserialize as table")
		assert(next(result) == nil, "empty table should remain empty")
	end,

	["round-trip table with None values (patch)"] = function()
		local patch = {
			health = 80,
			stamina = None,
			name = "bob",
		}
		local buf = Serializer.serialize(patch)
		local result = Serializer.deserialize(buf)
		assert(result.health == 80, "scalar value in patch should round-trip")
		assert(result.stamina == None, "None value in patch should round-trip")
		assert(result.name == "bob", "string value in patch should round-trip")
	end,

	["edge case: empty string"] = function()
		local buf = Serializer.serialize("")
		local result = Serializer.deserialize(buf)
		assert(result == "", "empty string should round-trip")
	end,

	["edge case: zero"] = function()
		local buf = Serializer.serialize(0)
		local result = Serializer.deserialize(buf)
		assert(result == 0, "zero should round-trip")
	end,

	["edge case: very large number"] = function()
		local buf = Serializer.serialize(1e308)
		local result = Serializer.deserialize(buf)
		assert(result == 1e308, "very large number should round-trip")
	end,

	["edge case: negative number"] = function()
		local buf = Serializer.serialize(-123.456)
		local result = Serializer.deserialize(buf)
		assert(result == -123.456, "negative number should round-trip")
	end,

	["edge case: very long string"] = function()
		local s = string.rep("x", 10000)
		local buf = Serializer.serialize(s)
		local result = Serializer.deserialize(buf)
		assert(result == s, "very long string should round-trip")
	end,

	["edge case: NaN"] = function()
		local buf = Serializer.serialize(0 / 0)
		local result = Serializer.deserialize(buf)
		-- NaN ~= NaN, so we check via string representation.
		assert(tostring(result) == tostring(0 / 0), "NaN should round-trip")
	end,

	["edge case: positive infinity"] = function()
		local buf = Serializer.serialize(math.huge)
		local result = Serializer.deserialize(buf)
		assert(result == math.huge, "positive infinity should round-trip")
	end,

	["edge case: negative infinity"] = function()
		local buf = Serializer.serialize(-math.huge)
		local result = Serializer.deserialize(buf)
		assert(result == -math.huge, "negative infinity should round-trip")
	end,

	["edge case: negative zero preserves sign bit"] = function()
		-- -0 == 0 is true in Luau, so == proves nothing.
		-- Verify the sign bit is preserved by comparing raw f64 bytes.
		local packed = Serializer.serialize(-0.0)
		local unpacked = Serializer.deserialize(packed)
		local repacked = Serializer.serialize(unpacked)
		assert(buffer.len(packed) == buffer.len(repacked), "buffer lengths should match")
		for i = 1, buffer.len(packed) do
			assert(
				buffer.readu8(packed, i - 1) == buffer.readu8(repacked, i - 1),
				string.format("byte mismatch at offset %d", i - 1)
			)
		end
		-- The last byte of f64 -0.0 has the sign bit set (0x80).
		assert(buffer.readu8(packed, 8) == 0x80, "sign bit should be set for -0.0")
	end,

	["calcSize matches actual packed size"] = function()
		local value = { a = 1, b = "hello", c = { x = 10 } }
		local expectedSize = Serializer.calcSize(value)
		local buf = Serializer.serialize(value)
		assert(buffer.len(buf) == expectedSize, "calcSize should match actual buffer size")
	end,

	["pack/unpack with offset"] = function()
		-- Verify the offset-based API works correctly for hot-path use.
		local buf = buffer.create(256)
		local endOffset = Serializer.pack(42.5, buf, 0)
		assert(endOffset == 9, "pack should return correct offset for number")
		local value, newOffset = Serializer.unpack(buf, 0)
		assert(value == 42.5, "unpack should return correct value")
		assert(newOffset == 9, "unpack should return correct offset")
	end,
}
