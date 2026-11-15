# Stage 3 construction verification report

Date: 2026-11-15
Status: **IMPLEMENTED**, **UNIT TESTED**, **ENGINE TESTED**

Tested runtime: Factorio **2.1.24** (build 87808, Windows Steam binary), isolated write-data
directory `.runtime/factorio-test`. Mod set: base, elevated-rails, quality, recycler, space-age,
planet-express 2.1.12 and factorio_autonomous_engineer 0.1.0. `factorio_llm_use` is disabled in
this test profile. The RCON password was supplied only through the required
`FACTORIO_RCON_PASSWORD` environment variable and is not recorded in the repository or this report.

Tested mod archive: `dist/factorio_autonomous_engineer_0.1.0.zip`

- SHA-256: `<filled after final archive>`
- Git commit: `<filled after final commit>`

The archive was built from the committed mod sources. A rebuild from the same Git commit was
compared byte-for-byte with the tested archive; see “Archive and source correspondence” below.

## 1. Implemented

New modules:

- `mod/factorio_autonomous_engineer/lib/construction.lua` — ghost cost calculation, exact material
  consumption/refund, paid revival, work-area approach points, natural-obstacle classification,
  named code-owned test plan placement and real-entity verification.
- `mod/factorio_autonomous_engineer/lib/clearing.lua` — tree/rock classification and ordinary
  character `mine_entity` clearing with a proximity guard.
- `mod/factorio_autonomous_engineer/lib/collaboration.lua` — bounded work-area scan, per-ghost
  ledger, player build/cancel/change reconciliation, player interference detection and compact
  result aggregation.

Changed modules and Python:

- `lib/tasks.lua` — `assist_construction` task, construction state machine, chest acquisition,
  obstacle clearing, building, settle re-scan, save-persistent ledger, partial/missing/blocked
  results, resume/death/safety integration.
- `lib/safety.lua` — drops in-flight construction target on emergency while retaining the ledger.
- `lib/lifecycle.lua` — clears in-flight construction target if the character entity is lost.
- `control.lua` — construction capability, internal named-plan placement operation and
  capability-gated task start.
- `lib/strategy.lua` — advertises `assist_construction` on non-platform surfaces.
- `src/factorio_autonomous_engineer/server.py` — `execute_task(task="assist_construction")` with
  no coordinate parameters; compact construction status fields.
- `src/factorio_autonomous_engineer/runner.py` — terminal `partial`, `missing_materials` and
  `blocked` results.
- `tests/test_runner.py` — terminal-status unit tests.
- `tests/engine/harness.py`, `tests/engine/s5_construction.py`,
  `tests/engine/s6_construction_persistence.py` — construction engine scenarios and helpers.

Documentation and skills updated: `docs/architecture.md`, `docs/tasks.md`, `docs/safety.md`,
`docs/engine-test-plan.md`, `docs/strategy-layer.md`, `docs/roadmap.md`, `README.md`,
`tests/engine/README.md`, `skills/core_strategy.md`, `skills/stages/early_game.md`,
`skills/stages/automation_bootstrap.md`, `skills/stages/automation.md`.

## 2. API findings and technical decisions

- The agent remains a standalone `LuaEntity` character, not `LuaPlayer`. Consequently
  `LuaControl.build_from_cursor` is unavailable, as expected by the stage constraints.
- `LuaEntity.revive()` in Factorio 2.1.24 creates the real entity/tile as a script action and does
  **not** charge the normal construction cost. It returns `(items_collided_with, entity,
  item_request_proxy)`; in successful base-entity revivals the first value was an empty table and
  the proxy was `nil`.
- For script-created ghosts `item_requests` is empty; the exact base item comes from the inner
  entity prototype's `items_to_place_this`. Player/blueprint ghosts expose `item_requests`.
  Both paths are implemented.
- Item quality is taken from each request, or from `ghost.quality.name` for script-created ghosts.
  An engine probe confirmed an uncommon ghost consumed an uncommon `stone-furnace` item and
  produced an uncommon real furnace.
- `insert_plan` is checked before payment. Non-empty insert plans (modules/equipment/ammunition)
  are refused as `unsupported_ghost_insert_plan`. Extra item requests that do not exactly match
  the prototype base cost are refused as `unsupported_extra_item_requests`, so the executor never
  charges for items it cannot insert.
- A ghost is only revived after `surface.can_place_entity(..., build_check_type=ghost_revive)`
  succeeds, the character is physically within build reach, the full exact cost is present, and
  no player is working at the target.
- No production code calls `surface.create_entity` for a real building. Ghost-only plan placement
  uses `surface.create_entity{name="entity-ghost", inner_name=...}`. The engine harness may create
  real entities or revive a ghost directly only as scenario setup.
- `ghost.bounding_box` in 2.1.24 reports the inner entity's footprint and was used to find actual
  obstacles.
- `LuaControl.can_reach_entity` is not a reliable distance guard for ghosts (it returned true from
  far away), so the executor enforces walk/path arrival and explicit distance limits itself.
- `LuaControl.mine_entity` awards the normal tree/rock products to the character inventory, but
  script mining also works from outside normal reach; `clearing.lua` therefore rejects calls when
  the character is more than four tiles from the obstacle.
- Chest inventories are accessed through `defines.inventory.chest` on ordinary `container` and
  `logistic-container` entities. `infinity-chest` is excluded. No marker, whitelist, reservation
  flag or special permission is used.

## 3. Material charging and transfer

Build:

1. Read requirement list (item name, count, quality) from the live ghost.
2. Verify every requirement is present in the character main inventory.
3. Remove each exact stack with `LuaInventory.remove`; compare the returned count to the requested
   count.
4. If any removal is short, refund every already removed stack and refuse the build.
5. Call `ghost.revive()` in the same game tick.
6. If revival fails before a real entity exists, refund the exact removed stacks.
7. If a real entity exists after a script error, do not refund (this avoids a free building).
8. Verify the ghost is gone and the real entity is valid; record `built` plus the real unit number.

Chest acquisition:

1. Compute only the still-missing items for the selected ghost.
2. Refuse to approach if the main inventory cannot accept even one unit.
3. Walk to a physically reachable ordinary chest inside the work area.
4. For each missing item, remove at most the missing count, then insert into the character main
   inventory.
5. If insertion is partial, immediately return the uninserted remainder to the same chest.
6. Track only actually inserted counts and re-read the live inventory on the next decision.
7. Recompute requirements after every transfer and after every save/load.

## 4. Engine scenario results (observed)

All commands were run against disposable copies of `.runtime/factorio-test/saves/baseline.zip`.
The scripts print evidence and exit 0 only when every check passes.

### `tests/engine/s5_construction.py`

Result: **50 checks, 0 failed — PASS**

- A — plan placement: 3 ghosts (`stone-furnace`, `wooden-chest`, `transport-belt`) created; 0 real
  buildings; inventory `{} -> {}`.
- B — own materials: 3 real objects built; inventory
  `{stone-furnace 7, wooden-chest 5, transport-belt 4}` became
  `{stone-furnace 6, wooden-chest 4, transport-belt 3}`; agent moved 33.41 tiles to the work area;
  no duplicate entities or ghosts.
- C — chest supply: an unmarked wooden chest lost exactly the required `stone-furnace`; agent built
  the furnace; agent inventory empty afterwards.
- C2 — partial supply: two ghosts, one supplied item; result `partial`,
  `missing_materials={stone-furnace:1}`, one build, one ghost left, chest emptied exactly once.
- C3 — full inventory: result `blocked` / `inventory_full`; ghost remained; chest still contained
  its item; nothing was built or lost.
- D — no materials: result `missing_materials` with `stone-furnace:1`; ghost remained; no real
  building; inventory unchanged.
- E — player blueprint: one ghost was already built by the player; agent built the other two; total
  real belts = 3; no duplicate at the player-built position; all ghosts resolved.
- F — player changes during movement: one ghost cancelled, one built by the player, third replaced
  by a `stone-furnace` ghost. Result `succeeded` with `built_by_agent=1`, `already_built=1`,
  `cancelled=2`; cancelled ghost absent; player-built belt exactly once; replacement furnace built;
  only the replacement cost (`stone-furnace`) was consumed; 3 belts remained in inventory.
- G — clearing: tree and rock both removed with `obstacles_cleared={tree-01:1,big-sand-rock:1}`;
  inventory gained wood (4) and stone (25); two belts built; adjacent player chest and real furnace
  remained intact.

### `tests/engine/s6_construction_persistence.py`

Result: **44 checks, 0 failed — PASS**

- H1 — save/load during clearing: task id preserved, task still running after load with
  `built_by_agent=1` and one remaining ghost; final success; 3 belts built exactly once; no ghost;
  cleared wood/stone survived.
- H2 — save/load after chest transfer, before building: chest already empty before save, agent held
  exactly one `stone-furnace`; after load still exactly one; final one furnace built, chest not
  debited again, agent inventory empty.
- H3 — safety: runner returned `interrupted_by_safety`; task paused for safety; after enemies were
  cleared the task stayed paused with `awaiting_llm_resume`; explicit resume built all 3 objects
  once.
- H4 — cancel during movement: status `cancelled`, walking stopped, ghost remained, inventory
  unchanged, nothing built.
- H5 — player working: agent built the free site only (`partial`, `player_interference`); occupied
  ghost and player character remained; after removing the test player and re-running, the second
  site was built; total exactly two belts.
- H6 — player withdraws chest materials: agent transferred one item and built one furnace; player
  removed the second item; final `partial` / `missing_materials={stone-furnace:1}`, one furnace,
  one ghost; no duplication.
- H7 — death/respawn: task paused with reason `death`; all 3 belts restored after respawn; explicit
  resume built all 3 once; inventory empty afterwards.

### Existing regression scenarios

The previously existing engine scripts were re-run on the same archive:

- `s1_save_load.py` — PASS
- `s2_attack.py` — PASS
- `s3_death.py` — PASS
- `s3b_unsafe_home.py` — PASS
- `s4_rcon.py` — PASS
- `s4b_mcp_restart.py` — PASS

## 5. Unit tests and Ruff

- `uv run pytest -q tests` — **11 passed**
- `uv run ruff check .` — **All checks passed**
- `uv run python -m unittest discover -s tests -v` — **11 tests, OK**

Unit tests cover the private runner polling contract, terminal construction statuses
(`partial`, `missing_materials`, `blocked`) and skill loading. They are not claimed as proof of
Factorio gameplay behaviour; that proof is in section 4.

MCP stdio smoke check: `tools/list` exposed the same 7 tools, and one real
`execute_task(task="assist_construction")` call over the stdio MCP server returned the single
terminal result `{"status":"succeeded","built_by_agent":1,"remaining":0}`. `strategy_context`
advertised `assist_construction` with `coordinates_exposed_to_model=false` and
`low_level_game_actions_exposed=false`.

## 6. Unsupported object types and known limitations

- Tile ghosts are ignored by the entity-ghost scanner; no tile construction is implemented.
- Ghosts with a non-empty `insert_plan` (modules, equipment, ammunition or other insert requests)
  are refused rather than partially built.
- Ghosts whose item requests differ from the prototype base cost are refused.
- Cliffs and any real player entity/chest blocking a site are reported as blocked; they are never
  mined, deconstructed or destroyed.
- Only trees and natural rocks are clearable automatically. Explosives are not used.
- Only base placeable-item construction is supported. Crafting placeable items from raw wood/stone/
  ore is not part of this stage.
- Materials are not taken from logistic networks, construction robots, vehicles, linked containers
  or infinity containers. Only physically reached ordinary chests are used.
- The scanner is confined to `WORK_RADIUS` (currently 64 tiles) around home/agent; no global scan
  or arbitrary world-wide work is offered.
- The player-interference radius is a conservative implementation constant (currently 8 tiles).
- Direction is passed to ghost revival and plan placement; only north-facing furnaces/chests and
  east-facing belts were exercised in the recorded scenarios.
- Blueprint books, arbitrary belt/pipe layout, power wiring, module insertion, construction robots,
  automatic deconstruction, full base generation and remote logistics remain out of scope.
- A save made during the short path-request window is handled by a bounded path retry, but the
  recorded save/load scenarios exercise clearing, post-transfer walking and completed-object
  persistence rather than every possible mid-request tick.
- Player-built objects that existed before the task started are not retroactively counted in
  `already_built`; they are simply never duplicated. Only objects whose ghost was observed and then
  completed by someone else are counted there.

## 7. Next-stage work

- Layout Planner and blueprint-book ingestion behind composite build tasks.
- Module/equipment item-request-proxy support with post-revival verification.
- Construction-robot and logistic-network delivery.
- Arbitrary belt/pipe/rail geometry and entity-specific placement requirements (fluids, rails,
  offshore pumps, circuit connections).
- Richer player-presence detection (players controlling vehicles/spidertrons) and work-area policy.
- Multi-surface construction policy only after planet-specific validation.
