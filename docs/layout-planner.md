# Layout Planner (Stage 5)

Status: **IMPLEMENTED**, **UNIT TESTED**, **AUTOMATED ENGINE TESTED**,
**HUMAN MULTIPLAYER TESTED** on Factorio 2.1.24. The real multiplayer acceptance used a real
Factorio client on the persistent isolated server; see
[verification-layout-planner.md](verification-layout-planner.md).

The Layout Planner turns a production goal into a deterministic, persisted module layout. It is
not a construction executor and not a working-factory generator:

- planning creates no entity and spends no item;
- applying a plan asks the existing Stage-4 module placer for ordinary `entity-ghost` objects only;
- paid construction remains the Stage-3 `assist_construction` task and its exact-cost executor;
- belts, pipes, inserters, wires, fuel insertion, circuit routing and throughput balancing are not
  implemented.

Implementation:

- `mod/factorio_autonomous_engineer/lib/production_graph.lua` — dependency resolution from module
  ports and live recipe/prototype data.
- `mod/factorio_autonomous_engineer/lib/layout_planner.lua` — bounded candidate placement,
  compatibility scoring, fingerprints, persistence and apply/revalidate lifecycle.
- `mod/factorio_autonomous_engineer/lib/module_placer.lua` — unchanged ghost-only instantiator plus
  a non-mutating `evaluate()` used by the planner.
- `src/factorio_autonomous_engineer/layout_planner.py` — reference implementation for the Python
  unit suite.
- `src/factorio_autonomous_engineer/server.py` — exactly two new model-facing MCP tools.

## 1. Production dependency resolution

The resolver reads the canonical Stage-4 catalog. It does not maintain a second module
representation.

For each module it expands the default parameters and classifies ports:

- item/fluid inputs and outputs;
- electric inputs;
- auxiliary inputs that are not recipe ingredients (for example furnace coal).

The process recipe is verified against live Factorio data:

- a fixed `assembling-machine` recipe is authoritative;
- a module without a script-assignable entity recipe (the stone furnace) gets a recipe only when
  exactly one force-enabled recipe produces its declared output and is accepted by the entity's
  crafting category;
- a mining module whose output is a resource entity is classified as `extraction`;
- ambiguous or unsupported production steps are reported, never guessed.

Resolution starts at the requested output item and walks declared inputs upstream. A producer is
chosen deterministically by:

1. category priority `mining < smelting < production < power < logistics < other`;
2. stable module ID.

Unavailable technologies/recipes/surfaces/stages exclude a producer and are reported as candidate
availability reasons. The resolver distinguishes:

- requested output;
- intermediate products;
- selected suppliers;
- available producing/consuming modules;
- inputs with no available catalog producer (`missing_supplier`);
- auxiliary/fuel inputs with no catalog producer;
- electric infrastructure requirements;
- unsupported production steps.

For `iron-gear-wheel` the live chain is:

```text
iron ore (world resource)
  -> nauvis.electric_mining.iron
  -> iron-ore
  -> nauvis.stone_furnace.iron_smelting
  -> iron-plate
  -> nauvis.assembling_machine_1.gear
  -> iron-gear-wheel (requested output)
```

The current catalog has no coal supplier and no power generator. The plan therefore reports:

- `coal` as a missing `fuel` dependency for the furnace;
- `electric-network` as a missing infrastructure dependency for the mining drill and assembling
  machine, unless an existing pole with a live electric network is within 16 tiles of the planned
  module bounds.

An existing electric network is reported as `externally_supplied`, with
`network_presence_only = true` and `physical_connection = false`. Pole presence is not proof that
the entity is inside the pole's supply area.

The resolver deliberately performs **no throughput or production-rate calculation**. The result is
a minimal valid module set, not a balanced or self-sufficient factory.

## 2. Logical connection graph

Nodes are selected module instances. Edges come from matching declared ports and external
requirements. Statuses are:

| Status | Meaning |
| --- | --- |
| `compatible` | Port interfaces match, but this status alone never claims a physical connection. |
| `route_required` | Item/fluid ports match and a future belt/pipe/inserter stage must route them. |
| `externally_supplied` | An existing world electric network was detected near the module bounds. |
| `missing_supplier` | No available module/external source supplies the port. |
| `unsupported` | Matching or geometry metadata is invalid for planning. |
| `blocked` | A selected module instance has no valid placement, so the edge cannot exist. |

`requested_output` marks the goal-facing output edge. Every item/fluid edge carries internal
positions and a Manhattan port distance for a later routing stage, but
`physical_connection = false` and `routing_required = true`. Adjacent or compatible ports do not
mean the modules are connected.

## 3. Placement algorithm

The planner is bounded to the existing Stage-3 work area: `PLAN_RADIUS = collaboration.work_radius()`
(64 tiles). It never scans the whole map.

Upstream nodes are placed before their consumers (dependency order).

### Candidate generation

- A module with a `resource_patch` constraint gets candidates only around resource entities inside
  the planning radius. Candidate anchors are derived from the resource positions, deterministic
  offsets and every advertised orientation. Generic center candidates are deliberately not mixed
  in, because they cannot satisfy the constraint and would consume the bounded evaluation budget.
- Other modules get ring candidates around the home/agent center and around each already-placed
  supplier's output port. Rings use a 2-tile step up to 24 tiles and all advertised orientations.
- Duplicate anchor/orientation pairs are removed. A deterministic rough ordering keeps at most
  **96** candidates per module for full evaluation.

### Hard constraints

Candidates are rejected when they:

- violate module placement constraints (resource patch, water, electric network, avoid lists,
  clear footprint);
- contain a real building, chest, vehicle or other hard blocker;
- contain an existing player construction ghost or another blueprint ghost;
- contain a player character or lie within `PLAYER_WORK_RADIUS` (8 tiles) of one;
- contain reserved-area blockers;
- fail terrain placement (`can_place_entity` with `script_ghost`) and have no clearable obstacles;
- leave the planning/work area;
- overlap another planned module or reserved area, including one tile of planning clearance;
- overlap a live Stage-4 module instance;
- use an unsupported surface/orientation/parameter set.

Natural trees and rocks are **clearable preparation requirements**. They are counted, recorded and
reported; the module is not claimed ready until the existing clearing executor removes them and
the placement is revalidated.

### Scoring

Lower integer score is better. Documented weights (from `layout_planner.lua`):

| Factor | Weight |
| --- | --- |
| connection distance to the nearest placed supplier port | ×4 |
| Manhattan distance from the plan center | ×1 |
| clearable obstacle count | ×12 |
| crowding: real entities within a 6-tile margin | ×2 |
| nearby player distance penalty | ×6 per tile inside 32, after rejection inside 8 |
| existing electric-pole network within 16 tiles | ×−3 per pole |

Tie-breaking is deterministic and total:

1. score;
2. connection distance;
3. center distance;
4. clearing count;
5. more nearby infrastructure;
6. lower orientation value;
7. lower anchor x;
8. lower anchor y;
9. node ID.

There is no randomness. The same world state, catalog, parameters and goal produce the same
anchors, orientations, fingerprint and plan ID.

## 4. Player and shared-world awareness

The planner treats the live world as authoritative:

- other character entities are detected and avoided with an 8-tile work radius;
- player construction ghosts are never overwritten or cancelled;
- hard buildings and vehicles block candidates;
- terrain, resources and electric networks are read live;
- the plan is revalidated before apply;
- a plan's own ghosts and its expected built entities are excluded from the local world
  fingerprint, so repeated apply remains idempotent.

Vehicle and Spidertron activity beyond their physical collision entities is **not** separately
interpreted. No claim of full vehicle-player detection is made.

## 5. Plan lifecycle

### Phase A — create

`plan_layout(goal_item="iron-gear-wheel")`

1. Validate the goal item prototype.
2. Resolve the minimal module dependency graph from live recipes and catalog availability.
3. Generate bounded candidates and choose deterministic placements.
4. Evaluate logical port connections and external infrastructure.
5. Persist the plan in `storage` with module instances, parameters, anchors, orientations,
   connection metadata, clearing requirements and fingerprint.
6. Return a compact summary. No entity is created.

The public plan contains `plan_id`, plan/placement status, materializability, selected modules,
connection-status counts, unresolved dependencies, external infrastructure, clearing counts,
fingerprint and explicit limitations. It does **not** contain anchors, coordinates, ports, entity
lists or ghost unit numbers.

Repeating the same goal reuses a still-valid persisted plan. If the world changed, a new plan is
created and the old plan can no longer be applied.

### Phase B — apply

`apply_layout(plan_id=...)`

1. Recompute the local environment signature and compare it with the stored signature.
2. Re-evaluate every not-yet-applied module against live collisions, ghosts, players, resources and
   placement constraints.
3. Refuse a stale or conflicting plan with `stale_plan`; nothing is created.
4. Instantiate only validated module ghosts through `module_placer`.
5. Record the instance-key → ghost-unit-number relationship and the plan identity on each ghost tag.
6. Reconciliation:
   - repeated apply returns `already_applied`;
   - a player-built plan entity is counted as built and not duplicated;
   - a player-cancelled plan ghost is not recreated;
   - partial application reports exactly which module instances were created, already applied,
     cancelled or failed.

Applying a plan never revives a ghost, consumes an item, calls `assist_construction`, or mutates a
player building.

### Persistence

Plans are plain serializable data in mod storage and survive save/load. Up to 32 plans are retained
in creation order; older plans are pruned. Plan IDs, fingerprints, environment signatures,
application state and module instance keys survive reload.

### Stale-plan rules

A plan becomes stale when any of the following changes after planning:

- a real building/entity appears in a planned footprint or reserved area;
- a foreign construction ghost appears there;
- a player character enters the player work radius around a planned footprint;
- iron resources inside a mining footprint change;
- an electric pole with a live network is added or removed near the plan;
- a planned module becomes unavailable;
- any placement constraint no longer holds.

Clearable trees/rocks and the plan's own construction progress (own ghosts or expected real
entities) are not stale changes. A stale plan is never silently applied over a new world state.

## 6. Interface

Model-facing MCP tools:

- `plan_layout(goal_item)`;
- `apply_layout(plan_id)`.

The LLM receives only compact strategic facts. Raw coordinates, port positions, entity references,
ghost unit numbers, inventory indices and routing instructions remain inside the mod.

Internal RCON operations for the engine harness and future code-owned planners:

`layout_plan_create`, `layout_plan_apply`, `layout_plan_status`, `layout_plans`,
`layout_planner_limits`, `plan_layout`, `apply_layout`.

They are not additional MCP tools. Internal callers may pass `force_new = true` to bypass
still-valid plan reuse and `orientation_hints` (module ID → orientation) to bound rotation
selection for deterministic tests; neither parameter is exposed to the LLM.

## 7. Known limitations

- No belt, pipe, rail, circuit or wire routing; item/fluid edges remain `route_required`.
- No inserter or fuel-insertion placement; the furnace coal input is unresolved unless a future
  fuel module exists.
- No power generation or pole placement; existing-network detection is presence-only.
- No throughput optimization or production-rate calculation.
- No arbitrary site search outside the 64-tile work area.
- No deconstruction, module removal, construction robots or logistics delivery.
- No blueprint-book ingestion.
- No planetary module libraries beyond Nauvis.
- One minimal module instance per selected module type; no duplication/balancing.
- Only one selected producer per item; alternative-recipe optimization is out of scope.
- Vehicle-player activity detection is limited to physical collision entities.
- A layout plan is not a working factory and must not be described as operational.

## 8. Verification and human multiplayer procedure

Automated verification:

- `uv run pytest -q tests` covers dependency graphs, port compatibility, missing suppliers,
  external dependencies, deterministic candidates/scoring/tie-breaking, resource constraints,
  collisions, reserved areas, orientations, player/ghost obstacles, fingerprints, stale plans,
  persistence serialization and idempotent application.
- `tests/engine/s8_layout_planner.py` covers the live recipe chain, the three selected modules,
  coal/electric dependencies, resource-patch placement, all four mining orientations, hard
  collisions, player ghosts, player work radius, clearing requirements, deterministic reproduction,
  ghost-only apply, repeated apply, cancellation/build reconciliation, save/load and stale-plan
  rejection.
- Existing `s1`–`s7` reliability, construction and module scenarios must pass on the same archive.

Human multiplayer acceptance is a separate gate:

1. Complete implementation, static/unit/automated engine tests, regression tests, archive creation
   and archive/tree integrity checks.
2. Start the persistent isolated multiplayer server from a disposable save and print verified
   connection details. Never expose RCON credentials or the RCON port as game connection data.
3. Wait for an explicit user confirmation that the real Factorio client joined.
4. Verify the real player's character is present in the running server.
5. Generate and apply the iron-gear plan. The real player must remain outside planned footprints;
   their buildings and ghosts must remain unchanged.
6. Ask the player to inspect the result in game and, if they perform a manual build/blueprint
   change, reconcile the observed world and report the behavior.
7. Mark **HUMAN MULTIPLAYER TESTED** only after these steps actually complete.
