# Advanced logistics: splitters, underground belts and multi-consumer graphs (Stage 7)

Status: **IMPLEMENTED**, **UNIT TESTED**, **AUTOMATED ENGINE TESTED** on Factorio
2.1.24. Human multiplayer acceptance is a separate gate and is not implied by these
results.

Stage 7 extends the one-to-one Stage-6 belt chain into a reusable directed transport graph
with branching, merging, splitters, underground pairs and multiple consumers/producers.
The composite task remains `execute_task(task="build_logistics", goal_item=..., mode=...)`.
No second module format or construction executor exists.

## 1. Graph model

A physical logistics plan is still one persisted table with the same `entities`,
`connections`, `output`, `fuel`, `power` and `observation` sections. A multi-consumer
plan additionally has:

| Record | Meaning |
| --- | --- |
| `connections[]` | Logical routes. Each route carries source/destination module and port IDs, item, ordered steps, belt records, inserter records, splitter/underground references, a deterministic fingerprint, ghost units, built units, engine connectivity, observed flow, status and failure reason. |
| `junctions[]` | Real splitter records: top-left anchor, direction, two-tile footprint, two input and two output connector tiles, used/unused connectors, kind (`split` or `merge`), route IDs and the engine verification result. |
| `underground_pairs[]` | Pair identity, belt prototype, entrance/exit tiles, travel direction, live `max_distance`, distance, reciprocal runtime neighbour result and the two endpoint records. |
| `cell` | Module anchors, junction anchors, the underground crossing, coal-chest tile and output-chest tile. It is internal planning data and is never sent to the LLM. |
| `observation` | Per-consumer and per-machine evidence: ore/coal/plate presence, `products_finished` baselines, output chest gauge and route flow samples. |

The representation deliberately separates:

1. **logical connection** — a source port should feed a destination port;
2. **planned route** — deterministic belt/splitter/underground steps and fingerprint;
3. **placed infrastructure** — ordinary construction ghosts with stable tags;
4. **engine-confirmed physical connection** — real entity names, directions, splitter
   connector lists, belt-neighbour outputs and underground reciprocal neighbours;
5. **observed flow** — read-only transport-line samples and real consumer inventories.

A route is never marked `connected` merely because its endpoint entities exist. A route
is never marked successful merely because it is `connected`.

### Stable identity

- `route.id` is semantic (for example `ore_branch_b`, `plate_merge_route`,
  `coal_branch_a`).
- Route fingerprints are a deterministic digest over the item and the ordered steps:
  `belt:tile:direction` or `ug:tile:direction:distance`.
- Underground pair identities are a deterministic digest over prototype, entrance tile,
  direction and distance.
- Junction identities are the stable names `ore_split`, `plate_merge`, `plate_split`,
  `gear_merge`, `coal_split`.
- Ghosts carry `ae_logistics_plan_id`, role, connection and (for underground endpoints)
  pair/side/direction/other-end tags.

## 2. Splitters

Factorio 2.1.24 splitter geometry was probed in the engine before implementation:

- a splitter is a transport-belt-connectable entity;
- its 2x1 footprint rotates with direction (east/west is 1x2);
- it exposes two input belt connectors on the back side and two output connectors on the
  front side;
- `LuaEntity.belt_neighbours` reports the connected belts, including their real positions.

The planner uses ordinary `splitter` prototypes only. It does not set filters, input/output
priority or circuit conditions. Those remain out of scope because their exact 2.1.24
behaviour was not part of this stage's verified contract.

### One-to-two branching

A belt feeds one splitter input. Both splitter outputs are connected to real belts. Factorio
performs the distribution. The planner never assumes equal long-term quantities: the actual
rate depends on consumer demand, machine state and back-pressure.

### Two-to-one merging

Two independent input belts feed both splitter inputs; one output is connected to the
shared route. The second output is deliberately left without a belt and the verification
requires that unused connector to stay empty. This makes the merge explicit and detects an
accidental side-load. With one input or the output blocked, the engine's native splitter
back-pressure applies; Stage 7 does not claim a throughput guarantee or perfect balancing.

### Physical verification

For every splitter the verifier checks:

- real entity type `splitter` and exact direction;
- the expected used input/output connector positions;
- every used connector is present in `belt_neighbours`;
- every unused connector is absent (no accidental belt side-loading).

## 3. Underground belts

`transport.underground_pair` uses the live `UndergroundBeltPrototype.max_underground_distance`
for the selected belt tier. Yellow belts report 5 in Factorio 2.1.24. Distances 1..max are
accepted; larger distances are rejected with `underground_distance_exceeded`. The planner
does not hard-code reach values.

Rules:

- entrance and exit tiles are collinear and use the same travel direction;
- both endpoint tiles must be free of player buildings/ghosts and outside reserved module
  areas;
- the pair identity includes prototype, entrance tile, direction and distance;
- ordinary belt-neighbour verification is used for belts before/after the pair;
- the underground relationship is verified separately through
  `LuaEntity.underground_belt_neighbour`, not inferred from adjacency;
- the engine must report reciprocal neighbours and the expected input/output roles.

Factorio 2.1.24 revives an underground ghost as an input endpoint until its partner exists.
The paid executor creates the exit ghost with the opposite build hint, then reasserts the
planned travel direction on both real endpoints after each revival. The engine then assigns
the input/output roles. This is construction configuration; it does not create, move or
teleport items.

The Stage-7 expansion uses one underground pair where a real conflict exists: the coal
branch to the second furnace passes underneath the first furnace's ore branch. It is not a
decorative demonstration pair.

## 4. Deterministic route planning

The existing bounded cardinal A* is extended by `lib/transport.lua`:

- ordinary straight belts and turns;
- splitter footprints and connector geometry;
- underground entrance/exit steps as explicit route steps;
- multiple incoming and outgoing routes;
- bounded search (`4096` nodes, length `128`) and fixed N/E/S/W ordering;
- deterministic tie-breaking by `(f, g, x, y)` and step order;
- no randomness.

Routes are allocated against an occupancy map containing module footprints, reserved
areas, real buildings, foreign ghosts, player work areas, trees/rocks and already planned
agent routes. Player entities are never removed, moved, rotated or replaced to make a route
fit. A player building on a route makes it blocked; the agent does not rebuild a missing
real belt or a player-cancelled ghost.

Shared physical segments are permitted only when they belong to the same agent plan and the
resulting connectivity is verified. The Stage-7 cell uses explicit junctions rather than
implicit belt side-loading.

## 5. Multi-consumer expansion

The internal layout mode `multi_consumer` places the existing catalog modules:

```text
nauvis.electric_mining.iron (x1)
nauvis.stone_furnace.iron_smelting (x2)
nauvis.assembling_machine_1.gear (x2)
```

The cell demonstrates:

1. one iron-ore source distributed to two furnaces by a splitter;
2. one ordinary coal chest feeding a splitter with a branch to each furnace;
3. both furnace plate outputs merged through a splitter into one shared plate trunk;
4. the shared plate trunk split to two assemblers;
5. both gear outputs merged through a splitter into one common output chest.

The module sizes are live prototype footprints (the assembler and drill modules include
their reserved service area). The cell uses exact physical gaps for inserters and belts.
The site search samples the whole bounded iron patch so a Stage-6 factory already occupying
the nearest ore tiles does not force a false `blocked_layout`. The new cell is parallel and
may run close to the old factory, but site selection rejects real buildings, ghosts and
players inside the cell rectangle; old entities are never modified.

## 6. Fuel distribution

- Fuel comes from an ordinary `container`/`logistic-container` with real coal. Infinity
  chests and special markers are not used.
- The coal source is fed through a real chest inserter, belt path, splitter and two fuel
  branches. Each furnace has a real fuel inserter.
- Coal is never inserted directly into a furnace or chest inventory by production code.
- The observation records the source chest contents and both furnace burner/fuel inventories.
- A depleted coal stock is reported as `missing_fuel_source:fuel_depleted`; it never
  fabricates coal.

## 7. Composite task

`build_logistics` accepts `mode="multi_consumer"` (default `linear_chain`). The task phases
remain planning → apply → route placement → paid construction → verification → monitoring.
The multi-consumer path:

1. resolves the multi-consumer layout plan through the existing Layout Planner/catalog;
2. resolves all routes and junctions deterministically;
3. checks player activity and world occupancy;
4. calculates the full ghost material set;
5. fetches missing materials through the existing ordinary-chest path;
6. creates ordinary entity-ghosts for belts, splitters, underground endpoints, inserters,
   poles and the output chest;
7. builds them through the existing paid executor;
8. reconciles partial completion and player changes;
9. verifies engine connectivity for belts, splitters and underground pairs;
10. monitors real consumer inventories, fuel, machine `products_finished` and output chest;
11. succeeds only when both furnaces and both assemblers have actually produced and the
    common output chest has gained gear wheels.

The model-facing terminal result is compact:

- route counts by state, consumer groups, power/fuel status;
- which consumers are supplied;
- `production_active`, `output_verified`, gear count and per-machine production flags;
- missing materials, blocked/cancelled/unsupported counts, ghost/built/remaining counts;
- `further_work_possible`.

No coordinates, entity indices, transport-line indices, unit numbers or per-belt
instructions are exposed.

## 8. Status semantics

| Status | Meaning |
| --- | --- |
| `route_planned` | Path and entities planned; no engine connectivity claim. |
| `route_placed` | Ordinary ghosts exist. |
| `connected` | Engine confirms the physical route, splitters and underground pairs. |
| `flow_observed` | A read-only transport-line sample contained the route item. It is evidence, not a throughput guarantee. |
| `consumers_supplied` | Each requested consumer actually received input or produced from it. |
| `production_active` | Both furnaces and both assemblers increased real `products_finished`. |
| `output_verified` | The common output chest gained real product. |
| `operational` | All of the above physical and production checks pass. |
| `blocked` | A route, junction, entity, player change or prerequisite is not valid. |
| `missing_fuel_source` | No coal source, depleted coal or no delivered fuel. |

Back-pressure and partial operation are normal. A full output chest stops the output
inserter; it is not a success and items are never deleted. One stopped consumer does not
make the shared splitter "balanced"; the task reports partial consumer/production status.

## 9. Persistence and collaboration

- Plans, routes, junction records, underground pairs, fingerprints, ghost tags, observation
  counters and task phase are plain save-persistent data.
- Save/load during construction, between underground endpoint builds, during production
  monitoring, cancellation, safety interruption and death is covered by `s16`.
- Re-running a built plan does not duplicate belts, splitters, underground pairs or
  materials. A real entity removed by a player is reported as blocked and is not silently
  rebuilt; a player-cancelled ghost remains absent.
- Construction remains ordinary ghost revival with exact item payment. No transport line,
  machine inventory, crafting progress, energy or resource is edited by production code.

## 10. Unsupported in Stage 7

- splitter filters, priorities and circuit-controlled splitters;
- throughput optimisation, equal-rate balancing guarantees and production scheduling;
- fluids, pipes, pumps, steam power, rail, circuits, loaders and logistic-network delivery;
- construction robots, automatic deconstruction and blueprint-book ingestion;
- autonomous coal mining or power generation;
- replacing/rewiring player-owned belts, splitters, underground belts or poles;
- automatic rebuilding of a player-cancelled ghost or a player-removed real route.

## 11. Verified engine APIs

The implementation and engine scenarios were validated on Factorio 2.1.24:

- `SplitterPrototype` / `TransportBeltConnectablePrototype` geometry through the real
  entity bounding box and `belt_neighbours`;
- `UndergroundBeltPrototype.max_underground_distance`;
- `LuaEntity.belt_neighbours` for ordinary belt connectivity;
- `LuaEntity.underground_belt_neighbour` and `belt_to_ground_type` for pair identity;
- read-only `LuaTransportLine.get_contents()` for flow observation;
- real inserter pickup/drop geometry, furnace burner fuel, `products_finished` and
  `crafter_input`/`crafter_output` inventories.

No API behaviour was inferred from an older Factorio version.
