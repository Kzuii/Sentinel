# sentinel

Server-authoritative state replication with delta-compressed patches for Roblox. The server owns truth; the client holds a read-only view that stays in sync through minimal diffs.

## Install

```toml
# wally.toml
[dependencies]
sentinel = "sentinel/sentinel@0.1.0"
```

## Quick Start

### Server

```lua
local Sentinel = require(Packages.sentinel)

Sentinel.Server.init()
Sentinel.Server.startFlushLoop()

local gameState = Sentinel.Server.create("gameState", {
    score = 0,
    round = 1,
    players = {},
})

gameState:set("score", 100)
gameState:set("round", 2)
gameState:remove("players", "disconnectedPlayer")
```

### Client

```lua
local Sentinel = require(Packages.sentinel)

Sentinel.Client.init()

local view = Sentinel.Client.getViewByName("gameState")
view:onReady(function()
    print("Initial state received:", view.state.score)
end)

view:onChange("score", function(newScore)
    print("Score changed:", newScore)
end)

view:onChange("players", function(players)
    print("Players table updated")
end)

view:onDestroy(function()
    print("Container destroyed by server")
end)
```

## API Reference

### Server

| Function | Description |
|---|---|
| `Server.init(config)` | Creates the RemoteEvent and sets up player join handling. |
| `Server.startFlushLoop()` | Starts the Heartbeat flush loop (one flush per frame). |
| `Server.stopFlushLoop()` | Stops the flush loop. |
| `Server.create(name, initialState, scope?)` | Creates a replicated container. Returns a `Container`. |

### Container (Server)

| Method | Description |
|---|---|
| `:set(key, value)` | Sets a top-level key. Marks it dirty for the next flush. |
| `:remove(key)` | Removes a top-level key (sets to nil). Marks it dirty. |
| `:mutate(fn)` | Passes state to a function for complex mutations. Marks all keys dirty. |
| `:get(key)` | Reads the current value of a key. |
| `:destroy()` | Marks the container for destruction. Sends 0x04 on next flush. |

### Client

| Function | Description |
|---|---|
| `Client.init(config)` | Connects to the RemoteEvent and sends initial sync request. |
| `Client.getView(id)` | Gets a view by container ID. |
| `Client.getViewByName(name)` | Gets a view by container name. |

### View (Client)

| Method | Description |
|---|---|
| `:get(path)` | Reads a value by dot-path (e.g. `"players.alice.health"`). |
| `:onChange(path, callback)` | Fires when the path or any descendant changes. Coalesced per-flush. Returns a `Connection`. |
| `:onAnyChange(callback)` | Fires for every changed path. Returns a `Connection`. |
| `:onReady(callback)` | Fires once when the initial snapshot arrives. Returns a `Connection`. |
| `:onDestroy(callback)` | Fires when the server destroys the container. Returns a `Connection`. |

## Architecture

### Why Delta Compression?

When a value changes server-side, only the diff crosses the wire — not the full state tree. On a busy server with 30 players and 60 FPS, sending full state every frame is catastrophic. Sentinel computes the minimal patch between the previous and current state, serializes it into a compact binary buffer, and batches all containers into a single RemoteEvent fire per frame.

### How the None Sentinel Works

The hardest problem in state replication is distinguishing **"this key was set to nil"** from **"this key was untouched."** A naive diff that compares old and new tables sees `nil` in both cases and can't tell them apart.

Sentinel solves this with a unique sentinel value called `None` — a locked userdata instance created via `newproxy(true)`. When a key is removed, the patch contains `patch[key] = None`. When a key is untouched, it simply doesn't appear in the patch.

```lua
local old = { a = 1, b = 2 }
local new = { a = 1 }
local patch = Delta.diff(old, new)
-- patch = { b = None }
-- "b was removed" — not "b is nil and maybe wasn't there before"
```

This is the single most common bug in hand-rolled replication. Every framework that doesn't use an explicit sentinel has this bug latent in it.

### Wire Format

Every frame, the server sends a single buffer over one RemoteEvent:

```
[u8 version] [container messages...]
```

Each container message:

```
[u32 containerId] [u8 msgType] [u32 payloadSize] [payload...]
```

| msgType | Meaning |
|---|---|
| `0x01` | Snapshot — full state, sent on initial sync |
| `0x02` | Delta — minimal patch of changed keys |
| `0x03` | Sync request (client → server only) |
| `0x04` | Destroy — container removed, client should tear down view |

The `payloadSize` is written via a seek-back: the server writes a placeholder `u32`, serializes the payload, then seeks back to fill in the actual length. This avoids double-serialization.

### Coalesced Signal Dispatch

When 5 leaves change under path `"a"`, a subscriber to `"a"` fires **once**, not 5 times. The reconciler collects all changed paths, resolves the set of affected subscriptions by walking up the path tree, and fires each subscription exactly once per flush with the post-patch value.

### Scope Boundary: String Keys Only

v1 supports string keys only — no numeric/array indices. Array support roughly doubles diff complexity (requiring LCS or index-diffing) and wire format overhead. A clean, correct, well-documented string-keyed framework beats a half-working one with arrays. This is a deliberate scope boundary, not an omission.

## Benchmarks

```bash
# Run in Roblox Studio server context
rojo build default.project.json -o benchmark.rbxl
# Run benchmarks/delta_vs_naive.luau
```

## License

MIT