--!strict

--[[
    Delta
    @kzui
]]

local None = require(script.Parent.None)

-- Compute the minimal patch from old to new state.
-- Only changed paths appear in the result. Removed keys map to None.
local function diff(old: { [string]: any }, new: { [string]: any }): { [string]: any }
	local patch = {}

	for key, newValue in new do
		local oldValue = old[key]

		if oldValue == nil then
			patch[key] = newValue
		elseif typeof(oldValue) == "table" and typeof(newValue) == "table" then
			local subPatch = diff(oldValue, newValue)
			if next(subPatch) ~= nil then
				patch[key] = subPatch
			end
		elseif typeof(oldValue) ~= typeof(newValue) then
			patch[key] = newValue
		elseif oldValue ~= newValue then
			patch[key] = newValue
		end
	end

	for key in old do
		if new[key] == nil then
			patch[key] = None
		end
	end

	return patch
end

-- Apply a patch to state, mutating in-place.
-- None values remove keys; table values recurse; scalars are set directly.
local function apply(state: { [string]: any }, patch: { [string]: any }): { [string]: any }
	for key, patchValue in patch do
		if patchValue == None then
			state[key] = nil
		elseif typeof(patchValue) == "table" and typeof(state[key]) == "table" then
			apply(state[key], patchValue)
		else
			state[key] = patchValue
		end
	end

	return state
end

return {
	diff = diff,
	apply = apply,
}
