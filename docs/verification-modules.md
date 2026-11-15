# Stage 4 module system verification report

Date: 2026-11-15
Status: **IMPLEMENTED**, **UNIT TESTED**, **ENGINE TESTED**

Tested runtime: Factorio **2.1.24** (build 87808, Windows Steam binary), isolated write-data
directory `.runtime/factorio-test`. Mod set: base, elevated-rails, quality, recycler, space-age,
planet-express 2.1.12, `ae_probe` and factorio_autonomous_engineer 0.1.0. `factorio_llm_use` was
disabled in this test profile. The RCON password was supplied only through the required
`FACTORIO_RCON_PASSWORD` environment variable and is not recorded in the repository or this report.

Tested mod archive: `dist/factorio_autonomous_engineer_0.1.0.zip`

- SHA-256: `8306fe6fd39cc0f67abd7c50f0b065879a2861c4a32529b9be33e0e926bed3e4`
- Tested mod-tree commit: `651de9e6ce1b78cf427b4583f65bfc54efdcbb72`
- The archive contains 18 files. Every archive entry was compared byte-for-byte with
  `HEAD:mod/factorio_autonomous_engineer/<path>`; there were no mismatches. Later documentation or
  test-harness-only commits do not change the mod tree or the archive hash.

## 1. Canonical format choice

The canonical representation is a **pure declarative Lua data table** per module under
`mod/factorio_autonomous_engineer/modules/`, listed once by `modules/manifest.lua`.

Rationale:

- Factorio 2.1 can load it with `require`; no arbitrary filesystem API is needed.
- Factorio 2.1 only allows `require` during `control.lua` parsing, so `modules/library.lua`
  preloads the manifest and module files at parse time. Runtime catalog operations read the
  preloaded tables. There is no runtime filesystem scan and no dynamic evaluation.
- Definitions contain only literals; functions, calls, variables and expressions are rejected by
  the Python declarative reader and are not part of the schema.
- The Python unit suite reads the same files, so there is one canonical definition per module and
  no duplicated/generated module data in Git.
- Blueprint strings are not the source of truth; blueprint interop is deferred.

Trade-offs are documented in [module-format.md](module-format.md).

## 2. Implemented components

New mod files:

- `lib/module_format.lua` — schema v1 constants, strict validation, prototype/recipe/technology
  checks, geometry expansion, parameter resolution, rotation of entities/ports/reserved areas,
  availability checks and cost estimation from live placeable-item prototypes.
- `lib/modules.lua` — manifest/catalog loading, duplicate-ID rejection, stable lookup, validation
  diagnostics, force/surface/stage availability and summary metadata.
- `modules/library.lua` — parse-time loader for the explicit manifest and module files.
- `modules/manifest.lua` + the three module data files.
- `lib/module_placer.lua` — internal deterministic ghost placement, placement constraints, obstacle
  checks, module tags, save-persistent instance records, deduplication and instance status.

Changed mod files:

- `control.lua` — internal module catalog/validate/resolve/instantiate/status operations. These are
  RCON-only and are not MCP tools.
- `lib/construction.lua` — after a successful paid revival, applies and verifies an
  `ae_recipe` module tag for assembling machines.
- `lib/tasks.lua` — records module configuration errors in construction entry/result/status.
- `lib/collaboration.lua` — aggregates `configuration_errors` and failure reasons.

New Python/tests:

- `src/factorio_autonomous_engineer/module_format.py` — strict declarative reader, reference
  validator and geometry transform for the unit suite.
- `tests/test_module_format.py` — 22 module-format unit tests.
- `tests/engine/s7_module_catalog.py` — 84 engine checks A–E.
- `tests/engine/harness.py` — internal module helpers and resource-anchor discovery.

Documentation: `docs/module-format.md`, `docs/module-library.md`, and updates to
`docs/architecture.md`, `docs/roadmap.md`, `docs/tasks.md`, `docs/engine-test-plan.md`,
`README.md` and `tests/engine/README.md`.

## 3. Initial module library

| ID | Function | Configuration |
| --- | --- | --- |
| `nauvis.electric_mining.iron` | One electric mining drill on iron ore | 3x3 base, 3x4 effective with output clearance; all four orientations; iron-ore output and electric input ports; resource-patch + clear-footprint constraints; `electric-mining-drill` technology |
| `nauvis.stone_furnace.iron_smelting` | One to three stone furnaces | `unit_count` 1..3 repeats the furnace and ore/fuel/plate ports; orientation 0 (non-rotatable entity); `iron-plate` process recipe |
| `nauvis.assembling_machine_1.gear` | One assembling machine making iron gear wheels | 3x3 base, 3x4 effective with service access; orientation 0; plate input, gear output, electric input; `automation` + `iron-gear-wheel`; post-revival recipe assignment |

These demonstrate three different entity configurations and three different placement/connection
profiles. They are not a complete working factory.

## 4. Schema/behavior supported

- Stable module IDs, schema version, module version, category, surfaces, intended stages, tags.
- Local top-left anchor, base footprint, effective bounds, reserved/clearance rectangles.
- Entity prototype name, entity-center half-tile positions, cardinal direction, explicit quality,
  fixed assembling-machine recipe and deterministic `repeat_by` expansion.
- Item, fluid and electric ports with stable IDs, role, position, direction, item/fluid and
  repeat expansion.
- Technology, recipe, item-recipe, stage and surface requirements, with availability separated
  from prototype existence.
- Placement constraints for resource patches, water proximity, clear footprints, avoided
  entities/tiles and existing electric networks.
- Integer, string and boolean parameters with defaults, bounds/allowed lists and deterministic
  geometry expansion for every allowed geometry-parameter combination.
- 0/90/180/270-degree rotation of entity positions/directions, ports and reserved areas. Mirroring
  is not supported and not advertised.
- Cost estimates derived from `items_to_place_this` (including repeats and quality) and live exact
  payment by the existing executor. Module definitions never override live ghost checks.

## 5. Unsupported/deferred

Layout Planner, automatic site search/optimization, whole-base generation, arbitrary
belt/pipe/rail/circuit/wire routing, blueprint-book ingestion, insert plans/modules/equipment,
logistic-network or construction-robot delivery, automatic deconstruction, mirrored modules,
non-Nauvis libraries, planetary validation and a new construction/material-transfer executor remain
out of scope. The module operations are not exposed as MCP tools; the LLM still receives no
coordinates, entity lists or per-building actions. Player-blueprint assistance is unchanged.

## 6. Unit tests

- `uv run pytest -q tests` — **33 passed**.
- `uv run python -m unittest discover -s tests -v` — **33 tests, OK**.
- `uv run ruff check .` — **All checks passed**.

The module unit tests cover: valid library definitions, unsupported schema version, duplicate IDs,
unknown prototypes, invalid directions/positions/footprints, duplicate/out-of-bounds ports,
unknown recipes/technologies, unsupported entity configuration, unsupported/unknown parameters,
invalid parameter values, deterministic repeat expansion, every advertised orientation, and
rotation of entity positions, directions, ports and reserved areas. They are not evidence of
Factorio behaviour; the engine results below are.

## 7. Engine scenario `s7_module_catalog.py`

Result: **84 checks, 0 failed — PASS**.

### A — catalog loading and invalid definitions

- Initial catalog: `loaded=3`, `invalid=0`, no catalog errors.
- Stable IDs resolved. Before research, the furnace was available while the mining drill reported
  `technology_not_researched:electric-mining-drill` and the assembler reported
  `technology_not_researched:automation` (plus their item-recipe reasons).
- After test-force research, all three modules were available.
- 11 malformed definitions were rejected with explicit diagnostics: schema version, unknown entity,
  invalid direction, invalid position, malformed footprint, duplicate port ID, port outside
  footprint, unknown recipe, unknown technology, unsupported entity field and unsupported
  parameter type.

### B — ghost instantiation

- All three modules instantiated at test-controlled locations.
- Ghost counts matched declared entities: mining 1, furnace bank `unit_count=3` 3, assembler 1.
- No real buildings were created for any module.
- Agent inventory remained `{}` before and after each instantiation.
- Instance status reported `pending` with the expected entity counts.

### C — geometry, ports, reserved areas and constraints

- Mining drill: all four advertised orientations instantiated; ghost positions/directions matched
  the resolved transforms (`31.5,-30.5)/0`, `(32.5,-30.5)/4`, `(31.5,-29.5)/8`,
  `(31.5,-30.5)/12`), and the output port directions/positions and reserved clearance strip were
  transformed correctly in each orientation.
- Furnace bank `unit_count=3`: footprint `6x2`, three ghost positions at x offsets 1/3/5, nine
  repeated port IDs (`ore_input`, `_2`, `_3`, etc.).
- Assembler: ghost at `{57.5,9.5}` direction 0; service reserved area returned as
  `{56,11}..{59,12}`.
- A real wooden chest in the mining footprint was rejected with
  `blocked_by_existing_entity` (details `wooden-chest:1`).
- An off-resource mining placement was rejected with `constraint_failed` /
  `resource_patch_missing`.

### D — paid construction integration

- Furnace bank `unit_count=2`: `assist_construction` built both entities at `{43,9}` and `{45,9}`
  with direction 0; inventory went `{stone-furnace:2}` to `{}`; no ghosts remained; instance status
  became `built`.
- Assembler: built at `{47.5,9.5}`; inventory went `{assembling-machine-1:1}` to `{}`; the real
  machine had recipe `iron-gear-wheel` and direction 0; `configuration_errors=0`; instance status
  `built`.
- No free buildings, duplicate buildings or duplicate item consumption were observed.

### E — save/load, identity and resume

- Two furnace ghosts were saved and reloaded. The module instance key, module ID, pending status
  and two ghost unit numbers survived.
- Re-instantiating the same key/fingerprint returned `deduplicated=true`; the ghost count remained 2
  and no duplicate instance record was created.
- A construction task was started, moved, saved mid-move and reloaded. The task ID survived and the
  task completed with `built_by_agent=2`; exactly two furnaces existed once, the inventory became
  `{}`, no ghosts remained, and the module instance became `built`.

## 8. Existing regression scenarios (same archive)

- `tests/engine/s1_save_load.py` — PASS
- `tests/engine/s2_attack.py` — PASS
- `tests/engine/s3_death.py` — PASS
- `tests/engine/s3b_unsafe_home.py` — PASS
- `tests/engine/s4_rcon.py` — PASS
- `tests/engine/s4b_mcp_restart.py` — PASS
- `tests/engine/s5_construction.py` — **50 checks, 0 failed — PASS**
- `tests/engine/s6_construction_persistence.py` — **44 checks, 0 failed — PASS**

A pre-existing timing race in the H1 save/load check could let the task finish between the
observation and the save. The test harness now pauses game ticks across the save/reload and unpauses
after loading; the production mod was not changed. The final rerun on this archive passed.

## 9. Status separation

**IMPLEMENTED:** schema v1, declarative loader/manifest, catalog, duplicate/ID/validation handling,
force/surface/stage availability, parameters and repeat expansion, rotation/port/reserved transforms,
placement constraints, ghost-only instantiation, instance identity/deduplication/status, module
recipe tag application by the existing paid executor, and the three Nauvis modules.

**UNIT TESTED:** 33 Python tests and Ruff, including the strict declarative reader and reference
schema/geometry rules.

**ENGINE TESTED:** 84 Stage-4 checks on Factorio 2.1.24 (catalog diagnostics, ghost-only
instantiation, all advertised mining orientations, ports/reserved transforms, collisions,
off-resource rejection, paid furnace and assembler construction, recipe verification, save/load
identity/deduplication and construction resume), plus all eight existing construction/reliability
scenarios on the same archive.

Not tested/not claimed: a complete working factory, a Layout Planner, inter-module routing, power
wiring, automated resource-site search, non-Nauvis modules, blueprint import/export, module/equipment
insertion, construction robots, logistic delivery, mirroring, or automatic deconstruction.
