"""Hide internal Factorio action polling behind one high-level MCP invocation."""
from __future__ import annotations
import asyncio
import time
from collections.abc import Callable
from typing import Any
from .bridge import Bridge, BridgeError

TERMINAL_STATES = {
    "succeeded", "failed", "cancelled",
    "interrupted_by_safety", "interrupted_by_death",
}


class TaskRunner:
    def __init__(self, bridge: Bridge, *, poll_interval: float = 2.0,
                 clock: Callable[[], float] | None = None,
                 sleep: Callable[[float], Any] = asyncio.sleep) -> None:
        self.bridge = bridge
        self.poll_interval = max(0.1, poll_interval)
        self._clock = clock or time.monotonic
        self._sleep = sleep

    async def _call(self, operation: str,
                    params: dict[str, Any] | None = None) -> dict[str, Any]:
        return await asyncio.to_thread(self.bridge.call, operation, params)

    async def execute(self, spec: dict[str, Any], *, timeout: float = 1800) -> dict[str, Any]:
        """Start a composite task and return one terminal result to the MCP caller."""
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        started = await self._call("task_start", spec)
        payload = started.get("result") or {}
        task_id = payload.get("task_id")
        if not task_id:
            raise BridgeError("Factorio did not return a task_id")
        deadline = self._clock() + timeout
        try:
            while True:
                response = await self._call("task_status", {"task_id": task_id})
                status = response.get("result") or {}
                state = status.get("status", "unknown")
                emergency = status.get("emergency") or {}
                pause_reason = status.get("reason")
                if emergency.get("active") or state == "paused":
                    interrupted = (
                        "interrupted_by_death"
                        if emergency.get("status") == "respawning" or pause_reason == "death"
                        else "interrupted_by_safety"
                    )
                    return {"success": False, "status": interrupted, "task_id": task_id,
                            "task": status, "emergency": emergency}
                if state in TERMINAL_STATES:
                    return {"task_id": task_id, **status}
                if self._clock() >= deadline:
                    await self._call("task_cancel", {"task_id": task_id, "reason": "mcp_timeout"})
                    return {"success": False, "status": "failed", "reason": "mcp_wait_timeout",
                            "task_id": task_id, "last_status": status}
                await self._sleep(self.poll_interval)
        except asyncio.CancelledError:
            try:
                await asyncio.shield(
                    self._call("task_cancel", {"task_id": task_id, "reason": "mcp_cancelled"})
                )
            finally:
                raise
