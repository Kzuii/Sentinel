--!strict

--[[
    View
    @kzui
]]

local Delta = require(script.Parent.Parent.Delta)
local None = require(script.Parent.Parent.None)

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

local View = {}
View.__index = View

function View.new(id: number, name: string): View
	return setmetatable({
		id = id,
		name = name,
		state = {},
		_subscriptions = {}, -- { [string] -> { ChangeCallback } }
		_anyChangeCallbacks = {}, -- { AnyChangeCallback }
		_destroyCallbacks = {}, -- { DestroyCallback }
		_readyCallbacks = {}, -- { ReadyCallback }
		_ready = false,
		_destroyed = false,
	}, View) :: View
end

local function makeConnection(callbacks: { () -> () }, callback: () -> ()): Connection
	table.insert(callbacks, callback)
	local conn = {
		Disconnect = function(self: Connection)
			local idx = table.find(callbacks, callback)
			if idx then
				table.remove(callbacks, idx)
			end
		end,
	}
	return conn
end

function View:onChange(path: string, callback: (newValue: any) -> ()): Connection
	if self._subscriptions[path] == nil then
		self._subscriptions[path] = {}
	end
	return makeConnection(self._subscriptions[path], callback)
end

function View:onAnyChange(callback: (path: string, newValue: any, isRemoved: boolean) -> ()): Connection
	return makeConnection(self._anyChangeCallbacks, callback)
end

function View:onDestroy(callback: () -> ()): Connection
	return makeConnection(self._destroyCallbacks, callback)
end

function View:onReady(callback: () -> ()): Connection
	return makeConnection(self._readyCallbacks, callback)
end

function View:get(path: string): any
	-- Support dot-path access: "a.b.c"
	local current: any = self.state
	for segment in string.gmatch(path, "[^%.]+") do
		if typeof(current) ~= "table" then
			return nil
		end
		current = current[segment]
	end
	return current
end

-- Collect all changed dot-paths from a patch.
-- e.g. { a = { b = 1 } } -> { "a", "a.b", "a.b.1" } — but we only care about
-- table-key paths, not array indices (string keys only).
local function collectChangedPaths(patch: { [string]: any }, prefix: string, paths: { [string]: boolean })
	for key, value in patch do
		local path = prefix == "" and key or (prefix .. "." .. key)
		paths[path] = true
		if value == None then
			-- Removal — no children to recurse
		elseif typeof(value) == "table" then
			collectChangedPaths(value, path, paths)
		end
	end
end

-- Resolve which subscriptions are affected by a set of changed paths.
-- Walks up the path segments: "a.b.c" -> check "a.b.c", "a.b", "a".
local function resolveAffectedSubs(paths: { [string]: boolean }, subscriptions: { [string]: { () -> () } }): { [string]: boolean }
	local affected = {}
	for path in paths do
		-- Walk up: "a.b.c" -> "a.b.c", "a.b", "a"
		local segments = string.split(path, ".")
		for i = #segments, 1, -1 do
			local subPath = table.concat(segments, ".", 1, i)
			if subscriptions[subPath] ~= nil then
				affected[subPath] = true
			end
		end
	end
	return affected
end

-- Apply a snapshot or delta patch to this view.
function View:_applyPatch(patch: { [string]: any })
	-- Collect changed paths before applying
	local changedPaths: { [string]: boolean } = {}
	collectChangedPaths(patch, "", changedPaths)

	-- Apply the patch
	Delta.apply(self.state, patch)

	-- Resolve affected subscriptions (coalesced: each fires once per flush)
	local affected = resolveAffectedSubs(changedPaths, self._subscriptions)

	-- Fire affected subscriptions
	for subPath in affected do
		local callbacks = self._subscriptions[subPath]
		if callbacks then
			local value = self:get(subPath)
			for _, cb in callbacks do
				cb(value)
			end
		end
	end

	-- Fire any-change callbacks
	if #self._anyChangeCallbacks > 0 then
		for path in changedPaths do
			local value = self:get(path)
			local isRemoved = value == nil
			for _, cb in self._anyChangeCallbacks do
				cb(path, value, isRemoved)
			end
		end
	end
end

function View:_applySnapshot(state: { [string]: any })
	-- Full replacement
	self.state = state

	-- Fire ready if first snapshot
	if not self._ready then
		self._ready = true
		for _, cb in self._readyCallbacks do
			cb()
		end
	end

	-- Fire all subscriptions with current values
	for subPath, callbacks in self._subscriptions do
		local value = self:get(subPath)
		for _, cb in callbacks do
			cb(value)
		end
	end

	-- Fire any-change callbacks for all top-level keys
	if #self._anyChangeCallbacks > 0 then
		for key in self.state do
			for _, cb in self._anyChangeCallbacks do
				cb(key, self.state[key], false)
			end
		end
	end
end

function View:_destroy()
	self._destroyed = true
	for _, cb in self._destroyCallbacks do
		cb()
	end
	table.clear(self._subscriptions)
	table.clear(self._anyChangeCallbacks)
	table.clear(self._destroyCallbacks)
	table.clear(self._readyCallbacks)
end

return View
