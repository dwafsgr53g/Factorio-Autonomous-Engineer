# Stage 6 verification — physical logistics

Status: **IMPLEMENTED**, **UNIT TESTED**, **AUTOMATED ENGINE TESTED** on Factorio 2.1.24.
**HUMAN MULTIPLAYER TESTED** is pending the real-player acceptance gate; this report does not
claim it.

## Environment

| Item | Value |
| --- | --- |
| Factorio | 2.1.24 (build 87808, win64, steam) |
| Runtime profile | isolated `.runtime/factorio-stage6` (not the Stage-5 acceptance profile) |
| RCON | `127.0.0.1:27076` (loopback, password supplied through the environment only) |
| Game port | `27037` |
| Save | disposable copies of `baseline.zip`; never the Stage-5 world |
| Mod | `factorio_autonomous_engineer_0.1.0.zip` built from the tested Git mod tree |
| Active mods | base, elevated-rails, quality, recycler, space-age, planet-express |

`tests/engine/harness.py` now stops only the Factorio process whose command line contains the
selected `FACTORIO_TEST_DIR`. The Stage-5 server on its own profile and port was preserved
throughout.

## Scenario fixtures

`tests/engine/stage6_fixture.py` creates only prerequisites on a disposable save:

- all research on the disposable force;
- a clear test area around a real iron patch and a home point;
- a legitimate solar-powered electric network with an accumulator and a medium pole;
- an ordinary wooden chest containing 100 coal;
- optional construction materials, either directly in the agent inventory or in an ordinary
  chest for the material-collection path.

The fixture does **not** place modules, belts, inserters, poles, the output chest or any real
production entity for the agent. The agent builds those through
`execute_task(task="build_logistics")` and the paid ghost executor.

## Changed files

Production:

- `mod/factorio_autonomous_engineer/lib/logistics.lua` (new)
- `mod/factorio_autonomous_engineer/lib/tasks.lua`
- `mod/factorio_autonomous_engineer/lib/layout_planner.lua`
- `mod/factorio_autonomous_engineer/lib/collaboration.lua`
- `mod/factorio_autonomous_engineer/lib/construction.lua`
- `mod/factorio_autonomous_engineer/modules/nauvis_electric_mining_iron.lua`
- `mod/factorio_autonomous_engineer/control.lua`
- `mod/factorio_autonomous_engineer/lib/strategy.lua`
- `src/factorio_autonomous_engineer/server.py`
- `src/factorio_autonomous_engineer/logistics.py` (new reference implementation)

Tests and tooling:

- `tests/test_logistics.py` (new)
- `tests/engine/s9_belt_routing.py` (new)
- `tests/engine/s10_inserters.py` (new)
- `tests/engine/s11_power_distribution.py` (new)
- `tests/engine/s12_gear_production.py` (new)
- `tests/engine/stage6_fixture.py` (new)
- `tests/engine/harness.py`, `tests/engine/mcp_client.py`, `tests/engine/README.md`
- `tests/engine/s7_module_catalog.py` (mining entity direction expectation)

Documentation and skills:

- `docs/logistics.md` (new), `docs/architecture.md`, `docs/tasks.md`, `docs/safety.md`,
  `docs/roadmap.md`, `docs/engine-test-plan.md`, `docs/layout-planner.md`,
  `docs/module-library.md`, `README.md`
- `skills/core_strategy.md`, `skills/stages/automation.md`,
  `skills/stages/automation_bootstrap.md`

## Defects found and corrected

1. **North-facing mining drill vs east output port.** The Stage-4 mining module declared an east
   `ore_output` port but created the real drill with direction `0` (north). Ore was dropped on the
   tile above the module and could never enter a belt routed from the declared port. The entity
   direction is now east, and all rotations rotate entity and port together.
2. **Adjacent same-prototype identity collision.** `construction.find_real_entity` accepted any
   same-name entity within 1.5 tiles. Adjacent belts/inserters were misidentified as the target,
   leaving the real ghost unbuilt. Identity matching is now exact within 0.25 tiles.
3. **Character inside a large ghost.** The construction approach could stop inside a 2x2/3x3 ghost
   and then report blocked terrain. The approach excludes the target footprint, arrival tolerance
   is tighter for logistics construction, and the executor steps out before another attempt.
4. **Failed physical plans were cached.** A `missing_power_source`/`missing_fuel_source`/blocked
   physical plan is now recomputed on a later run after the player supplies the prerequisite.
5. **Power detection with zero current solar demand.** The planner now also recognises real
   producer prototypes on the same bounded electric network, instead of only relying on current
   flow fields.

## Impact analysis

| Changed area | Affected contracts | Scenarios selected |
| --- | --- | --- |
| mining module direction | Stage-4 module geometry, Stage-5 rotations/ports | `s7`, `s8`, Stage-6 suite |
| `construction.find_real_entity` / approach | paid construction identity, player-build reconciliation, clearing approaches | `s5`, `s6`, `s7`, `s8`, Stage-6 suite |
| layout-planner finalization + `logistics_chain` | plan fingerprints, apply/idempotency, stale-plan checks | `s8`, Stage-6 suite |
| collaboration ghost filter | construction scanning, player ghosts | `s5`, `s6`, `s8`, Stage-6 suite |
| new composite task + persistence | task start/status/cancel/resume, save/load, safety/death | `s12` persistence/interruption scenarios |
| Python reference/docs only | fast checks | unit suite only |

Skipped engine groups and reasons:

- `s1`, `s2`, `s3`, `s3b` — gather, safety and lifecycle code paths were not changed. The new task
  was tested for safety and death in `s12`.
- `s4`, `s4b` — RCON, bridge and MCP transport code was not changed by Stage 6.

No skipped test is labelled PASS.

## Fast checks

| Command | Result |
| --- | --- |
| `uv run ruff check .` | PASS |
| `uv run pytest -q tests` | **67 passed** in 1.19 s |

The unit suite covers the deterministic A* reference: straight routes, turns, obstacle avoidance,
blocked starts/goals, endpoint overrides, non-mutation of the blocked grid, budgets, gap arithmetic
and belt endpoint geometry.

## Targeted engine results

All runs used the isolated Stage-6 profile and exited 0.

| Scenario | Checks | Result | Duration |
| --- | --- | --- | --- |
| `s9_belt_routing.py` | 21/21 | PASS | 77 s |
| `s10_inserters.py` | 17/17 | PASS | 128 s |
| `s11_power_distribution.py` | 15/15 | PASS | 85 s |
| `s12_gear_production.py` | 33/33 | PASS | 322 s |
| `s5_construction.py` | 50/50 | PASS | 75 s |
| `s6_construction_persistence.py` | 44/44 | PASS | 117 s |
| `s7_module_catalog.py` | 84/84 | PASS | 57 s |
| `s8_layout_planner.py` | 64/64 | PASS | 47 s |

### Actual production observed

`s12` recorded a real chain built entirely through the paid executor:

- electric mining drill extracts iron ore;
- ore is carried by engine transport belts to a real ore inserter and into the stone furnace;
- coal is removed from an ordinary wooden chest by an inserter, carried by real belts and inserted
  into the furnace;
- the furnace consumes fuel and produces iron plates;
- plates are removed by an inserter, carried on a belt and inserted into the assembling machine;
- the assembling machine has recipe `iron-gear-wheel` and produces gear wheels;
- an output inserter places gear wheels in the real output chest;
- the task reports `production_observed` only after a gear count increase over actual game ticks.

Additional evidence:

- all six logistics inserters report real pickup/drop targets and correct pickup directions;
- a full output chest stops the output inserter (`status 38`, waiting for space) and production
  resumes after the chest is drained;
- every required machine/inserter is connected to the real powered network;
- removing generation makes verification report no power and unpowered entities honestly;
- emptying the coal chest before production produces a blocked/missing-fuel result and no gear;
- save/load during construction, material collection and monitoring preserves task identity,
  progress and exact item counts without duplication;
- safety pre-emption and death both pause the task until explicit resume, which then completes the
  same chain without duplicate modules;
- a player building placed on a not-yet-built route tile prevents success and remains intact.

## Archive verification

- Tested mod-tree commit: `b5f679e8038a3779c91e83f2000465b47372b4e2`
- Tested scenario commit: `7137c46de54c4fa74b8f306ed83d9438e5410f84`
- Documentation commit containing this report: `e78d8d2d49cfd1b6cc425c10daa095cd974f0028`
- Archive: `dist/factorio_autonomous_engineer_0.1.0.zip`
- Archive SHA-256: `960de382cda4e6ffcfdef339007c32c39dd65731f24bbf84dc7a14851cc371bf`
- Archive size: 86,366 bytes
- Entries: 21; Git mod blobs: 21; mismatches: **none**
- Comparison: every archive entry was read byte-for-byte and compared with
  `git show HEAD:mod/factorio_autonomous_engineer/<entry>`.

The archive was rebuilt from the committed, clean mod tree after the engine runs. It is
byte-identical to the tested tree (the archive builder normalizes CRLF checkout endings to the LF
bytes stored by Git).

## Known limitations

- Underground belts are not implemented; routes must fit on ordinary surface belts.
- Splitters, lane balancing and branching/merging networks are not implemented.
- Only one linear eastward chain starting from a catalog mining module is supported.
- Fluids, pipes, rail, circuits and logistic networks are out of scope.
- Power generation and autonomous coal mining are external prerequisites, not built by the agent.
- Only medium/small electric poles are considered.
- No throughput optimization or production-rate sizing.
- Vehicle/Spidertron player detection is limited to physical entities, as in Stage 5.
