# Engine reliability scenarios

Python unit tests cannot prove Lua/gameplay behaviour. These scenarios drive a **real Factorio 2.1
headless server** through the mod's RCON bridge and assert on observable state only (MCP tool
results, `agent_status`, event queue, character inventories).

They are deliberately outside `tests/` discovery: `python -m unittest discover -s tests` must stay
fast and engine-free.

## Prerequisites

1. Factorio 2.1 with `bin/x64/factorio.exe` (`FACTORIO_BIN` overrides the default Steam path).
2. An **isolated write-data directory** — never the player's real one:

   ```
   <repo>/.runtime/factorio-test/
     config/config.ini          # read-data -> install, write-data -> this directory
     config/server-settings.json
     mods/                      # packaged mod + mod-list.json (+ optional ae_probe diagnostics)
     saves/baseline.zip         # disposable map, created with the test mod set
   ```

   `FACTORIO_TEST_DIR` overrides the location. `FACTORIO_RCON_PASSWORD` is **required** — the
   password is never stored in the repository, so export it before running a scenario and use the
   same value in the server command line below.

3. RCON must be enabled **on the command line**. A `"rcon"` block in `server-settings.json` is
   ignored by 2.1.24 and the server then starts without a listener:

   ```
   factorio.exe --config <dir>/config/config.ini --mod-directory <dir>/mods \
     --start-server <dir>/saves/<save>.zip --server-settings <dir>/config/server-settings.json \
     --rcon-bind 127.0.0.1:27075 --rcon-password <password>
   ```

   `--rcon-port` cannot be combined with `--rcon-bind`.

`harness.py` starts and stops the server, creates scenario copies of `baseline.zip`, and provides
inventory/equipment snapshots plus biter attack helpers. Every scenario copies the baseline, so
scenarios never inherit each other's state.

## Scenarios

| Script | Asserts |
| --- | --- |
| `s1_save_load.py` | hard kill + reload while mining: task id/phase/collected survive, task finishes with the exact requested amount, no double counting |
| `s2_attack.py` | biter attack during gathering: task paused by safety, `interrupted_by_safety` returned to the caller, evacuation to a safe destination, `agent_under_attack` / `emergency_resolved` events, explicit resume completes the task, firing only with gun+ammo and health above 30 % |
| `s3_death.py` | death recovery: main/guns/ammo/armor and armor-grid equipment restored exactly once, new unit number, task paused with reason `death`, resume gathers the remaining amount |
| `s3b_unsafe_home.py` | respawn holds at `waiting_for_safe_spawn` / `home_under_threat` while hostiles sit in the home radius, then completes once the area is clear |
| `s4_rcon.py` | replay of the same `request_id` returns the cached response instead of a second task (deduplication is request-id scoped, not a general exactly-once guarantee), cache survives save/load, connection loss raises a bounded error carrying the request id, reconnect works, wrong password and missing server report clearly |
| `s4b_mcp_restart.py` | SIGKILL of the MCP client mid-task: the task keeps its id, a fresh MCP process reports it, and the remaining amount completes exactly |
| `s5_construction.py` | scenarios A–G: ghost-only plan placement, paid builds, ordinary-chest acquisition, missing materials, full inventory, player blueprints, player cancellations/builds/plan changes, tree/rock clearing and preservation of nearby player entities |
| `s6_construction_persistence.py` | scenario H: save/load during clearing and after a chest transfer, safety pre-emption + explicit resume, cancel, player interference, player chest withdrawal and death/respawn with construction materials |
| `s7_module_catalog.py` | Stage 4 A–E: catalog loading and invalid-definition diagnostics, ghost-only instantiation of all modules, geometry/orientation/port/reserved-area checks, collision and resource constraints, paid module construction with recipe configuration, save/load instance identity/deduplication and construction resume |
| `s8_layout_planner.py` | Stage 5 A–E: live iron-gear dependency chain, all mining orientations, resource-patch placement, building/player-ghost/player-work-radius avoidance, clearing requirements, deterministic fingerprints, ghost-only apply, idempotent repeated apply, save/load, cancellation/build reconciliation, stale-plan rejection and the compact MCP `plan_layout` surface |
| `s9_belt_routing.py` | Stage 6 A: real belt routing/turns, unique tiles, engine belt connections, ore/coal on transport lines, blocked route endpoints, missing materials, cancellation and no transport-line mutation API in production |
| `s10_inserters.py` | Stage 6 B: six inserter roles and pickup directions, real pickup/drop targets, ore/plate movement, coal consumption, full output chest back-pressure and engine-driven resume |
| `s11_power_distribution.py` | Stage 6 C: missing power source, pole coverage, legal wire reach, preserved player wiring, real network membership and unpowered detection after supply removal |
| `s12_gear_production.py` | Stage 6 D: full ore→plate→gear production over ticks, exact paid costs, save/load during construction/material collection/monitoring, safety/death interruption, empty coal chest, player route conflict, distant-player planning, one-trip batch material acquisition, walk-out from a pending ghost and walk-off a working belt; scenario L resumes while the character stands inside a pending module ghost and asserts a bounded recovery (no request storm) |
| `s13_splitter_networks.py` | Stage 7 A: one-to-two splitting, two-to-one merging, both consumers supplied, common output, splitter type/direction/connectors, blocked branch preservation, full-output back-pressure, depleted fuel and no transport-line mutation |
| `s14_underground_belts.py` | Stage 7 B: live yellow-belt reach, min/max distance, over-range rejection, splitter geometry, reciprocal underground neighbours, paid pair construction and coal transfer, player-owned endpoint protection |
| `s15_multi_consumer_expansion.py` | Stage 7 C: working Stage-6 chain plus parallel multi-consumer cell, both factories operational, unchanged old units, all 14 routes/splitters/underground pair connected, merged gear output |
| `s16_factory_persistence.py` | Stage 7 D: save/load during construction and production, repeated execution, cancellation/restart, player-removed route, safety and death recovery without duplication |
| `s17_movement_pathfinding.py` | Stage 7.1 A/B: live build reach, native path requests, waypoint arrival, bounded unreachable routes, cancellation |
| `s18_movement_recovery.py` | Stage 7.1 recovery: aligned belts without step-off, conflicting belt displacement and target resume, ghost step-out, bounded blocked routes, save/load and safety during belt recovery |
| `s19_construction_work_zones.py` | Stage 7.1 C: live-reach zones, floating positions, batch construction and occupied-position reselection |
| `s20_movement_persistence.py` | Stage 7.1 D: movement/task persistence, cancellation, safety, death/respawn and sole `walking_state` writer audit |
| `s21_sequential_task_isolation.py` | immediate task restart, fresh task/movement IDs, per-task work-zone ledgers and stale callback rejection |

Run one at a time (they share RCON/game ports inside a profile). Never point two profiles at the
same RCON port. `stop_server()` terminates only the Factorio process whose command line contains the
selected `FACTORIO_TEST_DIR`, so a separate Stage-5 acceptance server can remain running.

```
FACTORIO_TEST_DIR="$PWD/.runtime/factorio-test" FACTORIO_RCON_PASSWORD=... FACTORIO_RCON_PORT=27075 FACTORIO_GAME_PORT=34197   uv run python tests/engine/s3_death.py
```

Stage-6 targeted runs use an isolated profile different ports, and `game.speed=60` for speed:

```
FACTORIO_TEST_DIR="$PWD/.runtime/factorio-stage6" FACTORIO_RCON_PASSWORD=... FACTORIO_RCON_PORT=27076 FACTORIO_GAME_PORT=27037 FACTORIO_GAME_SPEED=60   uv run python tests/engine/s12_gear_production.py
```

`harness.py` also provides construction setup helpers: `place_plan`, `create_ghost`, `cancel_ghost`, `build_ghost_as_player`, `create_chest`, `chest_contents`, `remove_chest_items`, `create_natural`, `create_player_character`, `give_items`, `fill_main_inventory`, `ghosts`, `entities_named` and `wait_task`. Direct ghost revival in `build_ghost_as_player` and direct `surface.create_entity` calls in setup are harness-only scaffolding; production construction uses paid ghost revival.

Stage-4 module helpers: `module_catalog`, `module_definition`, `module_validate`,
`module_resolve`, `module_instantiate`, `module_instance_status`, `module_instances`,
`research_all` (test scaffolding on the disposable force) and `find_resource_anchor`. Module
operations are internal RCON operations, not model-facing MCP tools. `research_all` is only for
engine test setup; it is not part of the agent's normal capability set.

Stage-5 Layout Planner helpers: `plan_layout`, `apply_layout`, `layout_plan_status`,
`layout_plans`, `plan_layout_public`, `apply_layout_public`, `ghost_tags`, `real_counts` and
`set_home`. The create/apply/status/limits operations are internal RCON operations. `set_home` is an
administrative test/setup operation, not a model-facing MCP tool. The public projections are the
same compact summaries returned by the `plan_layout` and `apply_layout` MCP tools.

Stage-6 helpers live in `harness.py` and `stage6_fixture.py`. `stage6_fixture.prepare()` creates a
disposable save, all research, a clear test area, a legitimate solar-powered electric network and
an ordinary coal chest. It never places modules, belts, inserters or poles for the agent. The agent
must build the chain through `build_logistics`. Internal RCON helpers are `layout_chain_plan`,
`logistics_plan_create`, `logistics_plan_status`, `logistics_ghosts_place`, `logistics_verify`,
`logistics_plans`, `task_debug` and `task_entries`; they are not model-facing tools.

Stage-7 helpers live in `stage7_fixture.py`. `prepare()` loads the clean `s7-baseline.zip`, clears a
test area, creates a legal solar network and an ordinary coal chest, creates/applies a
`multi_consumer` layout plan and creates the physical plan. It does not build the cell. The agent
builds every module and logistics entity through `build_logistics(mode="multi_consumer")`.
Internal helpers are `layout_multi_consumer_plan`, `logistics_plan_expansion`,
`transport_probe`, `task_cancel` and `task_resume`. `transport_probe` only returns deterministic
geometry/pair plans; it never creates or mutates an entity or transport line.

Human multiplayer acceptance for Stage 5 is not part of this automated suite. It must use a real
Factorio client connected to the persistent isolated server; synthetic characters created by the
harness are only collision-avoidance test objects.

Each script prints its evidence and exits non-zero on failure.

## Optional diagnostics mod

`.runtime/factorio-test/mods/ae_probe/` is a read-only probe that records what the engine exposes
during a character death (`script-output/ae_probe.log`). It is only useful when debugging recovery
changes and is not required for the scenarios.


## Stage-7 isolated run

Create a clean baseline once with the same Factorio 2.1.24 executable and mod set:

```
factorio.exe --config <s7>/config/config.ini --mod-directory <s7>/mods   --create <s7>/saves/s7-baseline.zip
```

Then run a Stage-7 scenario in the isolated Stage-7 profile:

```
FACTORIO_TEST_DIR="$PWD/.runtime/factorio-stage7-test" FACTORIO_RCON_PASSWORD=... FACTORIO_RCON_PORT=27078 FACTORIO_GAME_PORT=27039 FACTORIO_GAME_SPEED=60   uv run python tests/engine/s13_splitter_networks.py
```

Stage-7 scenarios use speed 60 except save/load, cancellation, safety and death windows, which
temporarily use speed 1–5 and restore 60. A skipped scenario is never reported as PASS.


## Stage-7.1 isolated run

Use the separate `factorio-stage71-test` profile and its `s71-baseline.zip`; do not reuse or alter
Stage-5/6/7 human saves or servers. Routine scenarios run at speed 60, with recovery and save/load
windows at speed 1–5.

```
FACTORIO_TEST_DIR="$PWD/.runtime/factorio-stage71-test" FACTORIO_RCON_PASSWORD=... \
FACTORIO_RCON_PORT=27079 FACTORIO_GAME_PORT=27040 FACTORIO_GAME_SPEED=60 \
  uv run python tests/engine/s18_movement_recovery.py
```

`s18` scenario E (safety pre-empting an active belt recovery) is a known pre-existing flake: a run
can exceed the 120 s wall-clock wait while the character crosses a dense belt field toward the
escape point. The same failure rate was reproduced on the pre-stabilization checkpoint. A failing
run is recorded as FAIL and never reported as PASS.

`s15` emits bounded transition/periodic timelines for both sequential logistics tasks. Each task's
counter baseline is captured immediately before `task_start`; snapshots include deadline remaining,
phase, movement owner/state, zone, path/callback/retry/recovery counters, sampled distance, builds,
acquisition trips and terminal tick. At most 64 nonterminal samples plus the terminal sample are
printed per task. `s21` uses the internal `movement_path_callback` diagnostic to deliver a stale
request ID directly to the production callback handler. `s18` uses the one-shot
`movement_save_on_recovery` diagnostic to save from the mod's normal tick order when persistent
recovery metadata is present. None of `movement_path_callback`, `movement_save_on_recovery` or
`movement_request` is an MCP tool.
