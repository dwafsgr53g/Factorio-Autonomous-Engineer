"""MCP entry point: expose strategic goals, not game micro-actions."""
from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Literal

from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError

from .bridge import Bridge, BridgeError
from .runner import TaskRunner
from .skills import load_skill_pack


def create_server(bridge: Bridge) -> MCPServer:
    server = MCPServer("Factorio Autonomous Engineer")
    poll_interval = float(os.environ.get("FACTORIO_TASK_POLL_INTERVAL", "2.0"))
    runner = TaskRunner(bridge, poll_interval=poll_interval)

    @server.tool()
    async def get_briefing() -> str:
        """Detect planet and game stage, then return matching strategy skills and allowed goals."""
        try:
            response = await asyncio.to_thread(bridge.call, "strategy_context")
        except (BridgeError, OSError) as exc:
            raise ToolError(str(exc)) from exc
        profile = response.get("result", response)
        return json.dumps({"profile": profile, "loaded_skills": load_skill_pack(profile)},
                          ensure_ascii=False)

    @server.tool()
    async def select_starting_site() -> str:
        """Select and register a suitable Nauvis bootstrap site.

        The model supplies no coordinates; the site is scored and chosen in code.
        """
        try:
            response = await asyncio.to_thread(bridge.call, "select_starting_site")
        except (BridgeError, OSError) as exc:
            raise ToolError(str(exc)) from exc
        return json.dumps(response.get("result", response), ensure_ascii=False)

    @server.tool()
    async def execute_task(task: Literal["gather_resource", "assist_construction",
                                          "build_logistics"],
                           resource: str | None = None, amount: int | None = None,
                           goal_item: str | None = None,
                           mode: Literal["linear_chain", "multi_consumer"] | None = None) -> str:
        """Execute one high-level objective.

        gather_resource needs resource and amount. assist_construction discovers pending
        construction ghosts in the executor-owned work area. build_logistics plans a
        deterministic linear production chain, builds real belts, inserters, a fuel feed
        from an ordinary coal chest and electric poles connected to an existing powered
        network, then verifies actual item movement and production. Route, approach,
        movement, mining, item transfer, clearing, building and verification all happen
        inside the executor.
        """
        if task == "gather_resource":
            if resource is None or amount is None:
                raise ToolError("gather_resource requires resource and amount")
            if amount <= 0:
                raise ToolError("amount must be a positive integer")
            spec = {"task": task, "resource": resource, "amount": amount}
        elif task == "build_logistics":
            spec = {"task": task, "goal_item": goal_item or "iron-gear-wheel",
                    "mode": mode or "linear_chain"}
        else:
            spec = {"task": task}
        try:
            result = await runner.execute(spec)
        except (BridgeError, OSError, ValueError) as exc:
            raise ToolError(str(exc)) from exc
        return json.dumps(result, ensure_ascii=False)

    @server.tool()
    async def plan_layout(goal_item: str) -> str:
        """Plan a minimal deterministic module layout for a production goal.

        The model supplies only an item goal. Dependency resolution, candidate sites,
        collisions, orientations and the plan fingerprint are computed inside the mod.
        Creating a plan never creates entities and never spends items.
        """
        try:
            response = await asyncio.to_thread(bridge.call, "plan_layout",
                                               {"goal_item": goal_item})
        except (BridgeError, OSError) as exc:
            raise ToolError(str(exc)) from exc
        return json.dumps(response.get("result", response), ensure_ascii=False)

    @server.tool()
    async def apply_layout(plan_id: str) -> str:
        """Revalidate a persisted plan and create only validated module ghosts.

        Paid construction, material transfer and clearing remain the existing
        assist_construction objective. A stale or conflicting plan is refused safely.
        """
        try:
            response = await asyncio.to_thread(bridge.call, "apply_layout",
                                               {"plan_id": plan_id})
        except (BridgeError, OSError) as exc:
            raise ToolError(str(exc)) from exc
        return json.dumps(response.get("result", response), ensure_ascii=False)

    @server.tool()
    async def get_agent_status() -> str:
        """Return compact health, lifecycle, safety, task and inventory summary."""
        try:
            response = await asyncio.to_thread(bridge.call, "agent_status")
        except (BridgeError, OSError) as exc:
            raise ToolError(str(exc)) from exc
        payload = response.get("result", response)
        lifecycle = payload.get("lifecycle", {})
        safety = payload.get("safety", {})
        task = payload.get("task", {})
        compact = {
            "lifecycle": {k: lifecycle.get(k) for k in ("status", "health", "death_count",
                "respawn_at_tick", "spawn_block_reason", "recovery_item_count") if k in lifecycle},
            "safety": {k: safety.get(k)
                       for k in ("active", "status", "reason", "destination_kind") if k in safety},
            "task": {k: task.get(k) for k in ("task_id", "type", "status", "phase", "resource",
                "requested", "collected", "deposits_used", "reason", "work_area_available",
                "ghosts_total", "built_by_agent", "already_built", "remaining", "cancelled",
                "unsupported", "blocked", "unreachable", "missing_materials",
                "missing_material_total", "obstacles", "player_interference",
                "inventory_full", "items_transferred") if k in task},
            "inventory": payload.get("inventory", {}),
        }
        return json.dumps(compact, ensure_ascii=False)

    @server.tool()
    async def get_pending_events(limit: int = 20, after_id: int = 0) -> str:
        """Fetch compact safety/death events after a cursor.

        Coordinates and implementation data are omitted from the payload.
        """
        try:
            response = await asyncio.to_thread(
                bridge.call, "agent_events",
                {"limit": max(1, min(limit, 100)), "after_id": max(0, after_id)},
            )
        except (BridgeError, OSError) as exc:
            raise ToolError(str(exc)) from exc
        payload = response.get("result", response)
        events = []
        for event in payload.get("events", []):
            data = event.get("data") or {}
            events.append({"id": event.get("id"), "type": event.get("type"),
                           "tick": event.get("tick"),
                           "data": {k: v for k, v in data.items()
                                    if k not in {"position", "surface_index",
                                                 "coordinates", "path"}}})
        return json.dumps({"events": events, "latest_id": payload.get("latest_id", after_id),
                           "has_more": payload.get("has_more", False)}, ensure_ascii=False)

    @server.tool()
    async def cancel_task(task_id: str, reason: str = "cancelled_by_llm") -> str:
        """Cancel the current or paused task by ID."""
        try:
            response = await asyncio.to_thread(bridge.call, "task_cancel",
                                               {"task_id": task_id, "reason": reason})
        except (BridgeError, OSError) as exc:
            raise ToolError(str(exc)) from exc
        return json.dumps(response.get("result", response), ensure_ascii=False)

    @server.tool()
    async def resume_task(task_id: str) -> str:
        """Resume a checkpointed task only after safety is clear."""
        try:
            response = await asyncio.to_thread(bridge.call, "task_resume", {"task_id": task_id})
        except (BridgeError, OSError) as exc:
            raise ToolError(str(exc)) from exc
        return json.dumps(response.get("result", response), ensure_ascii=False)

    return server


def main() -> None:
    password = os.environ.get("FACTORIO_RCON_PASSWORD", "")
    password_file = os.environ.get("FACTORIO_RCON_PASSWORD_FILE")
    if not password and password_file:
        password = Path(password_file).read_text(encoding="utf-8-sig").strip()
    bridge = Bridge(password, os.environ.get("FACTORIO_RCON_HOST", "127.0.0.1"),
                    int(os.environ.get("FACTORIO_RCON_PORT", "27075")))
    create_server(bridge).run()


if __name__ == "__main__":
    main()
