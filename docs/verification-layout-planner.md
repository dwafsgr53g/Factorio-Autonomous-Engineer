# Stage 5 Layout Planner verification report

Date: 2026-11-15
Status: **IMPLEMENTED**, **UNIT TESTED**, **AUTOMATED ENGINE TESTED**
Human multiplayer acceptance: **PENDING — waiting for a real Factorio client to join the isolated
test server.**

Tested runtime: Factorio **2.1.24** (build 87808, Windows Steam binary), isolated write-data
directory `.runtime/factorio-test`. Mod set: base, elevated-rails, quality, recycler, space-age,
planet-express 2.1.12, `ae_probe` and factorio_autonomous_engineer 0.1.0. `factorio_llm_use` was
disabled in this profile. The RCON password was supplied only through the required
`FACTORIO_RCON_PASSWORD` environment variable and is not recorded in the repository or this report.

Tested mod archive: `dist/factorio_autonomous_engineer_0.1.0.zip`

- SHA-256: `1dab788e6f88c2b92e7a4d8e293d93dd146c901bf930728bf079366c265a5bc6`
- Size: 67,232 bytes; 20 files.
- Tested mod-tree commit: `38dc7ca4a5070f4f748dd3f0c5bd9137bb9ea85b`
  (`feat: add deterministic layout planner`). Later test, documentation and packaging commits do
  not change the mod tree.
- Repository HEAD at verification time: `9fbc05507dd2ca715e3629c7937153e5e996c7f1`.
- Every archive entry was compared byte-for-byte with
  `HEAD:mod/factorio_autonomous_engineer/<path>` using the canonical Git blobs. There were no
  missing, extra or mismatched entries. The packaging script normalizes Windows CRLF checkout
  endings to the LF bytes stored by Git.

## 1. Implemented components

Mod:

- `lib/production_graph.lua` — catalog/recipe dependency resolution, port matching, missing
  supplier/fuel/infrastructure reporting, extraction detection and electric-network evaluation.
- `lib/layout_planner.lua` — bounded candidate generation, hard-constraint checks, deterministic
  scoring/tie-breaking, connection metadata, plan/environment fingerprints, persistence,
  revalidation, stale-plan refusal and idempotent ghost-only application.
- `lib/module_placer.lua` — non-mutating `evaluate()` plus plan-ID ghost tags and ignored-instance
  support for safe revalidation. It still creates only entity ghosts.
- `control.lua` — internal full-record planning operations and compact model-facing
  `plan_layout` / `apply_layout` operations.
- `lib/strategy.lua` — `plan_layout` / `apply_layout` capability gating on planet surfaces.
- `lib/lifecycle.lua` — includes the registered home in status for internal setup/setup checks.

Python/MCP:

- `src/factorio_autonomous_engineer/layout_planner.py` — reference dependency/placement/fingerprint
  implementation for the unit suite.
- `src/factorio_autonomous_engineer/server.py` — two model-facing MCP tools.

Tests:

- `tests/test_layout_planner.py` — 23 unit tests.
- `tests/engine/s8_layout_planner.py` — 64 engine checks A–E.
- `tests/engine/harness.py` and `tests/engine/mcp_client.py` — internal planner helpers, scenario
  setup and MCP tool probes.

Documentation: `docs/layout-planner.md`, plus updates to the architecture, task, roadmap, engine
test plan, module format/library and engine README docs.

## 2. Static and unit verification

Commands:

```text
uv run ruff check .
uv run pytest -q tests
```

Results:

- Ruff: pass.
- Pytest: **56 passed**, including the 23 new layout-planner tests.

Unit coverage includes dependency graph construction, recipe/port matching, incompatible ports,
missing suppliers, external fuel/electric dependencies, deterministic candidate generation,
documented scoring/tie-breaking, resource constraints, footprint/reserved collisions, all
orientations, player/ghost obstacles, plan fingerprints, environment signatures, stale-plan
detection, JSON persistence round trips and idempotent application state. Public-summary tests
assert that no coordinates, ports, entity lists, positions or unit numbers leak.

## 3. Automated engine verification

Final archive results:

| Scenario | Result |
| --- | --- |
| `s8_layout_planner.py` | **PASS**, 64 checks |
| `s7_module_catalog.py` | **PASS**, 84 checks |
| `s1_save_load.py` | **PASS** |
| `s2_attack.py` | **PASS** |
| `s3_death.py` | **PASS** |
| `s3b_unsafe_home.py` | **PASS** |
| `s4_rcon.py` | **PASS** |
| `s4b_mcp_restart.py` | **PASS** |
| `s5_construction.py` | **PASS**, 50 checks |
| `s6_construction_persistence.py` | **PASS**, 44 checks |

Stage-5 observations on the iron-gear demonstration:

- Live recipes resolved the chain iron ore → iron plate → iron gear wheel and selected exactly
  `nauvis.electric_mining.iron`, `nauvis.stone_furnace.iron_smelting` and
  `nauvis.assembling_machine_1.gear`.
- The mining footprint contained iron ore (amount and entity minimums satisfied).
- Coal fuel and electric-network infrastructure were reported as explicit unresolved dependencies
  when no pole network existed.
- Two item connections were `route_required` with measured port distances; no physical connection
  was claimed.
- Plan creation created no ghost/real entity and left inventory unchanged. Identical world state
  reproduced the same plan ID, fingerprint and anchors.
- All four mining orientations produced materializable plans with the correct rotated footprint
  and transformed output port.
- Existing buildings, player construction ghosts and a real player character were avoided; the
  objects remained unchanged.
- Natural trees were recorded as clearing preparation; the plan still materialized only ghosts.
- Apply created exactly three ghosts, no real module entity and no inventory change.
- Repeated apply returned `already_applied` with no duplicate ghosts.
- Plan, application state and ghost identities survived save/load.
- A cancelled plan ghost was not recreated. A player-built plan entity was recognised and not
  duplicated.
- New real buildings, player ghosts, player activity and resource removal caused `stale_plan`
  refusal with zero new ghosts.
- The Stage-3 named ghost plan and paid construction regressions still pass.

## 4. Honest limitations

- The resulting 3-module layout is **not** an operational factory.
- No belts, pipes, inserters, wires, fuel insertion, power generation or physical routing exist.
- Coal fuel and electric infrastructure remain unresolved unless the live world already has a
  nearby live electric network; even then, pole presence does not prove supply-area coverage.
- No throughput analysis or production-rate claim is made.
- The planner searches only the code-owned 64-tile work area.
- Automated obstacle checks use test characters; they do not substitute for the human multiplayer
  acceptance test.

## 5. Human multiplayer acceptance (pending)

This state must not be marked passed until a real Factorio client joins the isolated server and the
interactive checks complete. Phase A ends with the server running and
`STATUS: WAITING_FOR_USER_JOIN`. Phase B resumes only after the user explicitly confirms the
connection, verifies the real player character in the running world, generates and applies the
iron-gear plan, and checks that the player's buildings/blueprints/activity were preserved.
