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

## Stage 5 boundary

Stage 4 stops at the module format, catalog, validation and deterministic ghost instantiation. The
next stage may implement a Layout Planner that selects modules, chooses supported sites and submits
internal placement specifications. Stage 4 does not implement automatic site search, whole-base
generation, inter-module belt/pipe/rail/circuit routing, throughput optimization, logistic-network
delivery or blueprint-book ingestion.

## Next parity work

- Add a general goal/plan executor and a stage/planet-aware capability registry.
- Add high-level automation, crafting, delivery, repair and refuelling workflows.
- Build the Layout Planner on top of the Stage-4 catalog and instantiator; the LLM should submit intent and constraints, not each placement coordinate. The current construction executor handles a small code-owned test plan, player ghosts and internal module ghosts.
- Add module/equipment-aware ghost requests and item-request-proxy handling, arbitrary belt/pipe layout, construction robots and logistics-network delivery after the paid-ghost foundation is extended.
- Add planet-specific bootstrap/site planners and survival skills for Vulcanus, Fulgora, Gleba and Aquilo.
- Add production and science-chain analysis as compact strategic state.
- Add rail/logistics plans, then circuits and platform operations, behind high-level goals.
- Add configurable safety settings, enemy-force policy, retreat priorities and base-defense logic.
- Build automated Factorio 2.1.24 engine tests for stage transitions, site selection, save/load, task cancellation, hostile attacks, death, respawn and recovery.

No parity item should be described as implemented until it has code, tests and a recorded engine verification result. The next major step is a general goal/plan executor and capability registry whose MCP surface is scoped by the active stage and planet. Do not expose low-level action tools as a shortcut to filling missing capabilities.
