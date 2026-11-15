# Architecture

## Strategic control plane

The LLM is a planner. get_briefing obtains a code-generated profile containing the current planet/domain, progression stage and evidence, base maturity, agent lifecycle and allowed capabilities. Python loads matching plain-Markdown stage and planet skills. The model gets the skill text and strategic summary, not server source or raw game state.

The current capability set includes a Nauvis bootstrap-site selector, a high-level resource gathering goal and a high-level construction-assistance goal. Each mutating operation is checked again inside the Factorio mod; stale or unsupported capability requests fail closed.

The LLM does not choose coordinates, routes, approach positions, inventory slots, mining steps, ghost placement points or per-building costs. The site selector evaluates resource patches, water, collisions, hostile entities and generated-chunk coverage. The gather executor owns resource search, pathfinding, movement, mining, retries and actual inventory-delta verification. The construction executor owns ghost discovery, material accounting, chest access, clearing, movement and placement.

## Construction through ordinary ghosts

Construction follows Factorio's normal ghost model. The executor creates only `entity-ghost` objects for its own named test plans. A ghost placement alone creates no real entity and spends no items. Player-placed blueprint ghosts are discovered inside a code-configured work area centred on the registered home position (falling back to the character position when no home exists). The radius is a lib constant; the model cannot supply coordinates or widen the scan.

`lib/construction.lua` computes the exact item cost from the ghost's `item_requests`, or from the inner entity prototype's `items_to_place_this` for script-created ghosts. It supports base construction items by name and quality. Modules, equipment and other extra item requests are refused with an explicit `unsupported_extra_item_requests` reason instead of being silently dropped; a non-empty `insert_plan` is likewise unsupported in this stage.

The agent is a `LuaEntity` character, not a `LuaPlayer`; `LuaControl.build_from_cursor` is unavailable. `LuaEntity.revive()` is a script operation that would otherwise create a free building. The executor therefore removes exactly the required items from the character main inventory, verifies every removal, calls `revive()`, verifies the resulting entity and ghost state, and refunds exact stacks if the revival fails before creating the entity. Payment and revival happen in one game tick, so save/load cannot split them. `surface.create_entity()` is never used to create a real building in production code; the engine harness may use it or revive ghosts directly only for scenario setup.

`lib/collaboration.lua` reconciles a stable per-ghost ledger keyed by unit number. A ghost that disappears is counted as already built when a matching real entity now occupies the position, otherwise as cancelled. Cancelled ghosts are never recreated by the same task. New or changed ghosts are added on a later scan. A short settle window before success catches near-simultaneous player cancel/place sequences. A player character within the code-configured interference radius defers that target; the rest of the free work can continue.

`lib/clearing.lua` removes only natural trees and rocks through `LuaControl.mine_entity`, after walking into range. Resources, chests and all player real entities are excluded. Unsupported blockers (cliffs, buildings, chests) are reported instead of destroyed. The resulting items enter the character inventory and participate in the same economy as other materials.

Ordinary chests are searched by entity type (`container` and `logistic-container`) within the work area. No chest marker, whitelist, reservation or special permission exists. The executor walks to the selected chest, removes only the still-missing items, inserts them into the character inventory and returns any uninserted remainder immediately. Chest filters are untouched. Infinity containers are excluded. No logistic network or remote extraction is used.

## Declarative module library

`lib/module_format.lua` defines the canonical schema for reusable factory modules. A module is a
pure declarative Lua data table under `modules/`, listed once by `modules/manifest.lua`. It describes
stable identity/version, category, supported surfaces/stages, a local anchor and footprint, entity
positions/directions/quality/recipe, item/fluid/electric ports, supported orientations, reserved
areas, technology/recipe/stage requirements and declarative placement constraints. It contains no
functions or arbitrary expressions.

`lib/modules.lua` loads the parse-time preloaded library, rejects duplicate IDs and invalid
definitions, resolves stable IDs and reports force/surface/stage availability separately from
prototype existence. An invalid module is excluded entirely rather than partially interpreted.
`lib/module_placer.lua` validates the target surface, parameters, orientation, hard blockers and
supportable placement constraints, then creates **only** entity ghosts. It records module identity,
instance key, anchor, orientation, resolved parameters, expected settings and ghost unit numbers in
`storage` for reconciliation after save/load. Identical instantiations are deduplicated; an
instance-key conflict is rejected.

Module instantiation never creates real entities and never spends items. The existing
`assist_construction` task and `lib/construction.lua` remain the only paid build path. A module ghost
may carry a recipe tag; the executor applies that recipe with `set_recipe` after the paid revival
and records a configuration error if it cannot. The construction result now reports
`configuration_errors`, while module instance status distinguishes pending, built, missing,
configuration mismatch and geometry mismatch.

The module catalog/instantiation operations are internal RCON operations for tests and future
code-owned planners. They are not MCP tools; the LLM receives neither absolute placement
coordinates nor raw entity lists. The model continues to assist player-created blueprints through
the same `assist_construction` objective.

## Shared-world collaboration

Player actions are reconciled against the same ghost and entity objects. The executor does not delete, deconstruct or reconfigure player buildings. A player completion is recognized by the real entity at the ghost position, a cancellation by the absence of both ghost and replacement entity, and a blueprint change by a new ghost identity. Player presence near a target defers that target rather than racing the player. Materials removed by a player from a chest are observed through the actual inventory counts at transfer time.

## Work-area limits

The construction scanner is bounded by `WORK_RADIUS` in `lib/collaboration.lua`. Player interference uses `PLAYER_WORK_RADIUS`. These values are implementation constants, not LLM parameters. The executor does not scan the world, place arbitrary layouts, use construction robots, use logistic logistics or perform automatic deconstruction.

## Control-plane separation

The LLM selects milestones and high-level goals. The MCP server exposes a small, abstract tool surface. The Factorio mod owns the task state machine and game mechanics. Lua runs the task, safety, site-selection and lifecycle controllers on game ticks. The model must not orchestrate waypoints, action-status polls, mining ticks, crafting queues or inventory transfers.

## Task execution contract

execute_task is one MCP call. Python sends task_start, then polls task_status privately until a terminal result or a safety interruption. Those internal RCON calls are not returned as separate tool messages. A task has a stable ID and a save-persistent state in the Factorio mod. If the MCP process disconnects, the task continues in Factorio; a later client can inspect the status by task ID.

Terminal task results: succeeded, failed, cancelled, partial, missing_materials, blocked, interrupted_by_safety, interrupted_by_death. `assist_construction` distinguishes full success, partial completion, missing materials, impossible/blocked construction, player interference, inventory-full and cancellation. Its result also carries `configuration_errors` for module ghosts whose post-revival recipe could not be applied and verified. Nonterminal phases include searching, pathing, moving, clearing, acquiring, building, settling, waiting-for-player, paused, evacuating and respawning.

## Safety priority

Safety controller is ticked before ordinary task execution. It can suspend an active task, stop walking/mining, override movement and start defensive fire if an equipped weapon and ammunition are available. The controller itself is not an MCP call and does not wait for the LLM.

## Persistence

Only serializable task data, IDs, counters, positions, and valid Factorio LuaObjects belong in storage. Python process memory is not authoritative. The Factorio save is the source of truth for agent identity, active task, event queue, recovery inventory and respawn state. Construction keeps a per-ghost ledger, paid-once build status, obstacle/transfer counters and the in-flight target in that state. On safety pre-emption or death the in-flight target is dropped but completed ledger entries survive; an explicit resume resets only in-flight entries and re-scans.

## RCON boundary

RCON is restricted to loopback addresses. Each request has an ID and the Factorio mod caches responses so a retry with the same request ID does not repeat a completed command. No password is stored in the repository or exposed in MCP schemas.

## Why not a real LuaPlayer?

The runtime API's LuaPlayer represents a game player and supports player controller, GUI and respawn members. The current mod creates a standalone character entity. Factorio 2.1.24 does not document a game.create_player runtime method, so a mod cannot simply manufacture a fully fledged synthetic player. This project keeps the separate character and explicitly emulates only the lifecycle and gameplay capabilities it needs.
