--!strict

--[[
    Types
    @kzui
]]

-- The None sentinel type. At runtime it is a userdata; Luau's type system
-- cannot express a unique userdata instance, so we use any.
export type NoneSentinel = any

-- A value that can appear in state. String keys only — no numeric/array keys.
export type StateValue = number | string | boolean | Vector3 | State

-- A state tree is a map of string keys to StateValues.
export type State = { [string]: StateValue }

-- A patch is a sparse map of string keys to changed values or None (removal).
export type PatchValue = StateValue | NoneSentinel
export type Patch = { [string]: PatchValue }

-- Wire format message types.
export type MessageType = 0x01 | 0x02 | 0x03 | 0x04

-- Container configuration for server init.
export type ServerConfig = {
	remoteParent: Instance?,
	remoteName: string?,
}

-- Client configuration for client init.
export type ClientConfig = {
	remoteName: string?,
}

-- A change callback receives the new value at the subscribed path.
export type ChangeCallback = (newValue: any) -> ()

-- An any-change callback receives the full dot-path, new value, and removal flag.
export type AnyChangeCallback = (path: string, newValue: any, isRemoved: boolean) -> ()

-- A destroy callback fires when the server destroys the container.
export type DestroyCallback = () -> ()

-- A ready callback fires once when the initial snapshot arrives.
export type ReadyCallback = () -> ()

-- A connection returned from subscription methods.
export type Connection = {
	Disconnect: (self: Connection) -> (),
}

return {}
