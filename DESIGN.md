# sentinel — Design Note

> **Status:** Wire format settled. Ready for implementation.

## One-line pitch

Server-authoritative state replication with delta-compressed patches over a single RemoteEvent. The server owns truth; the client holds a read-only view that stays in sync through minimal diffs.

---

## Public API

### Server

```lua
local Sentinel = require(Packages.sentinel)

-- Initialize the framework. Creates a RemoteEvent and starts the Heartbeat flush loop.
-- Call once at server startup.
Sentinel.Server.init({
    remoteParent = game:GetService("ReplicatedStorage"),  -- optional, default ReplicatedStorage
    remoteName = "SentinelRemote",                         -- optional, default "SentinelRemote"
})

-- Create a global container (all players receive updates).
local gameState = Sentinel.Server.create("gameState", {
    score = 0,
    round = 1,
    players = {},
})

-- Create a per-player container (only that player receives updates).
local playerData = Sentinel.Server.createForPlayer(player, "playerData", {
    health = 100,
    stamina = 100,
    position = Vector3.new(0, 0, 0),
})

-- Write a single key. Marks the key dirty; flushes on next Heartbeat.
gameState:set("score", 100)

-- Remove a key. Sends None in the next patch.
gameState:remove("tempBuff")

-- Batch multiple writes in one call. All dirty keys flush together.
gameState:mutate(function(state)
    state.score = 200
    state.round = 3
end)

-- Read current state synchronously (server-side query).
local score = gameState:get("score")

-- Destroy a container. Sends a removal notification to clients.
gameState:destroy()
```

### Client

```lua
local Sentinel = require(Packages.sentinel)

-- Initialize. Finds the RemoteEvent and starts listening.
-- Call once at client startup.
Sentinel.Client.init({
    remoteName = "SentinelRemote",  -- optional, must match server
})

-- Get a read-only view. Returns immediately; view is empty until initial snapshot arrives.
local gameState = Sentinel.Client.get("gameState")

-- Read synchronously. Returns nil if the key doesn't exist or view isn't synced yet.
local score = gameState:get("score")

-- Subscribe to a specific key. Callback fires on every change to that key.
local conn = gameState:onChange("score", function(newScore)
    print("Score:", newScore)
end)

-- Subscribe to a nested path. Dot-separated, one level deep per segment.
gameState:onChange("players.alice", function(data)
    print("Alice's data changed")
end)

-- Subscribe to all changes. Fires once per changed leaf-path per flush with the dot-path.
gameState:onAnyChange(function(path, newValue, isRemoved)
    print(path, isRemoved and "removed" or "set to", newValue)
end)

-- Subscribe to container teardown. Fires when the server destroys the container.
gameState:onDestroy(function()
    print("Container was destroyed by the server")
end)

-- Check if initial snapshot has been received.
if gameState:isReady() then ... end

-- Fire once when initial snapshot arrives.
gameState:onReady(function()
    print("Initial state received")
end)

-- Disconnect a subscription.
conn:Disconnect()
```

### Shared

```lua
-- The None sentinel. Used in patches to distinguish "set to nil" from "untouched."
local Sentinel = require(Packages.sentinel)
local None = Sentinel.None

-- Shared type describing the state shape. Same type on both sides.
export type GameState = {
    score: number,
    round: number,
    players: { [string]: PlayerState },
}
```

---

## Module structure

```
src/
  init.luau              -- Main entry point. Exposes .Server, .Client, .None, .Types
  None.luau              -- The None sentinel (newproxy userdata, identity-comparable)
  Types.luau             -- Shared export types
  Delta.luau             -- Pure diff/patch functions (no networking, no Roblox world)
  Serializer.luau        -- Buffer pack/unpack for every supported value type
  Server/
    init.luau            -- Server container registry, flush loop, RemoteEvent management
    Container.luau       -- Per-container state, dirty tracking, snapshot/delta generation
  Client/
    init.luau            -- Client reconciler, remote listener, view registry
    View.luau            -- Read-only view with change signal management
```

### Rojo project mapping

`src/` maps to `ReplicatedStorage.sentinel`. The framework creates its RemoteEvent at runtime under `ReplicatedStorage` (configurable). Server and Client init scripts require the package and call `.init()`.

---

## The None sentinel

**Problem:** In a patch table, `patch.health = nil` is ambiguous. Does it mean "remove health" or "health was not changed"? In Luau, setting a table key to `nil` **removes the key** — so `nil` can't appear as a value in a sparse patch table. You cannot distinguish "deleted" from "absent."

**Solution:** A unique sentinel value called `None`. In a patch:

- `patch.health = None` → "remove the `health` key"
- `health` absent from `patch` → "no change to `health`"
- `patch.health = 50` → "set `health` to 50"

**Implementation:** `newproxy(true)` — a userdata with a locked metatable. It's identity-comparable (`value == None`), can't be cloned or frozen, can't be confused with any real value, and never appears in state itself (only in patches). On the wire, it's tag byte `0x00`.

**Why this matters:** This is the single most common bug in hand-rolled replication. Without an explicit sentinel, engineers reach for `nil` and either lose deletion events or conflate "not in diff" with "explicitly removed." The sentinel makes the three-way distinction (set / remove / unchanged) unambiguous.

---

## Wire format

### Supported value types

| Tag  | Type        | Payload                                                        |
|------|-------------|----------------------------------------------------------------|
| 0x00 | None        | (none)                                                         |
| 0x01 | Boolean     | 1 byte (0 = false, 1 = true)                                   |
| 0x02 | Number      | 8 bytes, f64 little-endian                                     |
| 0x03 | String      | 4 bytes u32 length + N bytes UTF-8                             |
| 0x04 | Vector3     | 12 bytes, 3× f32 little-endian                                 |
| 0x05 | Table (map) | 4 bytes u32 entry count + entries (each: u32 key len + key bytes + tagged value) |

**Design choices:**

- **f64 for numbers:** Luau numbers are doubles. f32 would silently lose precision. 8 bytes is the correct width.
- **f32 for Vector3:** Roblox `Vector3` components are 32-bit floats. f32 is lossless and saves 12 bytes per vector vs f64.
- **u32 for lengths:** Supports strings/tables up to 4 GB. Overkill but consistent, and only 4 bytes.
- **Tables are maps with string keys:** State is a tree of string-keyed maps. Array-like tables (numeric keys) are not supported in state — if you need a list, use a map with string keys (`{ item1 = ..., item2 = ... }`). This keeps the wire format simple and the diff algorithm clean.
- **No CFrame/Color3 in v1:** Keeps the core small. Can add tags 0x06+ in a future version without breaking the format (unknown tags are a deserialization error, not a crash, if we include a skip-length).

### Value encoding example

State:
```lua
{ health = 100, name = "alice", alive = true }
```

Wire bytes (annotated):
```
05              -- Table (map)
  03 00 00 00   -- 3 entries
  -- entry 1: "health" = 100
  06 00 00 00   -- key length = 6
  68 65 61 6C 74 68   -- "health"
  02            -- Number
  00 00 00 00 00 00 59 40   -- f64 100.0
  -- entry 2: "name" = "alice"
  04 00 00 00   -- key length = 4
  6E 61 6D 65   -- "name"
  03            -- String
  05 00 00 00   -- length = 5
  61 6C 69 63 65   -- "alice"
  -- entry 3: "alive" = true
  05 00 00 00   -- key length = 5
  61 6C 69 76 65   -- "alive"
  01            -- Boolean
  01            -- true
```

### Patch encoding

A patch uses the **same value encoding** as state. The only difference is that `None` (tag 0x00) can appear as a value, meaning "remove this key." A patch is simply a sparse table (map) serialized with tag 0x05.

Example patch — "set health to 80, remove stamina":
```lua
{ health = 80, stamina = None }
```

Wire bytes:
```
05              -- Table (map)
  02 00 00 00   -- 2 entries
  -- "health" = 80
  06 00 00 00 68 65 61 6C 74 68
  02 00 00 00 00 00 00 00 50 40   -- f64 80.0
  -- "stamina" = None
  07 00 00 00 73 74 61 6D 69 6E 61
  00            -- None
```

### Message envelope

#### Server → Client (batch, one per Heartbeat flush)

The server sends a single `buffer` through `RemoteEvent:FireClient` or `FireAllClients`. The buffer contains:

```
[u8  version]             -- Wire format version (currently 0x01)
[u16 containerCount]
  for each container with pending changes:
    [u32 containerId]        -- Sequential u32 assigned by server at registration
    [u8  messageType]        -- 0x01 = snapshot, 0x02 = delta, 0x04 = destroy
    [u32 payloadSize]        -- byte length of the following payload
    [payload]                -- serialized state (0x01), serialized patch (0x02), or empty (0x04)
    -- For 0x01 (snapshot) to a client that doesn't know this containerId yet:
    --   payload is preceded by [u32 nameLen][nameBytes] so the client can register the name
```

**payloadSize backfill:** The flush loop cannot know `payloadSize` until after the payload has been serialized. The approach is a **seek-back write**:

1. Record the current write offset as `lengthPos` before writing the 4-byte `payloadSize` slot.
2. Write a placeholder `0x00000000` into those 4 bytes.
3. Serialize the payload, tracking the end offset as `payloadEnd`.
4. Compute `payloadSize = payloadEnd - (lengthPos + 4)`.
5. Seek back to `lengthPos` and write `payloadSize` via `buffer.writeu32(buf, lengthPos, payloadSize)`.
6. Seek forward to `payloadEnd` and continue with the next container.

This is the same pattern used by every length-prefixed binary format. The buffer supports random access by offset, so the seek-back is a single `writeu32` — no copy, no reallocation. If this step is left vague, a future maintainer will either double-write the length (corrupting the stream) or serialize into a temporary buffer and copy (wasting the zero-allocation guarantee). The backfill is mandatory and explicit.

**Container ID:** Sequential u32 assigned by the server at registration time. The first container gets ID 1, the second ID 2, etc. The id→name mapping is piggybacked on the initial snapshot envelope: when a client receives a snapshot for an unknown container ID, the envelope includes the container name string so the client can register it. This avoids hash collisions entirely — a library that fails at runtime because two container names hash to the same value is a bad look. Sequential IDs are strictly safer and the mapping exchange cost is marginal since we already have an init handshake.

**Message types:**

| Type | Direction        | Meaning                                              |
|------|------------------|------------------------------------------------------|
| 0x01 | Server → Client  | Full snapshot (initial sync or container creation)   |
| 0x02 | Server → Client  | Delta patch (steady-state incremental update)        |
| 0x03 | Client → Server  | Initial sync request (player ready to receive state) |
| 0x04 | Server → Client  | Container destroyed (teardown notification)          |

#### Client → Server (initial sync request)

A single byte: `0x03`. The server knows which containers each player should receive (global containers + that player's per-player containers). Rate-limited to once per player; subsequent requests are ignored with a warning.

#### Server → Client (container destroy, 0x04)

When the server calls `container:destroy()`, the next flush includes a `0x04` message for that container ID. The payload is empty (`payloadSize = 0`). The client reconciler handles this by:
1. Firing all `onDestroy` callbacks registered on the view.
2. Firing all `onChange` callbacks for every key in the view's state with `nil` (the state is gone).
3. Clearing the view's internal state and subscription maps.
4. Removing the view from the client registry.

This prevents per-player container views from leaking on the client when a player's session-scoped state goes away.

#### Flush strategy

- **Global containers:** If any global container is dirty, build one buffer with all global deltas/snapshots, `FireAllClients(buffer)`.
- **Per-player containers:** For each player with dirty per-player containers, build one buffer with that player's deltas/snapshots, `FireClient(player, buffer)`.
- **Most frames:** 0 or 1 remote fires. Worst case: 1 + (number of players with per-player changes).
- **RemoteEvent ordering:** Roblox guarantees reliable, ordered delivery per RemoteEvent. Snapshots always arrive before deltas for the same container. Destroy messages (0x04) always arrive after all deltas for that container.
- **Buffer support:** `buffer` values replicate through RemoteEvents natively (supported since 2024). No string fallback is needed or built.

---

## Delta algorithm

### Pure functions (in Delta.luau, testable without the 3D world)

```lua
-- diff: compute the minimal patch from old to new
local function diff(old: State, new: State): Patch

-- apply: mutate state in-place by applying a patch
local function apply(state: State, patch: Patch): State
```

**diff(old, new) → patch:**

1. For each key in `new`:
   - If `old[key]` is nil → `patch[key] = new[key]` (key was added)
   - If `old[key]` is a table and `new[key]` is a table → `patch[key] = diff(old[key], new[key])` (recurse). If the sub-patch is empty, omit the key.
   - If `old[key]` is a table and `new[key]` is not (or vice versa) → `patch[key] = new[key]` (type change, full replacement)
   - If `old[key] != new[key]` (scalar comparison) → `patch[key] = new[key]` (value changed)
   - If `old[key] == new[key]` → omit (no change)
2. For each key in `old` not in `new` → `patch[key] = None` (key was removed)
3. Return the patch (sparse — only changed paths appear)

**apply(state, patch) → state:**

1. For each key in `patch`:
   - If `patch[key]` is `None` → `state[key] = nil` (remove)
   - If `patch[key]` is a table and `state[key]` is a table → `apply(state[key], patch[key])` (recurse)
   - Otherwise → `state[key] = patch[key]` (set, includes type changes)
2. Return `state` (mutated in-place)

### Hot-path optimization (in Server/Container.luau)

The pure `diff` function creates intermediate tables. The flush loop avoids this by:

1. **Dirty-key tracking:** `container:set(key, value)` marks `key` as dirty in a `{ [string]: boolean }` set. Only dirty keys are examined during flush.
2. **Per-key diff:** On flush, for each dirty key, compute `diff(lastSent[key], current[key])` (or `current[key]` if added, or `None` if removed). This avoids walking the entire state tree.
3. **Direct-to-buffer serialization:** A combined `diffAndSerialize(old, new, buf, offset) -> newOffset` function walks the dirty subtrees and writes changed values directly into the buffer. No intermediate patch table is created. The pure `diff` function exists for testing and non-hot-path use; the combined function exists for the flush loop.
4. **Buffer reuse:** A preallocated buffer (initial 64 KB, grows if needed) is reused across frames. Each frame writes from offset 0. One `buffer.create(payloadSize)` call per frame for the final send buffer (not a table allocation — this is acceptable and unavoidable).

### lastSentState management

- `lastSentState` is a deep clone of `currentState` at the time of the last flush.
- After flush, only dirty keys are updated in `lastSentState`. Scalars are a direct assignment (zero allocation). Nested tables that changed are deep-cloned — but **only the changed subtrees**, not the entire state tree.
- Dirty set is cleared after flush via `table.clear()`.

**The clone function — and proof it doesn't walk unchanged branches:**

```lua
--!strict

--[[
    CloneChanged
    @kzui
]]

-- Deep-clones a value. Only called on dirty subtrees — never on the full state tree.
-- Scalars (number, string, boolean, Vector3) are returned directly (no allocation).
-- Tables are cloned recursively. This function is only invoked for keys that are
-- in the dirty set, so unchanged branches are never visited.

local function cloneChanged(value: any): any
    local t = typeof(value)
    if t == "table" then
        local copy = table.create(0, nil) -- preallocate, grows as needed
        for k, v in value do
            copy[k] = cloneChanged(v)
        end
        return copy
    end
    -- number, string, boolean, Vector3, None — all value types, no clone needed
    return value
end

-- Called during flush, once per dirty key:
-- lastSent[dirtyKey] = cloneChanged(current[dirtyKey])
--
-- If dirtyKey's value is a scalar, this is a direct assignment (zero allocation).
-- If dirtyKey's value is a nested table, only that subtree is walked.
-- Keys NOT in the dirty set are never touched — lastSent retains its existing
-- references for unchanged keys, which are shared (not cloned) between
-- lastSent and the previous frame's lastSent.
```

**Allocation accounting per flush:**
- Zero allocations for unchanged keys (the common case — most keys don't change per frame).
- Zero allocations for scalar changes (direct assignment).
- Allocations proportional to changed nested table size only. If a dirty key holds a 10-entry table, that's one table creation + 10 scalar assignments. If the table has 500 entries but only 2 were dirty at the leaf level, the dirty key is the parent, so all 500 are cloned. **This is why the dirty set tracks at the finest granularity the API exposes** — `container:set("a.b.c", value)` marks `a.b.c` dirty, not `a`. The `mutate` function marks only the keys the callback writes. This keeps clone scope bounded to genuinely-changed subtrees.
- The README's claim is: "zero table allocations for unchanged state; allocations bounded to changed subtrees only." This is verifiable by the dirty-key tracking logic above.

---

## Client reconciliation

### Single deterministic reconciler

1. Receive buffer from RemoteEvent.
2. Read `version` byte. If unknown version, log a warning and discard (forward compatibility).
3. Read `containerCount`.
4. For each container message:
   - Look up the `ClientView` by container ID.
   - If not found and messageType is 0x01 (snapshot): read the container name from the payload prefix, register a new view, then process the snapshot.
   - If not found and messageType is 0x02 or 0x04: skip (delta/destroy for an unknown container — stale or already cleaned up).
   - If `messageType == 0x01` (snapshot): replace the view's entire state with the deserialized state. Mark view as ready. Fire `onReady` callbacks. Collect all root keys as changed paths for signal dispatch.
   - If `messageType == 0x02` (delta): deserialize the patch, call `Delta.apply(view._state, patch)`, then collect changed leaf paths from the patch for signal dispatch.
   - If `messageType == 0x04` (destroy): fire `onDestroy` callbacks, fire `onChange` for all current keys with `nil`, clear state and subscriptions, remove from registry.
5. After all container messages are processed, perform **coalesced signal dispatch** (see below).

### Change signal dispatch (coalesced)

The reconciler does **not** fire callbacks during patch application. Instead:

1. **Collect:** During `Delta.apply`, the reconciler records every changed leaf path into a set: `changedPaths: { [string]: boolean }`.
2. **Resolve subscriptions:** For each changed path `"a.b.c"`, walk up the path segments and collect all subscribed paths that match: `"a.b.c"`, `"a.b"`, `"a"`. Insert each into an `affectedSubscriptions: { [string]: boolean }` set.
3. **Deduplicate:** Because `affectedSubscriptions` is a set, if 5 leaves under `"a"` changed, `"a"` appears once — not 5 times.
4. **Fire:** For each path in `affectedSubscriptions`, fire all callbacks registered for that path **exactly once**. The callback receives the current value at that path in the view's state (after all patches in this flush have been applied).
5. **Fire onAnyChange:** For each path in `changedPaths`, fire all `onAnyChange` callbacks with the path, the current value at that path, and `isRemoved` (true if the value is `nil`).

**Example:** If a patch changes `a.b.c = 10` and `a.b.d = 20` in one flush:
- `changedPaths` = `{ "a.b.c", "a.b.d" }`
- `affectedSubscriptions` = `{ "a.b.c", "a.b.d", "a.b", "a" }`
- A callback subscribed to `"a"` fires **once** with the full `a` table (containing both changes).
- A callback subscribed to `"a.b"` fires **once** with the full `a.b` table.
- Callbacks on `"a.b.c"` and `"a.b.d"` each fire once with their respective scalar values.
- `onAnyChange` fires twice: once for `"a.b.c"`, once for `"a.b.d"`.

**Snapshot case:** On initial snapshot, every root key is a "changed path." Subscribers to root keys and their descendants fire once each with the snapshot values. `onAnyChange` fires once per root key.

### Path subscription matching

Subscriptions are stored in a flat map: `{ [string] -> { callbacks } }` where the key is the dot-path. During the resolve step, the reconciler walks up the path segments: `"a.b.c"` → check `"a.b.c"`, `"a.b"`, `"a"`. Exact paths only — no wildcards. The parent-fires-on-descendant-change rule (via the walk-up) covers the real use cases wildcards would solve.

---

## Object ownership

| Object             | Owner                          | Cleanup                                    |
|--------------------|--------------------------------|--------------------------------------------|
| RemoteEvent        | Server init                    | Destroyed on `Server.shutdown()`          |
| Server container   | Server registry                | `destroy()` sends 0x04, frees state        |
| Client view        | Client registry                | Destroyed on 0x04 message, GC'd after      |
| Preallocated buffer| Server flush loop              | Reused across frames, never destroyed      |
| Change connections | Client view                    | `Disconnect()` removes from callback list  |
| Dirty key set      | Server container               | `table.clear()` after each flush           |
| changedPaths set   | Client reconciler              | `table.clear()` after signal dispatch      |
| affectedSubs set   | Client reconciler              | `table.clear()` after signal dispatch      |

No dual ownership. No Debris for framework objects. The server owns the remote; containers own their state and dirty sets; views own their subscriptions; the reconciler owns its transient path sets.

---

## Testing strategy

### Pure unit tests (no 3D world needed)

**Delta.spec.luau:**
- Round-trip: `apply(state, diff(state, newState)) == newState`
- Minimal patch: diffing two identical states produces an empty patch
- Nested diff: changing a leaf deep in the tree produces a patch with only that path
- None/nil-removal: removing a key produces `patch[key] = None`; applying it sets `state[key] = nil`
- Type change: changing a table to a scalar produces a full replacement, not a recursive diff
- Empty sub-patch: if a nested table has no changes, the parent patch omits that key

**Serializer.spec.luau:**
- Round-trip each type: `unpack(pack(value)) == value` for number, string, boolean, table
- Round-trip Vector3: `unpack(pack(v)) == v` — this works because Roblox Vector3 components are f32 internally, so f32 round-trip is lossless. The test explicitly documents this assumption: it passes because the input components are already f32-representable. If a test constructs `Vector3.new(1/3, 0, 0)`, the component is already truncated to f32 by the constructor, so the round-trip is exact.
- Round-trip None: `unpack(pack(None)) == None`
- Nested tables: deeply nested table round-trips correctly
- Empty table: `{}` round-trips correctly
- Edge cases: empty string, 0, very large number (1e308), very long string, NaN, positive infinity, negative infinity
- **Negative zero:** Assert bit-level identity, not `==` (since `-0 == 0` is true in Luau). Pack `-0`, unpack it, then compare the raw f64 bytes against a freshly packed `-0`:
  ```lua
  local packed = pack(-0.0)
  local unpacked = unpack(packed)
  -- -0.0 == 0.0 is true, so this proves nothing:
  -- assert(unpacked == -0.0)
  -- Instead, verify the sign bit is preserved:
  local repacked = pack(unpacked)
  assert(buffer.readu8(packed, 1) == buffer.readu8(repacked, 1))
  assert(buffer.readu8(packed, 8) == buffer.readu8(repacked, 8))
  -- Specifically, the last byte should have the sign bit set (0x80):
  assert(buffer.readu8(packed, 8) == 0x80)
  ```

**None.spec.luau:**
- Identity: `None == None` is true
- Uniqueness: `None ~= nil`, `None ~= {}`, `None ~= 0`, `None ~= false`
- tostring: `tostring(None)` returns `"sentinel.None"`

### Integration tests (require Roblox runtime)

- Server creates a container, sets values, flush fires, client view receives snapshot
- Server updates a value, client `onChange` fires with correct new value
- Server removes a key, client `onChange` fires with `nil`
- Late joiner: player joins after state has been modified, receives correct snapshot
- Per-player container: only the owning player receives updates
- Rate limit: second sync request from same player is rejected
- Container destroy: server destroys container, client `onDestroy` fires, view is cleaned up
- Coalescing: multiple changes under the same subscribed path in one flush fire the callback once, not N times

### CI

GitHub Actions workflow:
1. **Selene** — static analysis lint
2. **StyLua** — format check
3. **Test suite** — run pure unit tests via a Roblox test runner (run-in-roblox or similar)

---

## Benchmark

`benchmarks/delta_vs_naive.luau` — a reproducible script that:

1. Creates a realistic state tree (e.g., 50 players × 10 fields each, nested).
2. Mutates 5% of fields per frame for 1000 frames.
3. Measures total bytes sent with delta compression vs. full-state resend.
4. Prints a summary table: total bytes, average bytes/frame, compression ratio.

Expected result: delta compression sends ~5% of the bytes that naive resend does (plus per-container overhead), with the ratio improving as state size grows.

---

## Resolved design decisions

1. **String keys only (v1 scope boundary).** State tables support string keys only — no numeric/array keys. This is a deliberate scope boundary, not an omission. Array support would roughly double the diff complexity (LCS or index-diffing) and the wire format. For a portfolio piece, a clean, correct, well-documented string-keyed framework beats a half-working one with arrays. Documented loudly in the README as a v1 limitation with a path to v2.

2. **Sequential container IDs.** The server assigns sequential u32 IDs at registration time (1, 2, 3, ...). The id→name mapping is piggybacked on the initial snapshot envelope. This is strictly safer than FNV-1a hashing, which has birthday collisions well before you'd intuit and could fail at runtime because someone named a container badly. A reviewer who spots a collision-on-string-name failure mode loses confidence; sequential IDs eliminate that risk entirely.

3. **Buffer through RemoteEvent — assume native support.** `buffer` values replicate through RemoteEvents natively (supported since 2024). No string fallback is built. This is a hard dependency on modern Roblox, which is acceptable for a 2025 library.

4. **Exact paths only — no wildcards.** `onChange("a.b.c")` supports dot-separated exact paths. Wildcards are scope creep. The parent-fires-on-descendant-change rule (via the walk-up in signal dispatch) covers the real use cases that wildcards would solve.

5. **Version byte — yes.** The envelope starts with `[u8 version]` (currently `0x01`). One byte per frame is negligible cost. This is the difference between "I can evolve this format" and "I'm locked forever." Cheap insurance; take it.
