# Roadmap

This is an early alternative implementation, not yet a feature-complete fork/replacement. The goal is to preserve the useful integration pattern while moving action orchestration and survival out of the model's reasoning loop.

## 0.1.0-dev scaffold

- Separate Factorio mod and Python MCP package.
- Strategic profile detects active planet/domain and game stage from Factorio state and research.
- Plain-Markdown skill loading by stage and planet; only high-level supported goals are advertised.
- Nauvis-only starting-site selection scores basic resource access, water, hostile presence, free building space and generated-terrain confidence; selected site becomes home.
- Loopback Source RCON bridge adapted from upstream transport code.
- One composite gather_resource task with internal pathfinding, movement and mining phases.
- Python-side wait loop; intermediate task status checks are not exposed as separate MCP results.
- Independent enemy/damage safety controller with retreat and conditional return fire.
- Persistent logical agent lifecycle: death, recovery bags, delayed safe respawn.
- Bounded event queue, cursor-based event retrieval, task resume/cancel.
- Stage-3 construction executor: ghost-only named plans, paid `revive()` builds, ordinary-chest item acquisition, natural tree/rock clearing, player-ghost collaboration, cancellation/change reconciliation, save/load and safety/resume integration.
- Stage-4 declarative module format and catalog: versioned pure-data module definitions, strict
  schema/geometry/port/parameter validation, force-aware requirements, deterministic rotation and
  parameter expansion, ghost-only internal instantiation, save-persistent instance identity and
  deduplication, and a three-module Nauvis starter library (electric iron mining, stone-furnace
  smelting bank, iron-gear assembling machine).

## Stage 5 — Layout Planner

Stage 5 adds a deterministic Layout Planner on top of the Stage-4 catalog:

- production dependency resolution from module ports and live recipes;
- bounded candidate placement inside the existing work area with resource, terrain and electric
  constraints;
- hard avoidance of buildings, vehicles, player construction ghosts and player work areas;
- documented deterministic scoring/tie-breaking and plan/environment fingerprints;
- persistent two-phase `plan_layout` / `apply_layout` lifecycle, stale-plan rejection and
  idempotent ghost-only application;
- explicit coal/fuel and electric-infrastructure dependencies and route-required item edges;
- human multiplayer acceptance remains a separate gate.

Still out of scope: belt/pipe/rail/circuit/wire routing, inserter placement and fuel insertion,
power generation, throughput optimization, complete starter-base generation, construction robots,
logistic delivery, blueprint-book ingestion, planetary module libraries and deconstruction.

## Next parity work

- Add a general goal/plan executor and a stage/planet-aware capability registry.
- Add high-level automation, crafting, delivery, repair and refuelling workflows.
- Extend the Stage-5 planner with routing, power/fuel modules and production-rate-aware sizing after those capabilities exist.
- Add module/equipment-aware ghost requests and item-request-proxy handling, arbitrary belt/pipe layout, construction robots and logistics-network delivery after the paid-ghost foundation is extended.
- Add planet-specific bootstrap/site planners and survival skills for Vulcanus, Fulgora, Gleba and Aquilo.
- Add production and science-chain analysis as compact strategic state.
- Add rail/logistics plans, then circuits and platform operations, behind high-level goals.
- Add configurable safety settings, enemy-force policy, retreat priorities and base-defense logic.
- Build automated Factorio 2.1.24 engine tests for stage transitions, site selection, save/load, task cancellation, hostile attacks, death, respawn and recovery.

No parity item should be described as implemented until it has code, tests and a recorded engine verification result. The next major step is a general goal/plan executor and capability registry whose MCP surface is scoped by the active stage and planet. Do not expose low-level action tools as a shortcut to filling missing capabilities.
