# Agent development instructions

This repository builds a semi-autonomous Factorio engineer.

- The LLM is a strategic planner only. Expose high-level goals, never movement/mining/inventory micro-actions, raw RCON, arbitrary Lua, or server source through MCP.
- Game mechanics, map analysis, pathfinding, inventory, crafting, construction, combat and lifecycle behaviour belong in the executor/mod.
- Update stage/planet skills and capability gating together when adding a capability. A skill must not advertise work the live MCP interface and mod can perform.
- Do not leak coordinates, entity handles, path nodes, inventory indexes or server implementation into the model-facing briefing unless the design explicitly requires it.
- Safety pre-emption must remain independent of the LLM and take priority over normal tasks.
- Death/respawn and task checkpoint state must survive save/load. The agent is a standalone character entity with an explicitly emulated lifecycle, not a true LuaPlayer.
- New planet logic must be planet-specific. Never reuse the Nauvis site-selection heuristic on Vulcanus, Fulgora, Gleba, Aquilo or a space platform without dedicated validation.
- Never report Lua/Factorio behaviour as tested unless an actual Factorio 2.1 engine run is recorded.

## Verification

Run the Python unit suite and package the mod. Then use a disposable copy of a Factorio 2.1.24 save for runtime validation. Never test on the only copy of a save. Record engine version, active mods, test scenario and results in docs/engine-test-plan.md or a separate verification report.
