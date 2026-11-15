# Physical logistics (Stage 6)

Status: **IMPLEMENTED**, **UNIT TESTED**, **AUTOMATED ENGINE TESTED** on Factorio 2.1.24.
Human multiplayer acceptance is a separate gate and is not implied by the automated results.

Stage 6 turns the logical item connections of a Stage-5 layout plan into real Factorio
infrastructure. The model-facing objective is one composite task:

```text
execute_task(task="build_logistics", goal_item="iron-gear-wheel")
```

The LLM receives one terminal result. It never receives coordinates, tile sequences, entity
references, unit numbers, wire connector identifiers or per-belt instructions.

## 1. What is real and what is not

The agent builds and the engine moves:

- electric mining drill → transport belt;
- belt → inserter → stone furnace;
- actual coal chest → inserter → belt → inserter → furnace;
- furnace → inserter → belt → inserter → assembling machine;
- assembling machine → inserter → output chest;
- electric poles with real supply areas and copper-wire reach connections.

The planner never creates a completed building, never inserts items into a transport line or a
machine inventory, never changes crafting progress, never fabricates energy and never bypasses the
paid construction executor. `LuaTransportLine` is not used by production code at all: observation
is done through `LuaEntity.get_transport_line()` only in defensive verification helpers, and the
mod contains no `insert_at`, `force_insert_at`, `remove_item` or `clear` call on transport lines.

The automated scenarios create a **pre-existing** solar-powered electric network and an ordinary
coal chest as scenario prerequisites. Those fixtures are distinguished from agent-built
infrastructure. The agent does not build generators and does not mine coal in this stage.

## 2. Implementation files

| File | Responsibility |
| --- | --- |
| `mod/factorio_autonomous_engineer/lib/logistics.lua` | Deterministic route search, physical plan, inserter/pole/fuel geometry, ghost placement, read-only verification and observations. |
| `mod/factorio_autonomous_engineer/lib/layout_planner.lua` | Internal `logistics_chain` planning mode that places a linear eastward module chain with exact physical gaps. The generic Stage-5 planner is unchanged by default. |
| `mod/factorio_autonomous_engineer/lib/tasks.lua` | Composite `build_logistics` task phases, construction orchestration, retries, verification, monitoring and persistence. |
| `mod/factorio_autonomous_engineer/lib/collaboration.lua` | Optional task ghost filter so a composite task builds only its own module and logistics ghosts. |
| `mod/factorio_autonomous_engineer/lib/construction.lua` | Exact-position real-entity reconciliation and an approach point that is guaranteed outside the target footprint. |
| `src/factorio_autonomous_engineer/logistics.py` | Python reference for deterministic A*, turns and gap/endpoint arithmetic. |
| `tests/test_logistics.py` | Fast unit tests for the reference implementation. |

The mining module was corrected in Stage 6: `nauvis.electric_mining.iron` now gives the drill
entity direction east (`4`). The Stage-4 definition declared an east `ore_output` port but pointed
the real drill north, so the engine dropped ore above the module. All advertised rotations rotate
both the entity and the port consistently.

## 3. Layout chain and physical gaps

The internal chain planner reuses the Stage-5 production graph and module catalog. It supports a
strict linear eastward chain whose first step is a catalog mining module. For the initial goal:

```text
mining_1 → smelting_1 → production_1
```

A producer and consumer are separated by exactly the tiles needed by real inserter geometry:

- direct drill output: `[belt]` then a consumer input inserter if needed;
- crafting-machine output: `[output inserter] [belt]`;
- consumer crafting machine: `[input inserter]`.

For `drill → furnace` the gap is 2 tiles. For `furnace → assembler` it is 3 tiles. Every module
anchor shares the same row; the belt row is `anchor.y + 1.5`. The layout plan stores this as
`logistics = {mode="linear_chain", belt_row=..., flow="east"}`. The plan remains a normal
save-persistent Stage-5 plan with module/edge/port records.

Supported orientation is 0 (eastward flow). Other item-flow directions, branching chains and
non-mining first steps are reported as `unsupported_chain` rather than guessed.

## 4. Belt routing

The router is a bounded cardinal A* on tile centers.

- Neighbour order is fixed: north, east, south, west.
- Cost is one per tile; the heuristic is Manhattan distance.
- Open-list tie-breaking is deterministic by `(f, g, tile.x, tile.y)`.
- The search is bounded by `MAX_ROUTE_NODES = 4096` and `MAX_ROUTE_LENGTH = 128`.
- The route includes the source and destination belt tiles.
- A turn is represented by a belt whose direction points at the next tile. Factorio's native
  curve handles the transition.
- Start/goal tiles may override blocked status only because they are the declared endpoints; any
  real entity on an endpoint is reported as `route_endpoint_occupied` before routing.
- Module footprints, reserved module areas, real buildings, foreign ghosts, player work areas,
  resources? (resources do not block ghost placement), trees/rocks and previously planned routes
  are part of the occupancy model. Trees/rocks are treated as route obstacles in this first
  version rather than silently routed through and cleared.
- No splitters, lane balancing, priority routing, circuit belts or underground belts are used.

A route is **not** `connected` merely because it was planned. Planning creates a route record with
a fingerprint; ghost placement changes it to `route_placed`; engine verification changes it to
`connected` or `blocked`.

### Route record

Each item connection stores internally:

- source module/port and destination module/port;
- item identity;
- source/destination belt tiles;
- full path and per-tile directions;
- deterministic route fingerprint;
- planned inserter records and belt records;
- created ghost unit numbers and later real entity unit numbers;
- verification result and failure reason.

The public task summary exposes only counts and statuses.

## 5. Inserter geometry

Factorio inserter `direction` is the **pickup side**; the drop side is opposite. This was verified
in the engine before implementation and is encoded in the planner and tests.

For the eastward chain:

| Role | Direction | Pickup | Drop |
| --- | --- | --- | --- |
| ore input inserter | west (12) | belt west of the inserter | furnace tile east |
| plate output inserter | west (12) | furnace tile west | belt tile east |
| plate input inserter | west (12) | belt tile west | assembler tile east |
| gear output inserter | west (12) | assembler tile west | output chest east |
| fuel chest inserter | side-dependent | ordinary chest | fuel belt tile |
| fuel inserter | north (0) | fuel belt/chest north | furnace tile south |

The planner uses actual `inserter_pickup_position`/drop geometry indirectly through the verified
tile layout, builds ordinary `inserter` prototypes and relies on the engine for item movement. It
does not set `pickup_target`, `drop_target`, custom vectors or machine inventories. Long-handed
inserters are not used.

## 6. Fuel source discovery

- The planner searches for ordinary `container`/`logistic-container` entities with at least one
  coal item. Infinity chests are excluded. There is no special chest marker, reservation,
  whitelist or permission.
- The nearest coal chest to the furnace fuel pickup is chosen deterministically.
- If the chest occupies the pickup tile, the fuel inserter moves coal directly.
- Otherwise the planner chooses a legal side of the chest, places a chest→belt inserter, routes a
  real belt to the fuel pickup tile and places a furnace fuel inserter.
- No coal is invented. If no suitable chest exists at planning time, the physical plan returns
  `missing_fuel_source` and no module/logistics ghosts are created.
- If coal is withdrawn later, the composite task verification observes the empty chest and the
  furnace's real fuel state. It returns `blocked` with a `missing_fuel_source` reason and does not
  fabricate coal or claim production.

## 7. Electric distribution

- The planner searches a bounded area for a real electric pole whose network has a producer. It
  accepts live generation/accumulator flow and also scans a bounded area for known producer
  entities on the same network, so a solar network with no current demand is still recognised.
- It chooses ordinary `medium-electric-pole` when the item recipe is enabled, otherwise
  `small-electric-pole`.
- Pole candidates are free tiles around the chain. A deterministic greedy cover selects poles
  whose live supply-area distance intersects the collision boxes of the drill, assembler and every
  electric inserter.
- All selected poles must form one connected component. If two selected poles are farther apart
  than the smaller live wire reach, legal intermediate pole ghosts are added by a bounded search.
  The nearest selected pole is likewise connected to the existing powered pole.
- Pole ghosts are built by the paid executor. Factorio itself creates the copper-wire connections
  during revival. Production code never calls `disconnect_all`, never removes player wires and
  never disables reach checks.
- Verification uses `is_connected_to_electric_network()`, `electric_network_id`, live network flow
  and the actual pole component. It never writes an energy buffer or network identifier.
- If no powered network exists, the result is `blocked` with reason `missing_power_source` and no
  entity is built. Power generation is out of scope.

## 8. Construction and task lifecycle

`build_logistics` is a composite foreground task with save-persistent phases:

1. **planning** — create or reuse a linear logistics layout plan; compute the physical plan; fail
   early on missing fuel, missing power, blocked route or unsupported geometry.
2. **apply** — create module ghosts through the Stage-5 module placer.
3. **route_placed** — create belts, inserters, poles and the output chest as ordinary
   `entity-ghost` objects tagged with the logistics plan ID.
4. **search/pathing/moving/building** — reuse the Stage-3 construction executor with the same
   exact-cost payment and paid `revive()` path. The task ghost filter ensures unrelated player
   ghosts are not built.
5. **verifying** — read-only engine checks for entity identity/direction, consecutive belt
   neighbours, inserter power, pole network membership, furnace fuel and the output chest.
6. **monitoring** — observe actual ore/coal/plate/gear evidence over game ticks. The task
   succeeds only when a real gear wheel appears in the output chest; entity existence alone is
   never success.

Missing materials are reported with exact per-item counts. Material acquisition uses the existing
ordinary-chest path and never fabricates items.

### Failure statuses

The terminal status is one of the runner-compatible statuses; the detailed reason distinguishes
the physical outcome:

| Status | Reason examples |
| --- | --- |
| `succeeded` | `production_observed` |
| `missing_materials` | exact missing item map |
| `blocked` | `missing_power_source`, `missing_fuel_source`, `blocked_route`, `unsupported_chain`, `blocked_layout`, `physical_entities_missing`, `production_not_observed` |
| `failed` | `production_not_observed`, `verification_error`, `task_deadline_exceeded` |
| `cancelled` | explicit cancellation |
| `interrupted_by_safety` / `interrupted_by_death` | runner-level emergency; the task is paused until explicit resume |

Construction retries a bounded number of times when ghosts remain after a path/approach failure.
The task also recovers in-flight `building` entries after save/load by resetting them to `pending`
during the search phase.

## 9. Save/load, safety and death

- The layout plan, physical plan, ghost records, required items, connection fingerprints and task
  phase are serializable and survive save/load.
- Save/load during route construction, material collection and production monitoring is verified
  by the engine scenarios. No belt, module or material is duplicated.
- Safety pre-emption pauses the task, drops the in-flight target and stops movement. It does not
  delete the ghost ledger or build anything. After recovery the task remains paused until an
  explicit `task_resume`; resume resets in-flight entries and re-scans.
- Death pauses the task with reason `death`. Recovery/respawn restores the character; resume
  continues from the persisted phase without repeating completed builds.
- A player removing a planned ghost or placing a real building on a route invalidates that route.
  The task must not report success; it finishes `blocked`/`partial`, and the player's building is
  preserved.

## 10. Verification and observations

Verification is strictly read-only:

- real entity at each planned tile with matching name and direction;
- `belt_neighbours` outputs matching the next route tile;
- inserter direction, powered state, pickup/drop targets and held stacks;
- pole existence, `electric_network_id`, `is_connected_to_electric_network()` and the shared
  network component;
- furnace burner fuel and coal chest contents;
- `crafter_input`/`crafter_output` contents;
- output chest gear count;
- assembler recipe.

The observation record carries `ore_seen`, `coal_seen`, `plate_seen`, `gear_produced`,
`gear_recipe_ok`, `output_gears`, drill/furnace/assembler status and real tick boundaries. It is
not exposed to the LLM beyond the compact production result.

## 11. Supported and unsupported cases

Supported:

- one linear eastward item chain whose first step is a catalog mining module;
- ordinary belts and turns;
- ordinary inserters with native pickup/drop geometry;
- ordinary coal chest fuel delivery, with or without a belt;
- medium/small electric poles, real auto-connect and a bounded connection chain;
- wooden output chest;
- save/load, cancellation, safety/death interruption, explicit resume and player interference
  reporting;
- ordinary-chest material acquisition and exact paid construction.

Unsupported and reported, never forced:

- underground belts (not implemented in this stage);
- splitters, lane balancing or priority routing;
- branching/merging chains, arbitrary flow directions and non-mining chain starts;
- fluid, pipe, rail, circuit or logistic networks;
- power generation, autonomous coal mining and fuel processing;
- construction robots and blueprint-book ingestion;
- throughput optimization and production-rate sizing;
- manual wire connection that would bypass reach;
- implicitly treating any nearby pole as supplying a machine.

## 12. Engine verification

The reusable scenarios are:

- `tests/engine/s9_belt_routing.py` — straight/turning routes, unique planned tiles, real belt
  connections, engine-carried ore/coal, blocked route, missing materials, cancellation and no
  transport-line mutation APIs.
- `tests/engine/s10_inserters.py` — six inserter roles/directions, real pickup/drop targets, ore
  and plate movement, coal consumption, full output chest back-pressure and engine-driven resume.
- `tests/engine/s11_power_distribution.py` — missing power, real pole coverage, legal reach,
  preserved player wiring, real network membership and detection after supply removal.
- `tests/engine/s12_gear_production.py` — full iron ore → plate → gear production over ticks,
  exact paid cost, save/load during construction/material collection/monitoring, safety
  interruption, death and resume, empty coal chest and player route conflict.

Results are recorded in [engine-test-plan.md](engine-test-plan.md).
