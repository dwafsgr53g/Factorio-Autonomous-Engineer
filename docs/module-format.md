# Module format (schema v1)

Status: **IMPLEMENTED**, **UNIT TESTED**, **ENGINE TESTED** for the initial Nauvis library.
See [the Stage 4 verification report](verification-modules.md).

This document specifies the canonical project-native building-module format. It describes what a
module is, how it is validated, how geometry is transformed, and what the future Layout Planner may
rely on. It is not a general blueprint-book format.

## 1. Canonical representation

A module is a **pure declarative Lua data table** stored in
`mod/factorio_autonomous_engineer/modules/`. The explicit list of canonical files is
`modules/manifest.lua`; each listed file returns one table. There is exactly one canonical
definition per module ID.

Why Lua data tables:

- The Factorio runtime can load them with `require`; no arbitrary filesystem access is needed.
- Factorio 2.1 only permits `require` while `control.lua` is being parsed. `modules/library.lua`
  therefore loads the manifest and every module at parse time, and the runtime catalog reads the
  preloaded tables.
- The tables contain only literals. Functions, calls, variable references, dynamic evaluation and
  arbitrary expressions are not part of the format. The Python unit suite includes a strict
  declarative reader that rejects executable Lua.
- The same files are read by the Python reference validator for fast static tests.

Trade-offs:

- Lua table syntax is less convenient for external tooling than JSON, so the Python unit suite
  contains a small literal-only reader instead of a general Lua interpreter.
- Adding a module requires a manifest entry plus the data file. There is no directory scan at
  runtime.
- Factorio Blueprint strings are **not** the source of truth. Blueprint export/import is deferred
  interoperability, not the canonical representation.

The mod tree is packaged directly into the release ZIP. No generated duplicate module data is
stored in Git.

## 2. Versioning and identity

| Field | Required | Meaning |
| --- | --- | --- |
| `schema_version` | yes | Must be `1`. A definition with another version is rejected. |
| `id` | yes | Stable module ID, e.g. `nauvis.stone_furnace.iron_smelting`. Pattern: `^[a-z0-9][a-z0-9_.-]*$`. |
| `module_version` | yes | Positive integer raised when module gameplay/geometry changes. |
| `name`, `description` | yes | Human-readable catalog text. |
| `category` | yes | `mining`, `smelting`, `power`, `production`, `logistics` or `other`. |
| `surfaces` | yes | Non-empty list of surface/planet names, e.g. `{"nauvis"}`. |
| `stages` | yes | Intended game stages: `early_game`, `automation_bootstrap`, `automation`, `oil_processing`, `advanced_industry`, `space_age`. |
| `tags` | no | List of strings for future catalog filtering. |

IDs are immutable once saved task or instance state can refer to them. Do not rename an ID to
express a new version; raise `module_version` instead.

The manifest has its own `schema_version` (currently `1`) and an ordered list of module paths:

```lua
return {
  schema_version = 1,
  modules = {
    "modules.nauvis_electric_mining_iron",
    "modules.nauvis_stone_furnace_smelting",
  },
}
```

Duplicate module IDs, duplicate manifest entries, malformed paths and unknown schema versions are
catalog errors. A definition that fails any validation is excluded entirely; it is never partially
interpreted or silently defaulted.

## 3. Coordinate convention

- The module anchor is the **top-left tile corner** of the base footprint in world coordinates.
  The anchor supplied to internal instantiation must have integer `x` and `y`.
- Local coordinates have origin `{x=0, y=0}` at the anchor, `+x` east and `+y` south. One unit is one
  tile. `geometry.origin` must be `{x=0, y=0}` in schema v1.
- Entity `position` is the **entity center**, not its top-left. Permitted local positions are
  multiples of `0.5`.
  - A 1x1 entity centred on a tile is at `{x=0.5, y=0.5}` (or any `n+0.5`).
  - A 2x2/even-footprint entity centring on a tile boundary is at an integer coordinate.
  - A 3x3/odd-footprint entity is at a half-tile coordinate such as `{x=1.5, y=1.5}`.
- `geometry.footprint.width` and `.height` are positive integers describing the base module
  rectangle starting at the anchor and extending `+x`/`+y`.
- `geometry.reserved` areas extend the effective bounds. They are declarative clearance or access
  areas; instantiation treats them as areas that must not contain hard blockers.
- Repeated entities/ports (`repeat_by`) extend the effective bounds deterministically. The declared
  base footprint must contain the first copy; later copies may extend it.
- The effective rotated footprint is reported by validation and by internal resolution.
- **Mirroring is not supported** and is not advertised. Only 0/90/180/270-degree rotations are
  defined.

### Rotation

Rotations are clockwise quarter turns. For an unrotated effective rectangle `W x H`:

| Orientation | Point transform | Direction transform | Rotated size |
| --- | --- | --- | --- |
| 0 | `(x, y)` | `d` | `W x H` |
| 90 | `(H - y, x)` | `(d + 4) % 16` | `H x W` |
| 180 | `(W - x, H - y)` | `(d + 8) % 16` | `W x H` |
| 270 | `(y, W - x)` | `(d + 12) % 16` | `H x W` |

Factorio direction values are north `0`, east `4`, south `8`, west `12`. Schema v1 entity and port
directions must be one of these cardinal values. Reserved rectangles rotate with the same
transform; their width/height swap on 90/270.

A module may advertise only orientations that its real entities preserve through construction. The
initial stone furnace and assembling-machine modules advertise only `0`, because those base entities
are non-rotatable; the electric mining drill advertises all four. The engine scenario verifies every
advertised orientation and records real entity directions after construction.

## 4. Entities

```lua
geometry.entities = {
  {
    id = "furnace",
    name = "stone-furnace",
    position = {x = 1, y = 1},
    direction = 0,
    quality = "normal",                 -- optional; default normal
    recipe = "iron-gear-wheel",         -- optional; assembling-machine only
    repeat_by = {parameter = "unit_count", step = {x = 2, y = 0}},  -- optional
  },
}
```

Supported entity settings in schema v1:

- `name`, `position`, `direction`;
- `quality` when explicitly configured (quality prototype must exist);
- `recipe` for `assembling-machine` entities only (recipe prototype must exist, be force-enabled and
  have a category accepted by the machine);
- `repeat_by` for deterministic repeated copies.

The supported entity types are deliberately bounded: `mining-drill`, `furnace`,
`assembling-machine`, `transport-belt`, `container`, `electric-pole` and `inserter`. Other entity
types are rejected rather than guessed. Other configuration fields (`insert_plan`, equipment,
fluids, control behaviour, item requests, etc.) are unknown fields and fail validation. The
construction executor still refuses any ghost with a non-empty insert plan or extra item requests.

A recipe on a stone furnace is rejected: Factorio does not expose script recipe assignment for
furnaces, so the module must declare its process through ports/requirements instead of pretending to
configure the entity. An assembling-machine recipe is stored as a ghost tag and applied by the paid
construction executor **after** revival, then verified.

## 5. Ports

```lua
geometry.ports = {
  {
    id = "plate_output",
    type = "item",               -- item | fluid | electric
    role = "output",             -- input | output | bidirectional
    position = {x = 2, y = 1},
    direction = 4,               -- canonical flow direction
    item = "iron-plate",         -- required for item ports
    repeat_by = {parameter = "unit_count", step = {x = 2, y = 0}},  -- optional
  },
}
```

- `id` is stable within the module after repeat expansion (`plate_output`, `plate_output_2`, ...).
- `position` is on the same entity-center/half-grid coordinate convention. Ports may sit on the
  footprint boundary (`x == width` or `y == height`) and are included in the effective bounds.
  The first copy of a repeated port must fit the declared base footprint.
- `direction` is the canonical flow direction. For an output it points out of the module; for an
  input it points in the direction items/fluids enter. Electric ports carry no item/fluid and may
  declare `connector = "input" | "output"`.
- Item ports require a known item; fluid ports require a known fluid and must not declare an item.
- `capacity` is reserved for future connection metadata and is not interpreted in Stage 4.

Ports describe interfaces only. Stage 4 does **not** route belts, pipes, wires or trains between
modules. A future Layout Planner may use these ports for matching, but no such planner is
implemented here.

## 6. Requirements and availability

```lua
requirements = {
  technologies = {"electric-mining-drill"},
  recipes = {"iron-plate"},
  stage = "automation_bootstrap",       -- optional minimum stage
}
```

Validation distinguishes:

1. the entity/item/fluid/recipe/technology **prototype exists** in the loaded game;
2. the recipe/technology exists for the force and is **enabled/researched**;
3. the module's base placeable-item recipes are enabled for the force;
4. the current **surface/planet** is listed in `surfaces`;
5. the current stage is at least `requirements.stage`.

A module can load successfully but be `available = false` if its technology, recipe, item recipe,
surface or stage requirements are not met. Availability reasons are explicit, e.g.
`technology_not_researched:electric-mining-drill`,
`recipe_not_available:iron-gear-wheel`, `item_recipe_not_available:assembling-machine-1` or
`unsupported_surface`. Instantiation rejects an unavailable module.

Environmental conditions are expressed through placement constraints (`resource_patch`,
`near_water`, `electric_network`, `avoid_tiles`) rather than an arbitrary expression language. More
environment conditions can be added only with a defined validator.

## 7. Placement constraints

`placement.constraints` is a non-empty list. Supported types in schema v1:

| Constraint | Meaning and Stage-4 validation |
| --- | --- |
| `clear_footprint` | The effective bounds and reserved areas must not contain hard blockers. Trees/rocks are clearable by the existing executor; cliffs, chests, buildings and characters are hard blockers. |
| `resource_patch` | Resource entities of `resource` inside the effective bounds must meet `minimum_entities` (default 1) and `minimum_amount` (default 1). The count uses live resource entities. |
| `near_water` | At least one `water`/`deepwater` tile within `max_distance` (default 32) of the bounds. |
| `avoid_entities` | Reject if `types` or `names` occur inside the effective bounds. |
| `avoid_tiles` | Reject if any tile in `names` occurs inside the effective bounds. |
| `electric_network` | At least one electric pole with a live electric network within `max_distance` (default 16) of the bounds. |

Unknown constraint types are rejected. Map-wide search, optimization, resource-patch scoring and
automatic site selection are **not** implemented; the internal instantiation call supplies an anchor
and the constraints are checked locally.

## 8. Parameters and variants

```lua
parameters = {
  unit_count = {
    type = "integer",          -- integer | string | boolean
    default = 1,
    minimum = 1,
    maximum = 3,
    affects_geometry = true,
    description = "Number of repeated furnaces.",
  },
}
```

- Parameter types are integer, string (with a non-empty `allowed` list) and boolean.
- Every parameter has an explicit default. Integer bounds are inclusive; string defaults must be in
  the allowed list; boolean defaults must be boolean.
- Unknown requested parameters and out-of-range values are rejected.
- `affects_geometry = true` is required when a parameter is used by `repeat_by`. Repeated copies
  use `step` offsets: copy 1 keeps the base ID, later copies get `_2`, `_3`, etc.
- Schema v1 deliberately has **no formulas, expressions or procedural generation**. Geometry is a
  deterministic function of the resolved parameter values and orientation.
- Validation expands every allowed geometry-parameter combination (bounded to 64) at every declared
  orientation and checks entity IDs, port IDs, overlap and bounds before any ghost is placed.

## 9. Material cost

Module definitions are not a cost source. The canonical cost comes from live prototype and ghost
data through the existing Stage-3 executor:

- a script-created ghost has no `item_requests`; the executor reads the inner prototype's
  `items_to_place_this`;
- a player/blueprint ghost uses its live `item_requests`;
- quality comes from the ghost/request;
- the executor verifies exact removal from the character main inventory before revival;
- extra item requests or insert plans are refused;
- a successful build is never free and a failed pre-revival build refunds exact stacks.

The catalog exposes `default_cost` / `cost_estimate` derived from `items_to_place_this` for
planning and display only. It never overrides the executor's live checks. Repeated entities and
qualities are aggregated by item name and quality.

## 10. Internal instantiation

`lib/module_placer.lua` turns a validated definition plus an internal placement specification into
**only entity ghosts**. It:

1. resolves the stable ID through the catalog and rejects invalid/unavailable modules;
2. resolves parameters and checks the requested orientation;
3. validates surface, hard blockers, reserved areas and placement constraints;
4. computes absolute entity/port positions internally from the anchor;
5. creates `entity-ghost` objects with `inner_name`, direction, quality and module tags;
6. creates no real entity and spends no items;
7. stores an instance record in `storage` with module identity/version, anchor, orientation,
   resolved parameters, footprint, ghost unit numbers and expected entity settings;
8. deduplicates an identical module/anchor/orientation/parameter fingerprint and rejects an
   instance-key conflict;
9. exposes internal status by deriving pending/built/missing/mismatch from live ghosts and real
   entities after save/load.

This is not a second construction executor. Actual construction still uses
`assist_construction`, `lib/collaboration.lua` and the paid `lib/construction.lua` path. The recipe
tag is applied by that executor after revival.

These module operations are available only through the internal RCON bridge for engine tests and
future code-owned planners. They are **not** MCP tools, so the model never receives arbitrary
placement coordinates or raw entity lists.

## 11. Validation diagnostics

A definition is rejected if any required field is missing or malformed. Typical codes:

`unsupported_schema_version`, `invalid_module_id`, `invalid_module_version`, `invalid_category`,
`invalid_surfaces`, `unknown_stage`, `invalid_parameter`, `unsupported_parameter_type`,
`invalid_parameter_default`, `invalid_parameter_bounds`, `invalid_parameter_values`,
`invalid_footprint`, `invalid_dimension`, `invalid_origin`, `invalid_entity`,
`invalid_entity_id`, `invalid_entity_name`, `unknown_entity_prototype`, `unsupported_entity_type`,
`no_placeable_item`, `invalid_position`, `invalid_direction`, `unknown_quality`, `unknown_recipe`,
`incompatible_recipe`, `unsupported_entity_configuration`, `unknown_field`, `invalid_port`,
`invalid_port_id`, `invalid_port_type`, `invalid_port_role`, `unknown_item`, `unknown_fluid`,
`duplicate_port_id`, `port_outside_footprint`, `duplicate_entity_id`, `entity_outside_footprint`,
`entity_overlap`, `reserved_outside_footprint`, `unknown_resource`, `unsupported_constraint`,
`unknown_technology`, `duplicate_module_id`, `module_load_failed`, `manifest_load_failed`.

A validation error excludes the whole module. There is no best-effort partial load.

## 12. Valid example

The shipped stone-furnace bank (abridged):

```lua
return {
  schema_version = 1,
  id = "nauvis.stone_furnace.iron_smelting",
  module_version = 1,
  name = "Stone furnace iron smelting bank",
  description = "One to three stone furnaces with ore, fuel and plate interfaces.",
  category = "smelting",
  surfaces = {"nauvis"},
  stages = {"early_game", "automation_bootstrap", "automation"},
  tags = {"nauvis", "smelting", "furnace", "iron-plate"},
  geometry = {
    footprint = {width = 2, height = 2},
    origin = {x = 0, y = 0},
    supported_orientations = {0},
    entities = {
      {
        id = "furnace",
        name = "stone-furnace",
        position = {x = 1, y = 1},
        direction = 0,
        repeat_by = {parameter = "unit_count", step = {x = 2, y = 0}},
      },
    },
    ports = {
      {
        id = "ore_input", type = "item", role = "input", item = "iron-ore",
        position = {x = 0, y = 1}, direction = 4,
        repeat_by = {parameter = "unit_count", step = {x = 2, y = 0}},
      },
      {
        id = "fuel_input", type = "item", role = "input", item = "coal",
        position = {x = 1, y = 0}, direction = 8,
        repeat_by = {parameter = "unit_count", step = {x = 2, y = 0}},
      },
      {
        id = "plate_output", type = "item", role = "output", item = "iron-plate",
        position = {x = 2, y = 1}, direction = 4,
        repeat_by = {parameter = "unit_count", step = {x = 2, y = 0}},
      },
    },
    reserved = {},
  },
  requirements = {technologies = {}, recipes = {"iron-plate"}},
  placement = {constraints = {{type = "clear_footprint"}}},
  parameters = {
    unit_count = {type = "integer", default = 1, minimum = 1, maximum = 3,
      affects_geometry = true, description = "Number of repeated stone furnaces."},
  },
}
```

With `unit_count = 3` the effective footprint is `6 x 2`; furnace positions are
`{1,1}`, `{3,1}`, `{5,1}`. Port IDs become `ore_input`, `ore_input_2`, `ore_input_3`, etc.

## 13. Invalid examples

| Invalid definition | Rejection |
| --- | --- |
| `schema_version = 2` | `unsupported_schema_version` |
| `id = "Not Stable"` | `invalid_module_id` |
| entity `name = "not-a-real-entity"` | `unknown_entity_prototype` |
| entity `direction = 2` | `invalid_direction` |
| entity `position = {x=1.25, y=1.5}` | `invalid_position` |
| `footprint.width = 0` | `invalid_dimension` |
| two ports with the same `id` | `duplicate_port_id` |
| port at `{x=9, y=1.5}` in a 3-wide module | `port_outside_footprint` |
| a stone furnace with `recipe = "iron-plate"` | `unsupported_entity_configuration` |
| an entity key named `insert_plan` | `unknown_field` |
| `requirements.technologies = {"missing"}` | `unknown_technology` |
| parameter `{type="formula"}` | `unsupported_parameter_type` |
| two files with the same module `id` | `duplicate_module_id` (both excluded) |

## 14. Adding a module

1. Create `mod/factorio_autonomous_engineer/modules/<name>.lua` returning one literal table.
2. Add exactly one `modules.<name>` path to `modules/manifest.lua`.
3. Keep coordinates on the half-grid convention and advertise only verified orientations.
4. Add the module to the Python static tests and, for a new entity/constraint capability, extend
   the engine scenario.
5. Run `uv run pytest -q tests`, package the mod, and run
   `tests/engine/s7_module_catalog.py` plus the existing construction/reliability scenarios.
6. Record the exact archive SHA-256 and engine result. A module is not "production ready" merely
   because its ghosts were created; construction, material cost and entity configuration must be
   observed in Factorio.

## 15. Unsupported in Stage 4

- Layout Planner / automatic site search or optimization.
- Arbitrary belt, pipe, rail, circuit or wire routing between ports.
- Blueprint import/export as a canonical source, blueprint books, tile ghosts.
- Insert plans, modules, equipment, ammunition or item-request proxies in module definitions.
- Logistic-network or construction-robot delivery.
- Automatic deconstruction, module removal or repair.
- Mirroring.
- Planetary libraries beyond Nauvis.
- A second material-transfer or construction implementation.
- A LuaPlayer migration.
