# Task executor

## Example high-level request

task=gather_resource, resource=iron-ore, amount=100

The executor owns the complete sequence:

1. Validate the request and the agent state.
2. Find a suitable resource entity using the game's entity index/search.
3. Find a collision-free approach position and request a native Factorio path.
4. Follow the path using the character's normal movement state.
5. Mine using the normal mining state and measure the inventory delta.
6. If the deposit is exhausted, unreachable or invalid, find another candidate.
7. Stop only when the requested amount is collected or a bounded failure condition occurs.
8. Return one compact result with requested/collected counts, deposits used and reason.

All waypoint advancement, path completion, action polling, retries and phase changes remain inside Lua/Python. The LLM sees the final result only.

## Required safeguards

- Overall deadline and per-phase deadline.
- Stall detection based on inventory/position progress, not a tight fixed loop.
- Explicit cancellation by task ID.
- Idempotent task_start request ID handling.
- A single active foreground task per agent.
- Safety pre-emption and resumable task checkpoint.
- No false success: verify actual inventory delta.


## Construction assistance

Example high-level request: `task=assist_construction`

The executor owns the complete construction cycle:

1. Validate the agent and the absence of a safety emergency.
2. Scan only the code-configured work area around home (or the character when no home exists) for `entity-ghost` objects.
3. Reconcile the per-ghost ledger: new ghosts, ground-truth player completions, player cancellations and modified plans.
4. Select the nearest feasible target. A player character working near a target defers that target.
5. If the target position is blocked by a tree or rock, walk to it and clear it with `mine_entity`; refuse cliffs, chests and real player entities without destroying them.
6. Compute the exact item/quality requirement from `item_requests` or, for script-created ghosts, the entity prototype's `items_to_place_this`.
7. If materials are missing, find an ordinary accessible chest inside the work area whose contents include them, walk to it, and transfer only the still-missing items. No chest marker or reservation exists.
8. Verify capacity and actual counts. Return any uninserted remainder to the chest immediately.
9. Walk to the ghost's ring approach position and place only after the ghost still exists, the position is valid, the player is not working there and the full cost is present.
10. Consume exactly the required stacks, call `revive()` in the same tick, verify the real entity, and record the ghost as built. A failed revive refunds the exact stacks.
11. Reconcile again after every build/clear/transfer. A cancelled ghost is never recreated by the same task. A short settle re-scan precedes successful completion.
12. Return one compact result. No waypoints, inventory indices, entity handles or coordinates are exposed to the model.

## Construction terminal results

- `succeeded`: all observed pending work is completed or already built/cancelled by players; `built_by_agent` is verified.
- `partial`: some objects were built but some work remains (missing materials, blocked site, player activity, inventory full).
- `missing_materials`: nothing could be built because the required placeable items are absent from the agent and accessible chests.
- `blocked`: construction is impossible for the observed state (unsupported ghost/item request, obstructing real entity, unreachable site or full inventory).
- `cancelled`: explicit cancel request. No new work starts after the terminal result.
- `interrupted_by_safety`, `interrupted_by_death`: the runner reports the independent emergency; the task remains paused and requires an explicit strategic resume.

## Construction safeguards

- Work-area and player-interference radii are lib constants, not LLM parameters.
- Cost is always paid from real inventory before `revive()`; no free revival path exists.
- Payment and revival are atomic within one tick.
- A failed build refunds exact stacks; a successful build is never refunded.
- Materials are transferred only from physically reached ordinary chests and only in needed quantities.
- Clearing is limited to natural trees/rocks through normal character mining; player entities, chests and resources are excluded.
- Safety pre-emption has unconditional priority. Completed ledger entries survive; in-flight targets are reset only on explicit resume.
- Save/load preserves the ledger, counters, chest transfers and in-flight target. A lost path request is retried a bounded number of times.
- The MCP surface remains one high-level `assist_construction` objective, not a per-building control API.
