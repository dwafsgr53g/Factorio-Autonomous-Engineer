# Module library

Status: **IMPLEMENTED**, **UNIT TESTED**, **ENGINE TESTED** for the three modules below.
The schema is specified in [module-format.md](module-format.md).

This is a small starter library, not a complete factory. It demonstrates three different entity
configurations and three different placement/connection profiles on Nauvis.

## Catalog summary

| Stable ID | Version | Category | Entity | Parameters | Requirements | Placement |
| --- | --- | --- | --- | --- | --- | --- |
| `nauvis.electric_mining.iron` | 1 | mining | 1 electric mining drill | none | `electric-mining-drill` technology | iron-ore patch, clear footprint |
| `nauvis.stone_furnace.iron_smelting` | 1 | smelting | 1-3 stone furnaces | `unit_count` 1..3 | `iron-plate` recipe; stone-furnace item recipe | clear footprint |
| `nauvis.assembling_machine_1.gear` | 1 | production | 1 assembling machine 1 | none | `automation` technology; `iron-gear-wheel` recipe | clear footprint |

All three are Nauvis-only and intended for early-game/automation-bootstrap stages. The catalog
loader is force-aware: the mining and assembling modules are unavailable until their technologies
and item recipes are enabled on the current force, even though their prototypes exist.

## 1. Electric iron mining drill

`nauvis.electric_mining.iron`

- **Function:** one electric mining drill on an iron-ore patch.
- **Geometry:** base footprint `3 x 3`, anchor at the top-left tile corner; effective bounds
  `3 x 4` because of a `output_clearance` reserved strip (`x=0..3`, `y=3..4`).
- **Entity:** `electric-mining-drill` at `{1.5, 1.5}`.
- **Orientations:** `0`, `90`, `180`, `270`; the entity is rotatable.
- **Ports:** `ore_output` (item output `iron-ore`, east side at `{3, 1.5}` when unrotated,
  direction east) and `power_input` (electric input at the drill center).
- **Requirements:** technology `electric-mining-drill`; no process recipe.
- **Placement:** `resource_patch` for `iron-ore` with at least 1 resource entity and at least 9
  units inside the effective bounds, plus `clear_footprint`.
- **Engine verification:** all four orientations were instantiated as ghosts and their transformed
  entity position, output port and reserved area were checked. Off-resource placement was rejected
  with `resource_patch_missing`. A real chest in the footprint was rejected as
  `blocked_by_existing_entity`.

The module is not a complete mining outpost: it does not include power poles, belts, inserter
unloading, resource coverage optimization or output routing.

## 2. Stone furnace iron smelting bank

`nauvis.stone_furnace.iron_smelting`

- **Function:** one to three stone furnaces with ore, fuel and plate interfaces.
- **Geometry:** base footprint `2 x 2`; `unit_count` repeats the furnace and all three ports along
  `+x` with a 2-tile step. Effective width for count `n` is `2n`.
- **Entity:** `stone-furnace` at `{1, 1}` for the first copy.
- **Orientations:** only `0`. Base stone furnaces are non-rotatable; the module does not advertise
  rotations it cannot preserve after construction.
- **Ports:** `ore_input` (iron ore, west side), `fuel_input` (coal, north side), `plate_output`
  (iron plate, east side). Repeated copies get `_2`, `_3` IDs.
- **Requirements:** recipe `iron-plate`; the stone-furnace item recipe must be enabled.
- **Placement:** `clear_footprint`.
- **Engine verification:** three-furnace expansion produced exactly three ghosts at deterministic
  positions and nine transformed ports. A two-furnace bank was built through
  `assist_construction`; exactly two stone furnaces appeared once, and exactly two stone-furnace
  items were consumed.

The module has no inserters, belts, fuel delivery, automatic recipe control or output removal. The
fuel and ore ports are declarative interfaces for a future planner, not a working smelting line.

## 3. Assembling machine iron gear

`nauvis.assembling_machine_1.gear`

- **Function:** one assembling machine configured for iron gear wheels.
- **Geometry:** base footprint `3 x 3`; effective bounds `3 x 4` because of a `service_access`
  reserved strip (`x=0..3`, `y=3..4`).
- **Entity:** `assembling-machine-1` at `{1.5, 1.5}` with `recipe = "iron-gear-wheel"`.
- **Orientations:** only `0`. The base assembling machine is non-rotatable.
- **Ports:** `plate_input` (iron plate, west), `gear_output` (iron gear wheel, east), `power_input`
  (electric input at the machine center).
- **Requirements:** technology `automation`; recipe `iron-gear-wheel`; assembling-machine item
  recipe.
- **Placement:** `clear_footprint`.
- **Engine verification:** ghost placement, reserved area and ports were checked; the module was
  built through `assist_construction`, the exact assembling-machine item was consumed, and the real
  machine has recipe `iron-gear-wheel` and direction `0` after revival.

The recipe is not part of the ghost's item cost. It is stored on the ghost as a module tag and
applied by the existing paid construction executor after revival, then verified. No inserters,
belts, power poles or logistics are included.

## Catalog and planning metadata

The internal catalog operation (`module_catalog`) reports for each module:

- stable ID, schema version, module version, name, category;
- surfaces, intended stages and tags;
- parameter names, base entity/port IDs and advertised orientations;
- validation status (loaded/invalid) and catalog errors;
- force/surface/stage availability with explicit reasons;
- a derived default cost estimate from live `items_to_place_this`.

Cost estimates are planning metadata only. The paid construction executor recomputes the exact
ghost requirement and performs all material checks.

## What was not tested

- This is **not** a complete working factory or a production-ready module set.
- No inter-module belt/pipe routing, power wiring, inserter placement, fuel delivery,
  module/beacon insertion, logistic network or construction robots exist.
- The Stage-5 Layout Planner can select and place this library's modules as a dependency-checked
  plan, but it does not make the resulting chain operational.
- Only the initial Nauvis library is included; no other planet libraries exist.
- Blueprint export/import and blueprint-book ingestion are not implemented.
- The modules were verified on a disposable baseline save with all technologies unlocked for the
  construction checks. A normal early-game force will see the mining/assembling modules as
  unavailable until the listed technologies are researched.

See the recorded engine results in [verification-modules.md](verification-modules.md).
