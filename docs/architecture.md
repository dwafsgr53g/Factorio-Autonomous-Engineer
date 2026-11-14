# Architecture

## Strategic control plane

The LLM is a planner. get_briefing obtains a code-generated profile containing the current planet/domain, progression stage and evidence, base maturity, agent lifecycle and allowed capabilities. Python loads matching plain-Markdown stage and planet skills. The model gets the skill text and strategic summary, not server source or raw game state.

The current capability set includes a Nauvis bootstrap-site selector and a high-level resource gathering goal. Each mutating operation is checked again inside the Factorio mod; stale or unsupported capability requests fail closed.

The LLM does not choose coordinates, routes, approach positions, inventory slots or mining steps. The site selector evaluates resource patches, water, collisions, hostile entities and generated-chunk coverage. The gather executor owns resource search, pathfinding, movement, mining, retries and actual inventory-delta verification.

## Control-plane separation

The LLM selects milestones and high-level goals. The MCP server exposes a small, abstract tool surface. The Factorio mod owns the task state machine and game mechanics. Lua runs the task, safety, site-selection and lifecycle controllers on game ticks. The model must not orchestrate waypoints, action-status polls, mining ticks, crafting queues or inventory transfers.

## Task execution contract

execute_task is one MCP call. Python sends task_start, then polls task_status privately until a terminal result or a safety interruption. Those internal RCON calls are not returned as separate tool messages. A task has a stable ID and a save-persistent state in the Factorio mod. If the MCP process disconnects, the task continues in Factorio; a later client can inspect the status by task ID.

Terminal states: succeeded, failed, cancelled, interrupted_by_safety, interrupted_by_death. Nonterminal states: queued, searching, pathing, moving, mining, paused, evacuating, respawning.

## Safety priority

Safety controller is ticked before ordinary task execution. It can suspend an active task, stop walking/mining, override movement and start defensive fire if an equipped weapon and ammunition are available. The controller itself is not an MCP call and does not wait for the LLM.

## Persistence

Only serializable task data, IDs, counters, positions, and valid Factorio LuaObjects belong in storage. Python process memory is not authoritative. The Factorio save is the source of truth for agent identity, active task, event queue, recovery inventory and respawn state.

## RCON boundary

RCON is restricted to loopback addresses. Each request has an ID and the Factorio mod caches responses so a retry with the same request ID does not repeat a completed command. No password is stored in the repository or exposed in MCP schemas.

## Why not a real LuaPlayer?

The runtime API's LuaPlayer represents a game player and supports player controller, GUI and respawn members. The current mod creates a standalone character entity. Factorio 2.1.24 does not document a game.create_player runtime method, so a mod cannot simply manufacture a fully fledged synthetic player. This project keeps the separate character and explicitly emulates only the lifecycle and gameplay capabilities it needs.
