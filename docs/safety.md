# Autonomous safety controller

## Triggers

- on_entity_damaged for the agent character.
- Nearby enemy unit/spawner/turret detection every 15 game ticks while idle and every 10 ticks during an emergency.
- A death event immediately transitions the safety controller into respawning.

## Emergency state machine

normal -> alert -> evacuating/defending -> safe -> resume-or-await-LLM.

The controller is independent of the MCP process and the LLM. It immediately suspends the current task, clears ordinary movement/mining states, chooses a configured home position or a dynamically selected escape position, and moves using the native pathfinder. If guns and ammunition are present and health is above the critical threshold, it requests automatic enemy fire while retreating. If no safe route is found, it remains in a blocked emergency state and retries; it never returns to ordinary work merely because pathfinding failed.

## Event delivery

The mod stores compact events such as agent_under_attack, emergency_resolved, agent_died and agent_respawned in a bounded queue. get_pending_events supports a cursor. A foreground execute_task call returns interrupted_by_safety or interrupted_by_death when it detects an emergency. When idle, the host must call get_pending_events or support a future MCP notification extension; MCP servers cannot force every LLM host to start a new model turn spontaneously.

## Never trust the model for survival

No LLM decision is required for evasive movement, defensive fire, cancelling work, respawn, or inventory recovery. Thresholds are constants in lib/safety.lua and require engine testing.
