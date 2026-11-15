# Factorio Autonomous Engineer

A semi-autonomous Factorio 2.1 engineer. The LLM is the strategic planner; the Factorio mod and MCP executor own gameplay mechanics.

## Product boundary

The LLM decides goals, milestones and priorities. It does **not** calculate coordinates, pathfinding, movement, inventory slots, mining loops, crafting queues, item transfers, building geometry or defensive movement. The model receives a code-generated briefing (active planet/domain, game stage and evidence, available high-level capabilities) plus matching plain-Markdown skills. The server implementation and low-level gameplay interface are not exposed as MCP tools.

The intended split is:

- **LLM:** decide what should happen next and evaluate compact outcomes.
- **Python MCP layer:** provide a small high-level interface, load stage/planet skills, hide private polling and return terminal task results.
- **Factorio Lua mod:** own all game mechanics, map analysis, pathfinding, action state machines, survival and character lifecycle.

## Current prototype (0.1.0-dev)

- Strategic briefing with planet/domain detection and technology-based stage classification.
- Stage and planet skill loading from plain Markdown.
- Nauvis-only bootstrap-site scoring using iron/copper/coal/stone access, water, a free furnace-sized footprint, nearby known hostiles and generated-chunk coverage. The selected location becomes the home/respawn point.
- High-level resource gathering. The executor searches for a deposit, chooses an approach point, pathfinds, moves, mines, retries and verifies the actual inventory delta.
- High-level construction assistance. The executor discovers ghosts in a code-owned work area, walks, clears natural obstacles, fetches only needed items from ordinary chests, pays the exact build cost, revives the ghost, verifies the real entity and reconciles player builds/cancellations/changes.
- Independent safety controller: damage/hostile detection, task pre-emption, evacuation, and conditional return fire.
- Persistent character lifecycle: death detection, recovery inventories, delayed safe respawn and event reporting.
- The planner sees only high-level outcomes and compact status/events. No coordinates are returned by the model-facing tools.

**Important scope boundary:** selecting a starting site and assisting with bounded construction ghosts are implemented; a complete starter base, Layout Planner, arbitrary belt networks, construction robots and logistics-network construction are not. The selector chooses and registers a home location. The construction executor supports base-placeable items by name and quality but refuses modules, equipment and other extra item requests in this stage. Other stage/planet skill files are planning guidance, not claims that every stage's tools are implemented.

The construction cycle has been validated in a real Factorio 2.1.24 engine run. See [the construction verification report](docs/verification-construction.md) and [the engine test plan](docs/engine-test-plan.md).

## MCP tools currently exposed

- `get_briefing`: detect planet/stage, return capability allow-list and matching skill text.
- `select_starting_site`: code-side Nauvis bootstrap site selection; the model supplies no coordinates.
- `execute_task(task="gather_resource", resource=..., amount=...)`: one high-level gathering goal; internal action polling is hidden.
- `execute_task(task="assist_construction")`: one high-level construction-assistance goal. The model supplies no coordinates or per-building actions; the result distinguishes success, partial completion, missing materials, blocked work, cancellation and safety interruption.
- `get_agent_status`: compact lifecycle, safety, task and inventory summary.
- `get_pending_events`: compact event queue with cursor.
- `cancel_task` / `resume_task`: task lifecycle controls.

## Setup (Windows)

1. Use a **disposable copy** of a Factorio 2.1 save. Never test on the only copy of a valuable world.
2. Install Python 3.12+ and `uv`.
3. Build the companion mod:

   ```powershell
   uv sync
   uv run python scripts/package_mod.py
   ```

4. Install `dist/factorio_autonomous_engineer_0.1.0.zip` into Factorio's mods directory and enable **Factorio Autonomous Engineer**. Disable the original `factorio_llm_use` mod in this test mod set so two engineers are not spawned.
5. Run the dedicated Factorio server with RCON bound to loopback only (`127.0.0.1`). Do not expose RCON to a LAN or the internet.
6. Copy `mcp.json.example`, set the local project directory and RCON password-file path, then register the MCP server with your host.
7. Connect and call `get_briefing`. On early Nauvis, call `select_starting_site`, then test a small objective with `execute_task(task="gather_resource", resource="iron-ore", amount=20)`.

## Development and verification

```powershell
uv sync
uv run ruff check .
uv run pytest -q tests
uv run python scripts/package_mod.py
```

Python unit tests cover the private task polling contract and skill loading. They are not a substitute for loading the mod in Factorio. Automated engine scenarios (save/load, safety pre-emption, death recovery, RCON faults, construction and collaboration) live in [tests/engine](tests/engine/README.md) and drive a disposable headless server. Follow [the engine test plan](docs/engine-test-plan.md) on a disposable save before real gameplay use.

## Architecture and contribution rules

- [Strategic layer and skill activation](docs/strategy-layer.md)
- [Architecture](docs/architecture.md)
- [Roadmap](docs/roadmap.md)
- [Safety controller](docs/safety.md)
- [Death and respawn lifecycle](docs/lifecycle.md)
- [Development instructions for coding agents](AGENTS.md)

Capability lists and mod-side validation must agree. Unsupported actions fail closed. Safety must never depend on LLM availability. Never describe a Lua/gameplay behaviour as tested unless an actual Factorio engine run is recorded.

See [NOTICE.md](NOTICE.md) and [LICENSE](LICENSE) for upstream attribution and licensing.
