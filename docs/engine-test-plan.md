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
- Confirm the task can be explicitly resumed and only gathers the remaining requested amount.

## 5. Save/load and fault handling

- Save/load while a composite task is in progress; confirm the task checkpoint survives.
- Interrupt the MCP request and confirm the configured cancellation policy is applied.
- Stop/restart the MCP process while Factorio remains active; inspect the task by status and event cursor. Do not assume an exactly-once guarantee beyond the request cache retention.
- Test unavailable RCON, wrong password and reconnect; verify clear errors and no duplicate task.

## Pass criteria

Do not promote the mod beyond development status until all relevant checks pass on the actual Factorio 2.1.24 executable and the user's enabled mod set. Record the save copy, mod list, Factorio build, test actions, RCON logs, event payloads and before/after inventory counts.
