# Agent lifecycle and respawn

The agent remains a standalone Factorio character entity, not a LuaPlayer. The mod therefore owns a small lifecycle state machine:

alive -> dead -> waiting_for_safe_spawn -> respawning -> alive.

On on_entity_died, the mod matches the dead entity by its stored unit number, records the death location/cause, transfers available death-loot stacks into save-persistent recovery inventories, pauses the current task and schedules a respawn cooldown. Recovery bags separate main inventory, guns, ammunition and armor. After the cooldown the mod requires a collision-free spawn near the configured home point with no nearby enemy entities, creates a replacement character, restores the bags into matching character inventories and emits an agent_respawned event.

If the home area is under threat or has no free spawn location, respawn is deferred and retried; the agent is not intentionally recreated inside an enemy group. The task stays checkpointed. After the safety controller reports that the area is safe, the LLM can inspect the task and explicitly resume it.

## Current limitations

- This recreates a standalone character, not a true connected player. It has no real player identity, GUI, quickbar/controller state or universal player-only mechanics.
- Recovery captures available death loot and falls back to character inventories when no loot was transferred. Unusual modded inventory types and mod-specific character attachments are not guaranteed to survive.
- Armor stacks are routed back to the character armor inventory; equipment-grid fidelity still needs engine testing with the exact Factorio 2.1 build and enabled mods.
- The configured home point must be viable. If it remains under enemy threat, respawn waits rather than forcing a dangerous spawn.
- Respawn and recovery behaviour must be tested on an isolated 2.1.24 save before use.
