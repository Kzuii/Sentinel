--!strict

--[[
    Container
    @kzui
]]

local Delta = require(script.Parent.Parent.Delta)
local None = require(script.Parent.Parent.None)
local Serializer = require(script.Parent.Parent.Serializer)

local TAG_TABLE = Serializer.TAG_TABLE

-- Wire message types
local MSG_SNAPSHOT = 0x01
local MSG_DELTA = 0x02
local MSG_DESTROY = 0x04

local WIRE_VERSION = 0x01

-- Deep-clone only the changed subtree. Scalars are direct assignment (zero alloc).
-- Tables are cloned recursively. Only called on dirty keys — unchanged branches never visited.
local function cloneChanged(value: any): any
	if typeof(value) == "table" then
		local copy = {}
		for k, v in value do
			copy[k] = cloneChanged(v)
		end
		return copy
	end
	return value
end

-- Compute the serialized byte size of a container message (without envelope header).
local function calcPayloadSize(value: any, messageType: number, includeName: boolean, name: string?): number
	local size = 0
	if messageType == MSG_DESTROY then
		return 0
	end
	if includeName and name then
		size += 4 + #name
	end
	size += Serializer.calcSize(value)
	return size
end

export type Container = {
	id: number,
	name: string,
	scope: "global" | { Player },
	_state: { [string]: any },
	_lastSent: { [string]: any },
	_dirty: { [string]: boolean },
	_destroyed: boolean,
	_needsSnapshot: { [Player]: boolean } | boolean,
	set: (self: Container, key: string, value: any) -> (),
	remove: (self: Container, key: string) -> (),
	mutate: (self: Container, fn: (state: { [string]: any }) -> ()) -> (),
	get: (self: Container, key: string) -> any,
	destroy: (self: Container) -> (),
}

local Container = {}
Container.__index = Container

function Container.new(id: number, name: string, initialState: { [string]: any }, scope: "global" | { Player }): Container
	return setmetatable({
		id = id,
		name = name,
		scope = scope,
		_state = table.clone(initialState),
		_lastSent = {},
		_dirty = {},
		_destroyed = false,
		_needsSnapshot = if scope == "global" then true else {},
	}, Container) :: Container
end

function Container:set(key: string, value: any)
	assert(not self._destroyed, "Cannot write to destroyed container: " .. self.name)
	self._state[key] = value
	self._dirty[key] = true
end

function Container:remove(key: string)
	assert(not self._destroyed, "Cannot remove from destroyed container: " .. self.name)
	self._state[key] = nil
	self._dirty[key] = true
end

function Container:mutate(fn: (state: { [string]: any }) -> ())
	assert(not self._destroyed, "Cannot mutate destroyed container: " .. self.name)
	fn(self._state)
	-- Mark all keys as dirty since we can't know which were touched.
	for k in self._state do
		self._dirty[k] = true
	end
end

function Container:get(key: string): any
	return self._state[key]
end

function Container:destroy()
	self._destroyed = true
end

-- Build the wire message for this container into the shared buffer.
-- Returns the new offset, or nil if this container has nothing to send.
function Container:_flush(buf: buffer, offset: number, player: Player?, isFirstSnapshot: boolean): number?
	if self._destroyed then
		-- Write container message header: id, type, payloadSize
		buffer.writeu32(buf, offset, self.id)
		offset += 4
		buffer.writeu8(buf, offset, MSG_DESTROY)
		offset += 1
		buffer.writeu32(buf, offset, 0)
		offset += 4
		return offset
	end

	local needsSnapshot = false
	if self.scope == "global" then
		needsSnapshot = self._needsSnapshot == true
	else
		needsSnapshot = self._needsSnapshot[player] == true
	end

	if needsSnapshot then
		-- Full snapshot
		local includeName = isFirstSnapshot
		local nameLen = includeName and #self.name or 0
		-- Calc total payload size
		local namePrefix = if includeName then 4 + nameLen else 0
		local payloadSize = namePrefix + Serializer.calcSize(self._state)

		buffer.writeu32(buf, offset, self.id)
		offset += 4
		buffer.writeu8(buf, offset, MSG_SNAPSHOT)
		offset += 1
		-- Write placeholder payloadSize (backfill after serialization)
		local lengthPos = offset
		buffer.writeu32(buf, offset, 0)
		offset += 4

		local payloadStart = offset
		if includeName then
			buffer.writeu32(buf, offset, nameLen)
			offset += 4
			buffer.writestring(buf, offset, self.name)
			offset += nameLen
		end
		offset = Serializer.pack(self._state, buf, offset)

		-- Backfill payloadSize
		buffer.writeu32(buf, lengthPos, offset - payloadStart)

		-- Update lastSent to full clone of current state
		self._lastSent = cloneChanged(self._state)
		if self.scope == "global" then
			self._needsSnapshot = false
		else
			self._needsSnapshot[player] = false
		end
		table.clear(self._dirty)
		return offset
	end

	-- Delta path: only dirty keys
	if next(self._dirty) == nil then
		return nil
	end

	-- Build patch from dirty keys only
	local patch = {}
	for key in self._dirty do
		local oldVal = self._lastSent[key]
		local newVal = self._state[key]
		if newVal == nil then
			if oldVal ~= nil then
				patch[key] = None
			end
		elseif oldVal == nil then
			patch[key] = newVal
		elseif typeof(oldVal) == "table" and typeof(newVal) == "table" then
			local subPatch = Delta.diff(oldVal, newVal)
			if next(subPatch) ~= nil then
				patch[key] = subPatch
			end
		elseif typeof(oldVal) ~= typeof(newVal) then
			patch[key] = newVal
		elseif oldVal ~= newVal then
			patch[key] = newVal
		end
	end

	if next(patch) == nil then
		table.clear(self._dirty)
		return nil
	end

	-- Write message
	buffer.writeu32(buf, offset, self.id)
	offset += 4
	buffer.writeu8(buf, offset, MSG_DELTA)
	offset += 1
	local lengthPos = offset
	buffer.writeu32(buf, offset, 0)
	offset += 4

	local payloadStart = offset
	offset = Serializer.pack(patch, buf, offset)
	buffer.writeu32(buf, lengthPos, offset - payloadStart)

	-- Update lastSent for dirty keys only
	for key in self._dirty do
		self._lastSent[key] = cloneChanged(self._state[key])
	end
	table.clear(self._dirty)
	return offset
end

return Container
