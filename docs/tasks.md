# Task executor

## Example high-level request

task=gather_resource, resource=iron-ore, amount=100

The executor owns the complete sequence:

1. Validate the request and the agent state.
2. Find a suitable resource entity using the game's entity index/search.
3. Find a collision-free approach position and request a native Factorio path.
4. Follow the path using the character's normal movement state.
5. Mine using the normal mining state and measure the inventory delta.
6. If the deposit is exhausted, unreachable or invalid, find another candidate.
7. Stop only when the requested amount is collected or a bounded failure condition occurs.
8. Return one compact result with requested/collected counts, deposits used and reason.

All waypoint advancement, path completion, action polling, retries and phase changes remain inside Lua/Python. The LLM sees the final result only.

## Required safeguards

- Overall deadline and per-phase deadline.
- Stall detection based on inventory/position progress, not a tight fixed loop.
- Explicit cancellation by task ID.
- Idempotent task_start request ID handling.
- A single active foreground task per agent.
- Safety pre-emption and resumable task checkpoint.
- No false success: verify actual inventory delta.


## Construction assistance

Example high-level request: `task=assist_construction`

The executor owns the complete construction cycle:

1. Validate the agent and the absence of a safety emergency.
2. Scan only the code-configured work area around home (or the character when no home exists) for `entity-ghost` objects.
3. Reconcile the per-ghost ledger: new ghosts, ground-truth player completions, player cancellations and modified plans.
4. Select the nearest feasible target. A player character working near a target defers that target.
5. If the target position is blocked by a tree or rock, walk to it and clear it with `mine_entity`; refuse cliffs, chests and real player entities without destroying them.
6. Compute the exact item/quality requirement from `item_requests` or, for script-created ghosts, the entity prototype's `items_to_place_this`.
7. If materials are missing, find an ordinary accessible chest inside the work area whose contents include them, walk to it, and transfer only the still-missing items. No chest marker or reservation exists.
8. Verify capacity and actual counts. Return any uninserted remainder to the chest immediately.
9. Walk to the ghost's ring approach position and place only after the ghost still exists, the position is valid, the player is not working there and the full cost is present.
10. Consume exactly the required stacks, call `revive()` in the same tick, verify the real entity, and record the ghost as built. A failed revive refunds the exact stacks.
11. Reconcile again after every build/clear/transfer. A cancelled ghost is never recreated by the same task. A short settle re-scan precedes successful completion.
12. Return one compact result. No waypoints, inventory indices, entity handles or coordinates are exposed to the model.

## Physical logistics task

Example high-level request: `task=build_logistics, goal_item=iron-gear-wheel`

The composite task owns the complete physical production-chain cycle:

1. Resolve or reuse a linear logistics layout plan through the same production graph, catalog and
   module placer used by the Stage-5 planner.
2. Compute the physical plan: item belt routes, inserters, an ordinary coal chest feed and electric
   pole coverage. Fail early with `missing_fuel_source`, `missing_power_source`, `blocked_route` or
   `unsupported_chain`; no module or logistics ghost is created in those cases.
3. Apply the module ghosts and create tagged logistics ghosts for belts, inserters, poles and the
   output chest. No item is spent and no real entity is created by planning.
4. Reuse the Stage-3 construction loop with a ghost filter so only this task's module/logistics
   ghosts are built. Exact costs are paid from real inventory or ordinary chests; revival remains
   the only real-building path. The composite task aggregates all pending ghost costs and fetches
   the whole available shortfall in one chest trip (`acquisition_trips`), while payment remains
   per ghost. It also walks out of any pending ghost footprint or off a working belt before
   continuing (`step_out_count`, `belt_step_offs`, bounded `step_out_teleports`).
5. Retry a bounded number of pending ghosts after path/approach failures. Save/load resets in-flight
   `building` entries to `pending` and resumes without duplicating completed builds.
6. Verify, read-only, that belts are physically connected, inserters are powered, poles belong to a
   real powered network and the furnace is actually fuelled.
7. Monitor actual game ticks until a real iron gear wheel appears in the output chest. Ore, coal,
   plate and recipe evidence are recorded. Entity existence alone is never success.

Terminal statuses use the same runner-compatible set as other tasks. A `blocked` result carries a
reason such as `missing_power_source`, `missing_fuel_source` or `blocked_route`. The task result is
compact: connection counts, power/fuel status, production counts/evidence, required items and the
missing-material map. No coordinates, paths, entity handles or wire identifiers reach the LLM.

## Construction terminal results

- `succeeded`: all observed pending work is completed or already built/cancelled by players; `built_by_agent` is verified.
- `partial`: some objects were built but some work remains (missing materials, blocked site, player activity, inventory full).
- `missing_materials`: nothing could be built because the required placeable items are absent from the agent and accessible chests.
- `blocked`: construction is impossible for the observed state (unsupported ghost/item request, obstructing real entity, unreachable site or full inventory).
- `cancelled`: explicit cancel request. No new work starts after the terminal result.
- `interrupted_by_safety`, `interrupted_by_death`: the runner reports the independent emergency; the task remains paused and requires an explicit strategic resume.

## Construction safeguards

- Work-area and player-interference radii are lib constants, not LLM parameters.
- Cost is always paid from real inventory before `revive()`; no free revival path exists.
- Payment and revival are atomic within one tick.
- A failed build refunds exact stacks; a successful build is never refunded.
- Materials are transferred only from physically reached ordinary chests and only in needed quantities.
- Clearing is limited to natural trees/rocks through normal character mining; player entities, chests and resources are excluded.
- Safety pre-emption has unconditional priority. Completed ledger entries survive; in-flight targets are reset only on explicit resume.
- Save/load preserves the ledger, counters, chest transfers and in-flight target. A lost path request is retried a bounded number of times.
- The MCP surface remains one high-level `assist_construction` objective, not a per-building control API.

## Internal module instantiation

Stage 4 adds an internal, code-owned module path separate from the model-facing task API:

1. Resolve a stable module ID through the catalog (or fail closed with diagnostics).
2. Resolve parameter values and the requested supported orientation.
3. Validate the surface, hard blockers, reserved areas and declarative placement constraints.
4. Compute absolute entity positions internally from the module anchor.
5. Create only `entity-ghost` objects; spend no items and create no real entity.
6. Record a save-persistent instance identity and deduplicate identical calls.
7. Leave actual construction to the existing paid `assist_construction` executor.

The module operations (`module_catalog`, `module_definition`, `module_validate_definition`,
`module_resolve`, `module_instantiate`, `module_instance_status`, `module_instances`) are available
only through the internal RCON bridge. They are not MCP tools. A future Layout Planner may call
them internally after it has selected an intent; the LLM still supplies no coordinates or entity
lists.

See [module-format.md](module-format.md) and [module-library.md](module-library.md).

## Layout planning

Stage 5 adds two high-level model-facing objectives:

- `plan_layout(goal_item=...)` resolves the module dependency graph and a deterministic placement.
  It stores the plan and returns a compact summary. It creates no entity and spends no item.
- `apply_layout(plan_id=...)` revalidates the stored plan and asks the Stage-4 module placer for
  validated module ghosts only.

The planner owns dependency resolution, candidate generation, collision/player/ghost avoidance,
orientation selection, scoring, clearing-requirement recording, fingerprints and stale detection.
The model supplies no coordinates or module placements. Public summaries exclude anchors, ports,
entity lists and ghost unit numbers.

A plan has a stable `plan_id`, fingerprint and environment signature. Repeated apply is idempotent.
Player-built plan entities are recognised; player-cancelled plan ghosts are never recreated.
`stale_plan` is returned after any conflicting world change. Plans survive save/load.

The plan is not a working factory. Item/fluid edges are `route_required`; coal fuel and electric
infrastructure are explicit unresolved dependencies unless an existing network is detected. Paid
construction, clearing and material transfer remain the existing `assist_construction` executor.

See [layout-planner.md](layout-planner.md).

## Advanced physical logistics (Stage 7)

`execute_task(task="build_logistics", goal_item=..., mode="multi_consumer")` selects the
multi-consumer composite path. `mode` defaults to `"linear_chain"`, preserving Stage 6.

The task:

1. creates or reuses a `multi_consumer` layout plan;
2. plans all routes, splitters, the underground pair and power/fuel distribution;
3. checks real occupancy, player work areas and existing player infrastructure;
4. calculates the complete paid material set;
5. fetches missing materials through the ordinary-chest path;
6. creates ordinary ghosts for modules, belts, splitters, underground endpoints, inserters,
   poles and the common output chest;
7. builds them through the same paid executor as Stage 6;
8. verifies engine connectivity for every route, splitter and underground pair;
9. monitors actual ore/coal/plate flow, both furnaces, both assemblers, `products_finished`
   and the common output chest;
10. succeeds only after both consumers are supplied and real gear wheels reach the output.

Internal-only task parameters `plan_id` and `logistics_plan_id` allow the engine harness (and
a resumed internal run) to pin an already planned cell. They are not exposed by the MCP
`execute_task` schema.

The terminal result contains `mode`, `routes_connected`/`routes_blocked`, junction and
underground counts, `consumers` by ore/fuel/plate/gear, `consumers_supplied`,
`production_active`, `output_verified`, `power_status`, `fuel_status`, gear count,
per-machine production flags, missing materials and `further_work_possible`. It contains no
coordinates, entity indices or per-belt instructions.

Save/load during splitter/underground construction, production monitoring, cancellation,
safety interruption and death uses the same task checkpoint. A built plan is never rebuilt
silently: player-removed real entities and player-cancelled ghosts produce a blocked result.
See [advanced-logistics.md](advanced-logistics.md).
