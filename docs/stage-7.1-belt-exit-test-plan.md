# Stage 7.1 — Belt exit pathfinder test plan

Status: **implementation candidate; live Factorio verification required**  
Target build: Factorio 2.1.24  
Base commit: `0a9e9629f6c408a40e5bd826b69eefce59f0f7d0`

## Goal and invariants

Verify that the autonomous character deliberately exits a conveyor using
`LuaSurface.request_path()` and the Movement Controller's existing waypoint follower.

- A belt-exit incident selects a bounded list of off-belt candidate positions once.
- A selected candidate remains fixed while its asynchronous path request is pending and
  while its route is being followed.
- The engine pathfinder decides reachability and supplies waypoints. Normal belt exits
  must not use a repeated fixed `walking_state.direction` as their route.
- If the conveyor displaces the character while a request is pending, discard the stale
  route and request a fresh route from the actual position to the same candidate.
- Only an engine-reported empty/failed path advances to another candidate.
- Recovery ends only when the character is placeable and outside the expanded belt
  clearance region.
- If the requested stand position is itself on or too close to a belt, do not restore
  that invalid destination after exiting.
- Ordinary travel, stand-at-work-position movement, ghost step-out and Safety evacuation
  remain distinct behaviours. No task deadline changes and no teleports.

## 0. Preserve and identify the environment

1. Fetch the exact branch head and confirm it is based on `0a9e9629f6c408a40e5bd826b69eefce59f0f7d0`.
2. Keep `main`, normal saves and normal profiles untouched.
3. Use the established disposable test profile, temporary RCON/game ports and existing
   harness saves. Do not start the human production server for this matrix.
4. Record tested commit, Factorio version, mod version, profile, ports, speed and save
   names in the report.
5. Use `game.speed = 5` for movement traces and save/load timing. Use `game.speed = 60`
   only for ordinary deterministic checks. Never accelerate timing-sensitive callbacks
   or save/load capture.

## 1. Static and unit checks

Run:

- `ruff check .`
- `pytest -q`
- `pytest -q tests/test_movement_contract.py`

Required evidence:

- Exactly one production `walking_state` writer remains: `lib/movement.lua`.
- No production `LuaEntity.teleport()` call exists.
- Candidate discovery has no fallback to the current belt position.
- Every belt-exit candidate is tested by `request_path()`.
- Candidate identity does not change while its path request or valid route is active.
- Stale async starts, empty paths, pathfinder-busy responses and path timeouts have
  bounded, distinct handling.
- An arrived intent is not reused for a new request; intent reuse includes `stand`.
- Construction/logistics deadline assertions remain unchanged.

Static tests do not prove live movement behaviour.

## 2. Focused live-engine tests

Run relevant scenarios in `tests/engine/s18_movement_recovery.py` individually first,
then as a suite. Capture a position trace every 1–2 ticks around each recovery.

### A. Belt field with a free side

Create a real 21-tile or wider conveyor field, place the agent on it and request a
stand position on the belt.

Pass conditions:

- `belt_exit_path_requests >= 1`.
- The intent exposes `recovery_kind = "belt"` and a non-empty candidate list.
- The agent follows engine-returned waypoints toward the fixed candidate.
- Candidate index does not oscillate while that path remains valid.
- The agent physically reaches a position outside all belts plus configured clearance.
- No teleport, belt deletion, entity movement or direct position assignment occurs.
- The intent reports `arrived` only after the off-belt condition is true.

### B. One side blocked, other side available

Place real walls/colliders over the closest candidate on one side. Keep the opposite side
open.

Pass conditions:

- The pathfinder returns an empty path for the blocked candidate.
- The controller advances to another precomputed candidate.
- The next reachable candidate is pathfound and reached.
- The controller does not change candidate while a valid route is being followed.

### C. No reachable off-belt exit

Surround candidate locations with real colliders, or create a belt field wider than the
bounded discovery radius.

Pass conditions:

- Candidates are rejected by the engine pathfinder, or no safe candidate is found.
- The intent ends in explicit `blocked` with a meaningful reason such as
  `belt_exit_unreachable` or `no_belt_free_exit`.
- It never reports `arrived` while still on the belt.
- Retries and path requests remain bounded.

### D. Conveyor moves the character during an asynchronous request

Capture request start position, callback position and selected candidate. Arrange enough
belt length to move the character more than the stale-start threshold before callback
consumption.

Pass conditions:

- The old route is discarded after the actual start moves beyond the threshold.
- The candidate remains unchanged.
- A new path request starts from the actual character position.
- The agent continues toward the same exit without side-switching jitter.

### E. Save/load during belt exit

Use the existing s18 save-capture hook.

Pass conditions:

- The save retains the original stand destination and active recovery kind.
- Old path handles and waypoint arrays are not trusted after load.
- Exit candidates are regenerated from the post-load character position.
- Recovery resumes through a fresh engine path request.
- The agent reaches an off-belt position or reports a bounded failure.
- No teleportation occurs.

### F. Safety pre-empts belt exit

Start a belt-exit incident, then trigger the existing hostile/emergency scenario.

Pass conditions:

- Safety creates a higher-priority emergency intent.
- The ordinary belt-exit intent becomes interrupted and stops issuing movement.
- Safety follows its own path and resolves the emergency.
- No stale belt-exit callback overrides the emergency intent.
- An incomplete evacuation is never reported as resolved.

## 3. Non-regression tests

Run:

- `s17_movement_pathfinding.py`: requests, waypoint following, callback correlation,
  unreachable targets, cancellation.
- `s18_movement_recovery.py`: belt exit, aligned belt, travel across belt, ghost recovery,
  save/load, Safety pre-emption and bounded stuck route.
- Relevant `s12` recovery/death-resume cases, especially inside-ghost after respawn.
- `s15`, `s16`, `s19`, `s20`, `s21`: construction scheduler, logistics movement,
  multi-consumer expansion and movement lifecycle.

Do not rerun untouched bridge/RCON/catalog suites unless the diff reaches those systems.
Skipped tests must be listed as **SKIPPED**, never **PASS**.

## 4. Quantitative evidence

For each incident, record:

- request ID, recovery kind, initial position and original stand target;
- candidate count, selected index and coordinates;
- each path request ID, request start, candidate goal and callback outcome;
- waypoint-index transitions;
- position trace and minimum distance to belt geometry;
- ticks from recovery start to actual exit;
- candidate advances and stale-start replans;
- final state/reason;
- total path requests, retries and teleports (must be zero).

A successful task alone is insufficient. The trace must show purposeful movement to a
stable off-belt target without side-switching jitter.

## 5. Acceptance gates

The fix is not release-ready until:

1. All static and unit tests pass.
2. Focused live-engine tests A–F pass.
3. Relevant regressions pass, with skips explicitly listed.
4. Repeated runs of the previously flaky Safety evacuation scenario pass without raising
   test timeouts or task deadlines.
5. The executor packages the exact tested mod tree, compares every archive entry
   byte-for-byte against Git blobs and reports archive SHA-256, tested commit and final HEAD.
6. Human multiplayer acceptance is completed later on a separate disposable server with
   the user's real client. A synthetic player is not acceptance evidence.

On any failure, stop and report the trace and first failing invariant. Do not apply a
second speculative patch before diagnosing it.
