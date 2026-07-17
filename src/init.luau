--!strict

--[[
    sentinel
    @kzui
]]

local None = require(script.None)
local Types = require(script.Types)
local Delta = require(script.Delta)
local Serializer = require(script.Serializer)
local Server = require(script.Server)
local Client = require(script.Client)

local Sentinel = {
	None = None,
	Types = Types,
	Delta = Delta,
	Serializer = Serializer,
	Server = Server,
	Client = Client,
}

return Sentinel
