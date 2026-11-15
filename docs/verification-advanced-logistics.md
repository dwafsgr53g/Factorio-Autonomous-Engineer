# Stage 7 verification — advanced logistics

Status: **IMPLEMENTED**, **UNIT TESTED**, **AUTOMATED ENGINE TESTED** on Factorio
2.1.24. Human multiplayer acceptance is recorded separately below after the mandatory
checkpoint.

## Environment

| Item | Value |
| --- | --- |
| Factorio | 2.1.24 (build 87808, win64, steam) |
| Runtime profile | isolated `.runtime/factorio-stage7-test` |
| RCON | `127.0.0.1:27078` (loopback; password supplied through the environment only) |
| Game port | `27039` |
| Baseline | `saves/s7-baseline.zip` created by the same executable and mod set |
| Mod | `factorio_autonomous_engineer_0.1.0.zip` built from the tested Git mod tree |
| Active mods | base, elevated-rails, quality, recycler, space-age, planet-express |
| Test speed | 60 for routine scenarios; 1–5 for save/load, cancellation, safety and death windows; human server at 1 |

The Stage-5 and Stage-6 profiles and worlds were not used by Stage-7 automated scenarios.

## Changed files

Production:

- `mod/factorio_autonomous_engineer/lib/transport.lua` (new)
- `mod/factorio_autonomous_engineer/lib/logistics.lua`
- `mod/factorio_autonomous_engineer/lib/layout_planner.lua`
- `mod/factorio_autonomous_engineer/lib/tasks.lua`
- `mod/factorio_autonomous_engineer/lib/construction.lua`
- `mod/factorio_autonomous_engineer/lib/module_placer.lua`
- `mod/factorio_autonomous_engineer/control.lua`
- `src/factorio_autonomous_engineer/server.py`

Tests and tooling:

- `tests/engine/stage7_fixture.py` (new)
- `tests/engine/s13_splitter_networks.py` (new)
- `tests/engine/s14_underground_belts.py` (new)
- `tests/engine/s15_multi_consumer_expansion.py` (new)
- `tests/engine/s16_factory_persistence.py` (new)
- `tests/engine/harness.py`, `stage6_fixture.py`, `README.md`, `s9_belt_routing.py`
- `tests/engine/README.md`

Documentation and skills:

- `docs/advanced-logistics.md` (new), `docs/logistics.md`, `docs/architecture.md`,
  `docs/tasks.md`, `docs/roadmap.md`, `docs/engine-test-plan.md`, `docs/module-library.md`,
  `README.md`
- `skills/core_strategy.md`, `skills/stages/automation.md`,
  `skills/stages/automation_bootstrap.md`

## Defects found and corrected

1. **Verification poisoning route state.** An external read-only `logistics_verify` while
   construction was still in progress marked a route `blocked`; later checks returned
   `route_blocked` without re-reading the engine. `expansion_route_connected` now evaluates
   real entities every time. This was the root cause of false blocked results during
   monitoring and repeated execution.
2. **Underground endpoint direction on paid revival.** Factorio 2.1.24 initially revives an
   underground ghost as an input endpoint. The exit ghost uses the opposite build hint and
   the paid executor reasserts the planned travel direction on both real endpoints. The
   engine then reports reciprocal `underground_belt_neighbour` values and input/output roles.
3. **Vertical approach side-loading a splitter input.** The first gear-merge layout arrived
   at the splitter input from the north, leaving the last belt pointing away from the
   splitter. The cell was shifted and the branch now reaches the input horizontally.
4. **Stale persisted module instances.** A missing persisted instance could make
   `module_placer.instantiate` deduplicate to a dead record and create no ghost. A stale
   instance is now forgotten and rebuilt; live instances remain deduplicated.
5. **Site search limited to the nearest 24 ore tiles.** A working Stage-6 factory occupying
   that patch caused `blocked_layout`. The multi-consumer site search samples the whole
   bounded patch and rejects occupied cell rectangles before module evaluation.
6. **Stage-7 scenario baseline pollution.** The shared Stage-6 baseline contained persisted
   module/plan records from earlier test runs. Stage-7 scenarios now use a clean
   `s7-baseline.zip` created from the same executable and mod set.
7. **Premature route blocking during a transient first verification.** A 3-attempt,
   10-second grace period was added before a disconnected route is reported blocked. It
   does not hide a real player change: repeated verification still reports blocked.

## Impact analysis

| Changed area | Affected contracts | Scenarios selected |
| --- | --- | --- |
| `transport.lua` splitter/underground geometry and verification | new Stage-7 routes and engine connectivity | `s13`, `s14`, `s16` |
| route graph status, expansion planning and verification | `build_logistics` multi-consumer task, repeat/idempotency | `s13`, `s15`, `s16`, `s9` |
| layout planner multi-consumer mode and site search | plan persistence, fingerprints, apply | `s15`, `s16`, `s8` |
| module placer stale-instance recovery | module instantiation identity/dedup | `s7`, `s8`, Stage-7 suite |
| construction underground post-build direction | paid ghost revival, no transport mutation | `s14`, `s16`, `s5`, `s6` |
| task phases/result contract | save/load, cancellation, safety, death | `s12`, `s16` |
| MCP `execute_task(mode=...)` | model-facing schema/skills | fast checks, `s15` |

Directly affected Stage 3–6 regressions selected: `s5`, `s6`, `s7`, `s8`, `s9`, `s10`,
`s12`.

Skipped and reasons:

- `s1`, `s2`, `s3`, `s3b` — gather/lifecycle/safety-controller internals were not changed.
  Stage-7 safety/death checkpoint behavior is covered by `s16 F/G`.
- `s4`, `s4b` — RCON/MCP transport and restart code were not changed.
- Broader historical scenarios — the impact matrix identifies every changed interface;
  running the rest would not exercise a changed contract.

No skipped scenario is labelled PASS.

## Fast checks

| Command | Result |
| --- | --- |
| `uv run ruff check .` | PASS |
| `uv run pytest -q tests` | **67 passed** in 1.12 s |

## Stage-7 engine results (final code commit)

All runs used the isolated Stage-7 profile and exited 0.

| Scenario | Checks | Result | Duration | Speed |
| --- | --- | --- | --- | --- |
| `s13_splitter_networks.py` | 24/24 | PASS | 46 s | 60 |
| `s14_underground_belts.py` | 15/15 | PASS | 22 s | 60 |
| `s15_multi_consumer_expansion.py` | 17/17 | PASS | 21 s | 60 |
| `s16_factory_persistence.py` | 31/31 | PASS | 206 s | 60, with 1–5 windows |

### Actual observed behavior

`s13` and `s15` observed a real cell built through the paid executor:

- the mining drill produced iron ore;
- a splitter distributed real ore to both stone furnaces;
- an ordinary coal chest fed a splitter and real belts to both furnace fuel inserters;
- both furnaces increased real `products_finished` and produced plates;
- both furnace plate outputs merged through a splitter into one trunk;
- the trunk split to both assembling machines;
- both assemblers received plates and produced iron gear wheels;
- both gear outputs merged through a splitter into the common output chest;
- the output chest gained real gear wheels.

Additional evidence:

- five real splitters had the expected east orientation and 1/2 or 2/1 native connector
  counts; unused connectors stayed empty;
- one underground pair reported input/output roles, reciprocal neighbours, distance 2 and
  direction south; coal physically crossed it to the second furnace;
- a full output chest produced back-pressure and never a success result;
- an empty coal chest reported `missing_fuel_source:fuel_depleted` and no gear production;
- a player building on a branch blocked the plan and was preserved;
- a player-owned underground exit belt blocked planning and was preserved;
- a Stage-6 factory built first remained unit-for-unit present; its output chest continued
  producing, and the Stage-7 cell ran beside it;
- save/load during splitter/underground construction and production monitoring preserved
  task identity and exact entity counts;
- repeated execution produced no duplicate belts, splitters or underground pairs;
- cancellation followed by a restart built exactly the planned entity set;
- a player-removed belt was reported blocked and was not rebuilt as a ghost or real belt;
- safety pre-emption and death both paused the task until explicit resume, then completed
  without duplicate infrastructure.

## Selected Stage 3–6 regressions

| Scenario | Checks | Result | Speed |
| --- | --- | --- | --- |
| `s5_construction.py` | 50/50 | PASS | 1 |
| `s6_construction_persistence.py` | 44/44 | PASS | 1 |
| `s7_module_catalog.py` | 84/84 | PASS | 60 |
| `s8_layout_planner.py` | 64/64 | PASS | 60 |
| `s9_belt_routing.py` | 21/21 | PASS | 60 |
| `s10_inserters.py` | 17/17 | PASS | 60 |
| `s12_gear_production.py` | 43/43 | PASS | 60, with 1–5 windows |

The s5/s6 runs were initially attempted at speed 60 and timed out in their movement/clearing
waits; those scenarios are documented at speed 1 and passed at speed 1.

## Archive verification

- Tested mod-tree commit: `14e7434` (`test: add advanced logistics engine scenarios`)
- Final HEAD: recorded after the documentation commit
- Archive: `dist/factorio_autonomous_engineer_0.1.0.zip`
- Archive SHA-256: `a03b8e7a7d0792b95b51a89d7b44abb8da409e871d26320d8a5459f401f79c3e`
- Entries: 22; Git mod blobs: 22; mismatches: **none**
- Comparison: every archive entry was read byte-for-byte and compared with
  `git show 14e7434:mod/factorio_autonomous_engineer/<entry>`.

## Human multiplayer acceptance

Pending the mandatory checkpoint. This section will record the isolated Stage-7 server,
real player join, preserved Stage-6 baseline, applied expansion, actual item movement and
the observed player interaction. Synthetic characters were not used.

## Known limitations

- Splitter filters, priorities and circuit-controlled splitters are out of scope.
- No throughput optimization or equal-balancing guarantee; physical back-pressure is
  reported honestly.
- Fluids, pipes, pumps, steam power, rail, circuits, loaders, logistic-network delivery and
  construction robots are out of scope.
- Autonomous coal mining and power generation remain external prerequisites.
- The Stage-7 layout uses the existing Nauvis starter module set; new module definitions
  were not added.
- A player-cancelled ghost or player-removed real route is reported blocked, not rebuilt.
