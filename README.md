# Factorio Autonomous Engineer

A semi-autonomous Factorio 2.1 engineer. The LLM is the strategic planner; the Factorio mod and MCP executor own gameplay mechanics.

## Product boundary

The LLM chooses goals and priorities. It does not calculate coordinates, pathfinding, movement, inventory slots, mining loops, crafting queues, item transfers, or defensive movement. The model receives a code-generated briefing (active planet, game stage, evidence, available capabilities) plus matching plain-Markdown skills. Only high-level objectives are exposed through MCP.

## Current prototype

- Strategic briefing with planet/domain and technology-based stage detection.
- Stage and planet skill loading.
- Nauvis-only starting-site selection using resource access, water, building clearance, nearby hostiles, and generated-chunk coverage.
- High-level resource gathering with internal pathfinding, movement, mining, retries, and inventory-delta verification.
- Independent safety controller and delayed death/respawn lifecycle with inventory recovery.

The project is an early development scaffold. The Factorio Lua implementation has not yet been validated in a real 2.1.24 engine run. See docs/engine-test-plan.md.

## Setup

1. Use a disposable copy of a Factorio 2.1 save.
2. Build the companion mod with: `python scripts/package_mod.py`.
3. Install the generated ZIP from dist/ and enable Factorio Autonomous Engineer. Disable the original factorio_llm_use mod in this test setup.
4. Run a dedicated/hosted Factorio server with RCON bound to loopback only.
5. Configure the MCP server from mcp.json.example and install Python dependencies with uv.
6. Start with get_briefing. During early Nauvis bootstrap, call select_starting_site, then execute a small gather_resource objective.

## Development rules

- The LLM is a planner, not a player motor controller.
- The executor owns all Factorio mechanics and raw game state.
- Capability lists and mod-side validation must agree; unsupported work fails closed.
- Safety pre-emption and respawn must not depend on LLM availability.
- Do not claim gameplay verification without an actual Factorio engine test.

See AGENTS.md for coding-agent guidance, docs/strategy-layer.md for the planner contract, and NOTICE.md/LICENSE for upstream attribution and licensing.
