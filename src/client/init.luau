--!strict

--[[
    Client
    @kzui
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local View = require(script.View)
local Serializer = require(script.Parent.Serializer)

local WIRE_VERSION = 0x01

local MSG_SNAPSHOT = 0x01
local MSG_DELTA = 0x02
local MSG_SYNC_REQUEST = 0x03
local MSG_DESTROY = 0x04

local Client = {}

local _remote: RemoteEvent?
local _views: { [number]: View.View } = {}
local _initialized = false

function Client.init(config: { remoteName: string? })
	assert(not _initialized, "Sentinel.Client.init already called")
	_initialized = true

	local name = config.remoteName or "SentinelRemote"
	_remote = ReplicatedStorage:WaitForChild(name) :: RemoteEvent

	_remote.OnClientEvent:Connect(function(data: buffer, dataLength: number?)
		if typeof(data) ~= "buffer" then
			return
		end

		local len = dataLength or buffer.len(data)
		if len < 1 then
			return
		end

		-- Read version byte
		local version = buffer.readu8(data, 0)
		if version ~= WIRE_VERSION then
			warn(`[sentinel] Unsupported wire version: {version}`)
			return
		end

		local offset = 1
		while offset < len do
			if offset + 5 > len then
				break
			end

			local containerId = buffer.readu32(data, offset)
			offset += 4
			local msgType = buffer.readu8(data, offset)
			offset += 1
			local payloadSize = buffer.readu32(data, offset)
			offset += 4

			if offset + payloadSize > len then
				warn(`[sentinel] Truncated message for container {containerId}`)
				break
			end

			if msgType == MSG_DESTROY then
				local view = _views[containerId]
				if view then
					view:_destroy()
					_views[containerId] = nil
				end
				-- No payload for destroy
			elseif msgType == MSG_SNAPSHOT then
				local payloadStart = offset
				-- Check for name prefix (first 4 bytes could be name length)
				-- The server includes the name only on the first snapshot.
				-- We detect it by checking if the first tag byte is TAG_TABLE (0x05).
				-- If not, it's a name string prefix.
				local name: string? = nil
				if payloadSize >= 4 then
					local firstTag = buffer.readu8(data, offset)
					if firstTag ~= Serializer.TAG_TABLE then
						-- Name prefix present
						local nameLen = buffer.readu32(data, offset)
						offset += 4
						name = buffer.readstring(data, offset, nameLen)
						offset += nameLen
					end
				end

				local state, newOffset = Serializer.unpack(data, offset)
				offset = newOffset

				local view = _views[containerId]
				if not view then
					view = View.new(containerId, name or "")
					_views[containerId] = view
				end
				view:_applySnapshot(state)
			elseif msgType == MSG_DELTA then
				local patch, newOffset = Serializer.unpack(data, offset)
				offset = newOffset

				local view = _views[containerId]
				if view then
					view:_applyPatch(patch)
				end
			else
				warn(`[sentinel] Unknown message type: {msgType}`)
				offset += payloadSize
			end
		end
	end)

	-- Send initial sync request
	local syncBuf = buffer.create(1)
	buffer.writeu8(syncBuf, 0, MSG_SYNC_REQUEST)
	_remote:FireServer(syncBuf)
end

function Client.getView(containerId: number): View.View?
	return _views[containerId]
end

function Client.getViewByName(name: string): View.View?
	for _, view in _views do
		if view.name == name then
			return view
		end
	end
	return nil
end

return Client
