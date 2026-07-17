--!strict

--[[
    Delta vs Naive Benchmark
    @kzui
]]

-- This script benchmarks the delta encoder against a naive full-resend approach.
-- Run it in a Roblox Studio server context to get reproducible numbers.

local Sentinel = require(game:GetService("ReplicatedStorage").sentinel)
local Delta = Sentinel.Delta
local Serializer = Sentinel.Serializer

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

-- Simulated game state with nested tables, scalars, and Vector3s.
local function makeState(): { [string]: any }
	return {
		score = 0,
		round = 1,
		timeLeft = 60,
		players = {
			alice = { health = 100, position = Vector3.new(0, 0, 0), alive = true },
			bob = { health = 85, position = Vector3.new(10, 0, 5), alive = true },
			charlie = { health = 50, position = Vector3.new(-5, 0, 20), alive = false },
		},
		settings = {
			difficulty = "normal",
			maxPlayers = 16,
			friendlyFire = false,
		},
	}
end

-- Apply a small random change to the state (simulating per-frame writes).
local function applyRandomChange(state: { [string]: any })
	local players = state.players
	local playerKeys = {}
	for k in players do
		table.insert(playerKeys, k)
	end
	local randomPlayer = playerKeys[math.random(1, #playerKeys)]
	local changeType = math.random(1, 3)
	if changeType == 1 then
		players[randomPlayer].health = math.random(0, 100)
	elseif changeType == 2 then
		players[randomPlayer].position = Vector3.new(
			math.random(-50, 50),
			math.random(0, 10),
			math.random(-50, 50)
		)
	elseif changeType == 3 then
		players[randomPlayer].alive = math.random() > 0.5
	end
end

local FRAMES = 1000
local WARMUP = 100

-- Warm up
local warmupState = makeState()
local warmupSent = deepClone(warmupState)
for _ = 1, WARMUP do
	applyRandomChange(warmupState)
	local patch = Delta.diff(warmupSent, warmupState)
	Delta.apply(warmupSent, patch)
end

-- Benchmark: Delta path
local deltaState = makeState()
local deltaSent = deepClone(deltaState)
local deltaTotalBytes = 0
local deltaStartTime = os.clock()

for _ = 1, FRAMES do
	applyRandomChange(deltaState)
	local patch = Delta.diff(deltaSent, deltaState)
	if next(patch) ~= nil then
		local buf = Serializer.serialize(patch)
		deltaTotalBytes += buffer.len(buf)
		Delta.apply(deltaSent, patch)
	end
end

local deltaElapsed = os.clock() - deltaStartTime

-- Benchmark: Naive full-resend path
local naiveState = makeState()
local naiveTotalBytes = 0
local naiveStartTime = os.clock()

for _ = 1, FRAMES do
	applyRandomChange(naiveState)
	local buf = Serializer.serialize(naiveState)
	naiveTotalBytes += buffer.len(buf)
end

local naiveElapsed = os.clock() - naiveStartTime

-- Results
print("\n=== Delta vs Naive Benchmark ===")
print(string.format("Frames: %d (warmup: %d)", FRAMES, WARMUP))
print()
print(string.format("Delta:  %8.3f ms total | %6.1f us/frame | %8d bytes total | %7.1f bytes/frame",
	deltaElapsed * 1000,
	deltaElapsed / FRAMES * 1e6,
	deltaTotalBytes,
	deltaTotalBytes / FRAMES))
print(string.format("Naive:  %8.3f ms total | %6.1f us/frame | %8d bytes total | %7.1f bytes/frame",
	naiveElapsed * 1000,
	naiveElapsed / FRAMES * 1e6,
	naiveTotalBytes,
	naiveTotalBytes / FRAMES))
print()
print(string.format("Bandwidth savings: %.1f%%", (1 - deltaTotalBytes / naiveTotalBytes) * 100))
print(string.format("Overhead: %.1f%%", (deltaElapsed / naiveElapsed - 1) * 100))
