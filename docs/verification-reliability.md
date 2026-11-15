# Reliability verification — 2026-11-15

Target: autonomous-agent reliability on Factorio 2.1.24 (Windows, Steam build), isolated
write-data directory, disposable map. Mod set: base, elevated-rails, quality, recycler, space-age,
planet-express 2.1.12, factorio_autonomous_engineer 0.1.0 (`factorio_llm_use` disabled).

Reproduce with `tests/engine/*` (see [tests/engine/README.md](../tests/engine/README.md)). Every
row below was observed in a real engine run; nothing here is inferred from reading Lua.

## Results

### 1. Save/load during gathering — PASS

| Step | Observation |
| --- | --- |
| Task running, phase `mining`, 5 ore collected | `task_start` → task 1 |
| `game.server_save`, then SIGKILL of the game process | save written, no graceful shutdown |
| Reload that save | same task id, `status=running`, `phase=mining`, `collected=5`, `deposits_used=1` |
| Continue without intervention | finishes with `collected=120`, inventory exactly 120 iron ore |

No duplicate counting: the restored `start_count` keeps the delta correct across the reload. The
executor also survives a save taken mid-path — an in-flight path request cannot complete after a
reload, and the phase timeout (`60*20` ticks) returns it to `search`, which re-plans.

### 2. Emergency response — PASS (after a crash fix)

| Step | Observation |
| --- | --- |
| Three small biters spawned and ordered to attack during gathering | `runner.execute` returns `interrupted_by_safety` on its own |
| Task state | `status=paused`, `reason=safety`, movement/mining stopped |
| Safety state | `active=true`, `reason=nearby_hostiles`, destination kind `local_escape` |
| Evacuation | agent walked ~37 tiles away from the threat, no LLM decision involved |
| Events | `agent_under_attack` (cause `small-biter`, health/max_health) and `emergency_resolved` (`elapsed_ticks`) |
| Resume | explicit `resume_task` → task finishes 200/200 |
| Firing rules | armed: `shooting_state=shooting_enemies`; no ammunition: `not_shooting`; health below 30 %: `not_shooting` |

Defect found here: the safety controller crashed the whole game the first time a hostile came into
range (see fix 1).

### 3. Death and respawn — PASS (after two fixes)

Inventory at death: 50 iron plate, 25 copper plate, submachine gun, 100 firearm magazines,
modular armor with battery + solar-panel equipment.

| Step | Observation |
| --- | --- |
| Death during a running task | `agent_died` event, task `paused`/`reason=death`, emergency `respawning` |
| Loot capture | 177 items moved into the recovery bags, `agent_loot_recovered` event |
| Respawn | after the 180-tick delay, new unit number, at the home position |
| Restored inventory | identical to the pre-death snapshot, including both grid equipment modules |
| Loss / duplication | none (`MISSING={}`, `DIFFERENT={}`), recovery bags empty afterwards |
| Task | stays paused until `resume_task`, then gathers the remaining amount |
| Unsafe home | while hostiles sit inside the 48-tile home radius: `waiting_for_safe_spawn` with `spawn_block_reason=home_under_threat` and **no** character created; respawn happens after the area is cleared |

### 4. RCON faults — PASS

| Check | Observation |
| --- | --- |
| Replay of a completed `task_start` with the same request id | identical cached response (same tick), no second task |
| Same call with a new request id | new task created — proves the replay above was really served from cache |
| Cache across save/load | replayed request still served from cache after a restart |
| Server killed while polling | `BridgeError: RCON unavailable; retain request_id=…` after ~7 s, no hang |
| Restart + reconnect | state readable, agent alive, no duplicate task |
| Wrong RCON password | `RCON authentication failed` |
| No server at all | `RCON unavailable; retain request_id=…` after ~4 s |
| MCP client SIGKILL mid-task | task keeps its id and keeps running; a fresh MCP process reports the same task; remaining amount completes exactly (400/400) |

Deduplication is **not** a general exactly-once guarantee for gameplay actions. The only mechanism
is the 512-entry request cache in `storage` (so it survives save/load): a repeated RCON call that
carries the **same `request_id`** inside the retained cache window returns the stored response
instead of executing again. Anything else re-executes — a planner tool call always mints a new
`request_id`, so repeating a tool call can start a second task. A restarted MCP process must read
`agent_status` before acting rather than blindly re-submitting.

## Defects found and fixed

1. **`lib/safety.lua` — crash on first hostile detection.**
   `safety, safety.nearby_enemies = s.safety, scanned` evaluates the indexed left-hand side before
   the assignment, so it indexed `nil` and the game died with a non-recoverable error
   (`attempt to index local 'safety'`). The server stopped accepting RCON, which also made the
   "emergency" path untestable. Fixed by assigning the table first, then its fields, with a guard.
2. **`lib/lifecycle.lua` — all items lost on death.**
   Recovery relied on `on_entity_died`'s `event.loot`, but for a character the engine puts the
   inventory into a `character-corpse` that is only readable on the following tick; both `loot`
   and the character's own inventories are empty inside the event. Fixed with a one-shot,
   attempt-bounded corpse sweep in `M.tick` that moves every item into the recovery bags, destroys
   the corpse only once it is empty, and emits `agent_loot_recovered` (or `agent_loot_unavailable`
   if no corpse is found). Armor keeps its equipment grid because stacks are moved, not recreated.
3. **`lib/lifecycle.lua` — silent no-op in the corpse sweep.**
   `defines.inventory.corpse` does not exist in 2.1.24; a table literal with that leading `nil`
   plus `ipairs` never iterated, so the first version of fix 2 recovered nothing. Candidate
   inventory ids are now collected with `pairs` and `type(id) == "number"` filtering.

## Known limits

- If the corpse is destroyed (biters, artillery) before the sweep, items are gone; the queue
  reports `agent_loot_unavailable` rather than pretending success.
- The sweep searches a 3-tile radius around the recorded death position; a corpse that is pushed
  further away is not found.
- A task cancelled by an MCP timeout is cancelled in-game; a hard MCP crash leaves the task running
  until someone inspects status. That is intentional and documented in the engine test plan.
- Multiplayer, space platforms and other planets are out of scope for this run.
