# Factorio engine test plan (disposable save only)

Target: Factorio 2.1.24, Windows, isolated copy of an existing save. Disable the original factorio_llm_use mod in this test mod set so only one AI engineer is spawned.

## 1. Load, strategic profile and identity

- Enable factorio_autonomous_engineer and load the disposable save.
- Confirm the named Autonomous Engineer character appears near the player-force spawn.
- Call get_briefing; verify active planet/domain and stage evidence against actual research and space-platform state. Confirm the matching core, stage and planet skills are loaded.
- Verify the briefing exposes only implemented high-level capabilities and no coordinates, entity handles, path nodes, inventory slots or low-level operations.
- On early Nauvis, call select_starting_site; verify the chosen area has basic resources, water, a valid furnace footprint, no known hostile entities within the exclusion radius and adequate generated-chunk coverage. Confirm it becomes the home/respawn point.
- Confirm the named character and home survive save/reload.

## 2. Composite task and model-visible results

- Ask the agent to collect a small amount of a nearby resource (for example, 20 iron ore).
- Observe the MCP transcript: one execute_task call should produce one final tool result.
- Confirm the agent pathfinds, mines using the native mining state and reports the actual inventory delta.
- Try an unavailable resource; confirm a bounded, explicit failure rather than an infinite loop.
- Start a task and cancel it by task ID; confirm movement/mining stop.

## 3. Safety pre-emption

- Equip a test weapon and compatible ammunition, then cause one controlled nearby enemy unit to approach and attack the character on the disposable save. Also place/enable a hostile turret in a test scenario and confirm it is included in threat detection.
- Confirm the current task becomes paused, ordinary mining/movement stops, and the safety controller selects a home or local escape destination without an LLM decision.
- Confirm automatic firing only occurs when a gun and ammunition are present and health is above the configured critical threshold.
- Confirm agent_under_attack and emergency_resolved events are recorded and retrieved with a cursor.
- Confirm the paused task does not resume automatically; resume explicitly after status is safe.

## 4. Death, inventory recovery and respawn

- Give the agent representative main-inventory items, a gun, ammunition and armor.
- Kill the agent in a controlled test. Confirm agent_died, a paused task with reason death, and recovery inventory counts.
- Confirm respawn is delayed, uses a new character unit number, and occurs only when the home area is collision-free and outside the enemy danger radius.
- Confirm items return to their matching character inventory classes and that no items are duplicated or silently lost. Specifically inspect armor equipment-grid contents.
- Make the home area unsafe before the respawn deadline; confirm the controller waits and retries instead of creating the character inside the threat radius.
- Confirm the emergency lock clears after a successful respawn, but the task remains paused until explicitly resumed; then verify it gathers only the remaining requested amount.

## 5. Save/load and fault handling

- Save/load while a composite task is in progress; confirm the task checkpoint survives.
- Interrupt the MCP request and confirm the configured cancellation policy is applied.
- Stop/restart the MCP process while Factorio remains active; inspect the task by status and event cursor. Do not assume an exactly-once guarantee beyond the request cache retention.
- Test unavailable RCON, wrong password and reconnect; verify clear errors and no duplicate task.

## 6. Construction and collaboration

Run `tests/engine/s5_construction.py` and `tests/engine/s6_construction_persistence.py` against disposable copies of the baseline save. Expected observations:

- A — plan placement: named plan reports success; the expected `entity-ghost` objects exist; no real building exists; inventory is unchanged.
- B — own materials: the agent walks to the work area; each real building appears once; the exact placeable items are removed once; the result reports built_by_agent and no ghosts remain.
- C — ordinary chest: an unmarked wooden chest supplies the required items; the chest loses exactly those items; the agent walks to it; a full inventory leaves the chest untouched and reports inventory_full; partial supply builds what it can and reports missing_materials.
- D — no materials: the ghost remains, no real building or new item appears, and the terminal status is missing_materials.
- E — player blueprint: the agent detects player ghosts in its work area, leaves an already-built object alone and builds the remaining objects without duplicates.
- F — player changes: a cancelled ghost is not recreated, a player-built object is not duplicated, and a replacement ghost is discovered and built; only the replacement's cost is paid.
- G — clearing: a tree and a rock on target positions are mined, their ordinary resources enter the inventory and the objects are then built; nearby chests and real buildings remain intact.
- H — persistence/interruption: save/load during clearing and after a chest transfer preserves task ID, ledger and materials exactly once; safety pre-emption returns interrupted_by_safety and waits for explicit resume; cancel stops movement and leaves the ghost; a player working at one site is deferred and a player removing chest materials is observed; death/respawn preserves construction materials and resume completes the build.

Do not count a construction scenario as engine-tested unless the script prints its evidence and exits 0. Record the actual commands and results in `docs/verification-construction.md`.

## 7. Module catalog and instantiation

Run `tests/engine/s7_module_catalog.py` against a disposable copy of the baseline save. The script
uses the internal RCON module operations; it never sends absolute placement coordinates to an LLM.

Expected observations:

- A — catalog: all three initial modules load with unique stable IDs; invalid test definitions are
  rejected with explicit diagnostics (schema version, unknown prototype, direction, position,
  footprint, duplicate port, port bounds, unknown recipe/technology, unsupported entity/parameter);
  force availability distinguishes prototype existence from researched/enabled requirements.
- B — ghost instantiation: each module creates exactly its declared number of `entity-ghost`
  objects, creates no real building and leaves the agent inventory unchanged.
- C — geometry: actual ghost positions/directions match the resolved module geometry; every
  advertised orientation is exercised; repeated furnace positions and port IDs are deterministic;
  transformed mining ports and reserved areas are checked; resource-dependent placement is rejected
  off-resource and a real blocker in the footprint is rejected.
- D — construction integration: `assist_construction` builds a complete module through paid ghost
  revival; exactly the expected items are consumed; real entity count/position/direction matches the
  module; no duplicates or ghosts remain; the assembling-machine recipe is applied after revival and
  verified.
- E — save/load: module instance identity, ghost unit numbers and pending state survive a
  save/reload; re-instantiating the same key does not duplicate ghosts or records; a construction
  task saved mid-move resumes with the same task ID and completes exactly once.

The Stage-3 scenarios `s5_construction.py`, `s6_construction_persistence.py` and all earlier
reliability scenarios must be re-run on the same archive. Record results in
`docs/verification-modules.md` and `docs/verification-construction.md`.

## Pass criteria

Do not promote the mod beyond development status until all relevant checks pass on the actual Factorio 2.1.24 executable and the user's enabled mod set. Record the save copy, mod list, Factorio build, test actions, RCON logs, event payloads and before/after inventory counts.
