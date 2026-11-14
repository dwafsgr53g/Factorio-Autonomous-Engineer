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
