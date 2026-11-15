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

Run one at a time (they share port 27075):

```
uv run python tests/engine/s3_death.py
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

Human multiplayer acceptance for Stage 5 is not part of this automated suite. It must use a real
Factorio client connected to the persistent isolated server; synthetic characters created by the
harness are only collision-avoidance test objects.

Each script prints its evidence and exits non-zero on failure.

## Optional diagnostics mod

`.runtime/factorio-test/mods/ae_probe/` is a read-only probe that records what the engine exposes
during a character death (`script-output/ae_probe.log`). It is only useful when debugging recovery
changes and is not required for the scenarios.
