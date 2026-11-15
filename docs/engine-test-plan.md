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

## 8. Layout Planner

Run `tests/engine/s8_layout_planner.py` against disposable copies of the baseline save. The script
uses internal RCON planning operations; the model-facing MCP tools return only compact summaries.

Expected observations:

- A — dependency graph and plan creation: the live recipe chain selects the iron mining, stone
  furnace smelting and gear assembling modules; the mining footprint contains iron ore; the furnace
  recipe is inferred from live data; gear comes from the entity recipe; coal fuel and electric
  network are explicit missing dependencies; two item edges are `route_required`; no ghost or real
  module exists; inventory is unchanged; identical world state reproduces the same plan ID,
  fingerprint and anchors; the MCP `plan_layout` response contains no coordinates, ports, entities
  or unit numbers.
- B — all four supported mining rotations produce materializable plans with the correct rotated
  footprint and transformed output port direction; the four plans have distinct deterministic
  identities.
- C — an existing real building, an existing player construction ghost and a real player character
  are avoided; the building/ghost remain unchanged; natural trees are recorded as clearing
  requirements; a clearing-required plan still materializes only ghosts.
- D — apply creates exactly one ghost per selected module and no real entity; all ghosts carry the
  plan ID; inventory is unchanged; repeated apply is idempotent; plan and ghost identities survive
  save/load; a cancelled plan ghost is not recreated; a player-built plan entity is recognised and
  not duplicated; the Stage-3 named ghost plan still works.
- E — a new real building, player construction ghost, player character or resource removal makes the
  stored plan stale; apply refuses it and creates no ghost; the conflicting world object remains.

Expected archive and regression checks:

- Existing scenarios `s1_save_load`, `s2_attack`, `s3_death`, `s3b_unsafe_home`, `s4_rcon`,
  `s4b_mcp_restart`, `s5_construction`, `s6_construction_persistence` and `s7_module_catalog` pass on
  the same archive.
- `uv run ruff check .` and `uv run pytest -q tests` pass.
- The tested archive is built from the tested Git mod tree; every entry is compared byte-for-byte
  with the corresponding Git blob and its SHA-256 is recorded.

The human multiplayer acceptance test is separate and must use a real Factorio client on the
persistent isolated server. Synthetic characters used by automated obstacle checks do not count as
human multiplayer verification.

## 9. Physical logistics (Stage 6)

Run in an isolated Stage-6 profile (`FACTORIO_TEST_DIR=.../factorio-stage6`,
`FACTORIO_RCON_PORT=27076`, `FACTORIO_GAME_PORT=27037`) so the running Stage-5 acceptance
server and its world are untouched. The harness `stop_server()` is scoped to the selected
runtime directory. The scenario fixtures create only prerequisites: all research on a disposable
save, a clear test area, a legitimate solar-powered network, an ordinary coal chest and optional
construction materials. They do not place the agent's modules, belts, inserters or poles.

- `s9_belt_routing.py` — straight/turning routes, unique tiles, real belt connections, engine-moved
  ore/coal, blocked endpoint, missing materials, cancellation and absence of transport-line
  mutation APIs in production code.
- `s10_inserters.py` — all six inserter roles and pickup directions, real pickup/drop targets, ore
  and plate movement, coal consumption, full output chest back-pressure and engine-driven resume.
- `s11_power_distribution.py` — missing powered network, real coverage/reach, preserved player
  wiring, real network membership and honest detection after removing generation.
- `s12_gear_production.py` — full iron ore → plate → gear production over ticks, exact paid cost,
  save/load during construction/material collection/monitoring, safety interruption and resume,
  death and resume, empty coal chest, distant/real player handling, batch material acquisition,
  and recovery from being inside a pending ghost or on a working belt.

Stage-6 runs use `game.speed = 60` by default. Observation windows for save/load/recovery briefly
use speed 1–5, then restore 60. Timeouts are phase-specific and deliberately short; they must not
be increased to compensate for a fast-forwarded simulation.

Impact-based regression policy used for Stage 6:

| Changed components | Scenarios selected |
| --- | --- |
| mining module entity direction | `s7`, `s8`, Stage-6 suite |
| `construction.find_real_entity` and approach geometry | `s5`, `s6`, `s7`, `s8`, Stage-6 suite |
| layout-planner shared finalization and `logistics_chain` mode | `s8`, Stage-6 suite |
| collaboration ghost filter | `s5`, `s6`, `s8`, Stage-6 suite |
| task persistence/checkpoint for the new composite task | `s12` save/load, safety, death and cancellation scenarios |
| Python-only reference and docs | fast checks only (no engine scenario) |

Tests not selected: `s1`–`s4` (lifecycle/RCON/gather), because those code paths were not changed by
Stage 6. This exception is valid only while the changed-file analysis above remains accurate.

## Pass criteria

Do not promote the mod beyond development status until all relevant checks pass on the actual Factorio 2.1.24 executable and the user's enabled mod set. Record the save copy, mod list, Factorio build, test actions, RCON logs, event payloads and before/after inventory counts.

## 10. Advanced logistics (Stage 7)

Run in the isolated Stage-7 profile (`FACTORIO_TEST_DIR=.../factorio-stage7-test`,
`FACTORIO_RCON_PORT=27078`, `FACTORIO_GAME_PORT=27039`). Use the clean
`saves/s7-baseline.zip` generated from the same 2.1.24 executable and mod set. The Stage-5
and Stage-6 worlds are not used by these automated scenarios.

Scenario prerequisites (`tests/engine/stage7_fixture.py`):

- all research on the disposable force;
- a cleared bounded test area around a real iron patch and a home point;
- a legitimate solar-powered network near the cell;
- an ordinary wooden chest containing 100 coal at the cell's relative coal position;
- optional construction materials in the agent inventory or an ordinary chest.

Prerequisites never create the agent's modules, belts, splitters, underground belts,
inserters, poles or output chest.

Scenarios:

- `s13_splitter_networks.py`
  - one-to-two splitter distribution to both furnaces;
  - two-to-one plate and gear merging;
  - real splitter type/direction and used/unused connector verification;
  - both consumers supplied and common output produced;
  - player building on a branch blocks the plan and is preserved;
  - a full output chest causes back-pressure and never a success result;
  - an empty coal chest reports depleted fuel and no fabricated production;
  - no transport-line mutation API in production code.
- `s14_underground_belts.py`
  - live yellow-belt `max_underground_distance = 5`;
  - minimum distance 1 and maximum distance 5 accepted, 6 rejected;
  - north/east splitter footprint and connector geometry;
  - distance-one real pair reciprocal neighbours;
  - paid construction of the expansion pair with input/output roles and travel direction;
  - coal physically crosses the pair to the second furnace;
  - a player-owned belt at the planned exit blocks the plan and is preserved.
- `s15_multi_consumer_expansion.py`
  - Stage-6 linear chain is built first and snapshotted;
  - Stage-7 multi-consumer cell is planned beside it on the same ore area;
  - both cells operate; old unit numbers/positions/directions are unchanged;
  - Stage-6 output chest keeps its production and the old factory still verifies entities
    and power;
  - all 14 Stage-7 routes, five splitters and one underground pair are connected;
  - both furnaces, both assemblers and the common output are verified.
- `s16_factory_persistence.py`
  - save/load during splitter and underground construction;
  - save/load during multi-consumer production monitoring;
  - repeated execution with no duplicate entities;
  - cancellation followed by a clean restart;
  - player-removed route is reported and not silently rebuilt;
  - safety pre-emption and explicit resume;
  - death, respawn and explicit resume;
  - exact paid entity counts and no duplicated materials.

Speed policy:

- routine construction/production scenarios use `game.speed = 60`;
- save/load windows, cancellation, safety and death run at `game.speed = 1..5` and restore
  60 after the timed window;
- human multiplayer uses `game.speed = 1` and is restored before acceptance.

Impact-based selection for Stage 7:

| Changed component | Selected scenarios |
| --- | --- |
| `lib/transport.lua` splitter/underground geometry | `s13`, `s14`, Stage-7 suite |
| route graph/status and `lib/logistics.lua` expansion planning | `s13`, `s15`, `s16`, `s9` |
| layout planner `multi_consumer` mode and site search | `s15`, `s16`, `s8` |
| `module_placer` stale-instance recovery | `s7`, `s8`, Stage-7 suite |
| paid construction underground post-build direction | `s14`, `s16`, `s5`, `s6` |
| composite task phases/result contract | `s13`, `s15`, `s16`, `s12` |
| MCP `execute_task(mode=...)` and docs | fast checks plus `s15` |

Directly affected historical regressions selected: `s5`, `s6`, `s7`, `s8`, `s9`, `s10`,
`s12`.

Not selected and reasons:

- `s1`, `s2`, `s3`, `s3b` — gather/lifecycle/safety controller internals were not changed;
  Stage-7 safety/death checkpoint behaviour is covered by `s16 F/G`.
- `s4`, `s4b` — RCON/MCP transport and restart code were not changed. Stage-7 MCP smoke is
  covered by the existing `s15` task path and fast tests.
- Full historical suite — the impact matrix above identifies the affected contracts; running
  every old scenario would not exercise a changed interface.

A skipped scenario is never recorded as PASS.
