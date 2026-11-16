# Construction Work Scheduler

`lib/work_scheduler.lua` divides an existing task's pending ghost ledger into sequential spatial
zones. It does not create distant ghosts, move the character or write `walking_state`; the Movement
Controller owns every route.

## Zones and floating work positions

Zone size is derived from the character's live `build_distance`, not a fixed construction-range
constant. The base side length is `floor(build_distance * sqrt(2) * 0.95)`, with a small minimum and
bounded overlap. Zone identity comes from grid coordinates, and entry identity remains the stable
ghost-ledger key across scans and save/load.

For each zone the scheduler evaluates bounded candidate positions. A position must be collision-free
for the character, off belts, outside pending ghost footprints and clear of other characters.
Candidates are scored by how many pending ghosts they cover, travel distance from the agent, the
next zone and deterministic tie-breakers. Large module zones are handled before smaller logistics
ghosts so belts cannot enclose an unbuilt module footprint.

The selected position is floating: it is a computed work position, not a ghost's approach ring.
After arrival, the executor builds every payable ghost for which the live engine
`can_place_entity(..., build_check_type=ghost_revive)` check succeeds from the character's actual
position. It does not walk close to each ghost when several are reachable from one position.
Unreachable or blocked positions are rejected and another candidate is tried, with bounded fallback
to the legacy target/clearing/acquisition path.

## Task isolation and persistence

The active plan is stored at `task.work_plan`. A newly started task receives a new plan, zone order,
rejected-position set and processed-work view. Completing one task does not share scheduler state
with the next. Safety/death resume and explicit task reset discard transient zone selection while
preserving paid construction records, real entities, module identities and ghost deduplication
records.

`active_zone`, selected position, transition count and per-zone attempts are internal diagnostics.
They never become model-facing coordinates or construction micro-actions. Batch material
acquisition still aggregates all pending costs, and every revival still pays its exact cost.
