--!strict

--[[
    Serializer
    @kzui
]]

local None = require(script.Parent.None)

-- Tag bytes for each supported value type.
local TAG_NONE = 0x00
local TAG_BOOLEAN = 0x01
local TAG_NUMBER = 0x02
local TAG_STRING = 0x03
local TAG_VECTOR3 = 0x04
local TAG_TABLE = 0x05

-- Calculate the byte size needed to serialize a value.
-- Used by serialize() to preallocate an exact-size buffer.
local function calcSize(value: any): number
	if value == None then
		return 1
	end

	local t = typeof(value)

	if t == "boolean" then
		return 2
	elseif t == "number" then
		return 9
	elseif t == "string" then
		return 5 + #value
	elseif t == "Vector3" then
		return 13
	elseif t == "table" then
		local size = 5
		for k, v in value do
			size += 4 + #k + calcSize(v)
		end
		return size
	else
		error(`Unsupported type for serialization: {t}`)
	end
end

-- Pack a value into a buffer at the given offset.
-- The buffer must have sufficient capacity starting at offset.
-- Returns the new offset after writing.
local function pack(value: any, buf: buffer, offset: number): number
	if value == None then
		buffer.writeu8(buf, offset, TAG_NONE)
		return offset + 1
	end

	local t = typeof(value)

	if t == "boolean" then
		buffer.writeu8(buf, offset, TAG_BOOLEAN)
		buffer.writeu8(buf, offset + 1, value and 1 or 0)
		return offset + 2
	elseif t == "number" then
		buffer.writeu8(buf, offset, TAG_NUMBER)
		buffer.writef64(buf, offset + 1, value)
		return offset + 9
	elseif t == "string" then
		buffer.writeu8(buf, offset, TAG_STRING)
		local len = #value
		buffer.writeu32(buf, offset + 1, len)
		buffer.writestring(buf, offset + 5, value)
		return offset + 5 + len
	elseif t == "Vector3" then
		buffer.writeu8(buf, offset, TAG_VECTOR3)
		buffer.writef32(buf, offset + 1, value.X)
		buffer.writef32(buf, offset + 5, value.Y)
		buffer.writef32(buf, offset + 9, value.Z)
		return offset + 13
	elseif t == "table" then
		buffer.writeu8(buf, offset, TAG_TABLE)
		local count = 0
		for _ in value do
			count += 1
		end
		buffer.writeu32(buf, offset + 1, count)
		offset += 5
		for k, v in value do
			local keyLen = #k
			buffer.writeu32(buf, offset, keyLen)
			buffer.writestring(buf, offset + 4, k)
			offset += 4 + keyLen
			offset = pack(v, buf, offset)
		end
		return offset
	else
		error(`Unsupported type for serialization: {t}`)
	end
end

-- Unpack a value from a buffer at the given offset.
-- Returns (value, newOffset).
local function unpack(buf: buffer, offset: number): (any, number)
	local tag = buffer.readu8(buf, offset)
	offset += 1

	if tag == TAG_NONE then
		return None, offset
	elseif tag == TAG_BOOLEAN then
		local val = buffer.readu8(buf, offset) == 1
		return val, offset + 1
	elseif tag == TAG_NUMBER then
		local val = buffer.readf64(buf, offset)
		return val, offset + 8
	elseif tag == TAG_STRING then
		local len = buffer.readu32(buf, offset)
		offset += 4
		local val = buffer.readstring(buf, offset, len)
		return val, offset + len
	elseif tag == TAG_VECTOR3 then
		local x = buffer.readf32(buf, offset)
		local y = buffer.readf32(buf, offset + 4)
		local z = buffer.readf32(buf, offset + 8)
		return Vector3.new(x, y, z), offset + 12
	elseif tag == TAG_TABLE then
		local count = buffer.readu32(buf, offset)
		offset += 4
		local result = {}
		for _ = 1, count do
			local keyLen = buffer.readu32(buf, offset)
			offset += 4
			local key = buffer.readstring(buf, offset, keyLen)
			offset += keyLen
			local value
			value, offset = unpack(buf, offset)
			result[key] = value
		end
		return result, offset
	else
		error(`Unknown tag byte: {tag}`)
	end
end

-- Serialize a value to a buffer. Convenience wrapper for non-hot-path use.
local function serialize(value: any): buffer
	local size = calcSize(value)
	local buf = buffer.create(size)
	pack(value, buf, 0)
	return buf
end

-- Deserialize a value from a buffer. Convenience wrapper for non-hot-path use.
local function deserialize(buf: buffer): any
	local value, _ = unpack(buf, 0)
	return value
end

return {
	pack = pack,
	unpack = unpack,
	serialize = serialize,
	deserialize = deserialize,
	calcSize = calcSize,

	-- Expose tag constants for the envelope encoder.
	TAG_NONE = TAG_NONE,
	TAG_BOOLEAN = TAG_BOOLEAN,
	TAG_NUMBER = TAG_NUMBER,
	TAG_STRING = TAG_STRING,
	TAG_VECTOR3 = TAG_VECTOR3,
	TAG_TABLE = TAG_TABLE,
}
