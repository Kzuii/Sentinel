--!strict

--[[
    Server
    @kzui
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Container = require(script.Container)

local WIRE_VERSION = 0x01
local INITIAL_BUFFER_SIZE = 65536

local Server = {}

local _remote: RemoteEvent?
local _containers: { [number]: Container.Container } = {}
local _nextId: number = 1
local _buf: buffer = buffer.create(INITIAL_BUFFER_SIZE)
local _initialized = false
local _heartbeatConn: RBXScriptConnection?

local function ensureBufferCapacity(required: number)
	if buffer.len(_buf) < required then
		local newSize = buffer.len(_buf)
		while newSize < required do
			newSize *= 2
		end
		_buf = buffer.create(newSize)
	end
end

local function onPlayerAdded(player: Player)
	-- Mark all per-player containers as needing a snapshot for this player.
	for _, container in _containers do
		if container.scope ~= "global" then
			local scope = container.scope :: { Player }
			for _, p in scope do
				if p == player then
					container._needsSnapshot[player] = true
				end
			end
		end
	end
end

function Server.init(config: { remoteParent: Instance?, remoteName: string? })
	assert(not _initialized, "Sentinel.Server.init already called")
	_initialized = true

	local parent = config.remoteParent or ReplicatedStorage
	local name = config.remoteName or "SentinelRemote"

	_remote = Instance.new("RemoteEvent")
	_remote.Name = name
	_remote.Parent = parent

	-- Handle initial sync requests from clients
	_remote.OnServerEvent:Connect(function(player: Player, data: any?)
		-- Validate: data should be a buffer containing [u8 0x03] (sync request)
		if typeof(data) ~= "buffer" then
			return
		end
		if buffer.len(data) < 1 then
			return
		end
		local msgType = buffer.readu8(data, 0)
		if msgType ~= 0x03 then
			return
		end

		-- Mark all global containers as needing a snapshot for this player.
		-- Per-player containers are handled by onPlayerAdded.
		for _, container in _containers do
			if not container._destroyed and container.scope == "global" then
				-- Global containers always send snapshot to new players via the flush loop.
				-- We set a per-player snapshot flag.
				if typeof(container._needsSnapshot) == "table" then
					container._needsSnapshot[player] = true
				end
			end
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

function Server.create(name: string, initialState: { [string]: any }, scope: "global" | { Player }?): Container.Container
	assert(_initialized, "Call Sentinel.Server.init first")
	assert(typeof(name) == "string" and #name > 0, "Container name must be a non-empty string")

	local id = _nextId
	_nextId += 1

	local actualScope = scope or "global"
	local container = Container.new(id, name, initialState, actualScope)
	_containers[id] = container
	return container
end

local function flush()
	-- Calculate total required buffer size.
	-- Envelope: [u8 version] + N * [u32 containerId, u8 msgType, u32 payloadSize, payload...]
	local totalSize = 1 -- version byte

	for _, container in _containers do
		if container._destroyed then
			totalSize += 4 + 1 + 4
		elseif next(container._dirty) ~= nil then
			-- Estimate: at least header + some payload. We'll grow if needed.
			totalSize += 4 + 1 + 4 + 1024
		end
	end

	ensureBufferCapacity(totalSize)

	-- Write version byte
	buffer.writeu8(_buf, 0, WIRE_VERSION)
	local offset = 1

	local activeContainers = {}
	for _, container in _containers do
		table.insert(activeContainers, container)
	end

	for _, container in activeContainers do
		local newOffset = container:_flush(_buf, offset, nil, false)
		if newOffset then
			offset = newOffset
		end
	end

	if offset > 1 then
		-- Send to all players (global scope). Per-player routing is a future enhancement.
		_remote:FireAllClients(_buf, offset)
	end

	-- Clean up destroyed containers
	local toRemove = {}
	for id, container in _containers do
		if container._destroyed then
			table.insert(toRemove, id)
		end
	end
	for _, id in toRemove do
		_containers[id] = nil
	end
end

function Server.startFlushLoop()
	assert(_initialized, "Call Sentinel.Server.init first")
	assert(not _heartbeatConn, "Flush loop already started")
	_heartbeatConn = RunService.Heartbeat:Connect(flush)
end

function Server.stopFlushLoop()
	if _heartbeatConn then
		_heartbeatConn:Disconnect()
		_heartbeatConn = nil
	end
end

return Server
