"""Minimal stdio MCP client: one-shot call against the real MCP server entry point."""
import asyncio
import json
import os
import sys
from pathlib import Path

from mcp import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

ROOT = Path(__file__).resolve().parents[2]
ENV = {
    **os.environ,
    "FACTORIO_RCON_HOST": "127.0.0.1",
    "FACTORIO_RCON_PORT": "27075",
    "FACTORIO_RCON_PASSWORD_FILE": str(ROOT / ".runtime" / "rcon-password.txt"),
    "FACTORIO_TASK_POLL_INTERVAL": "1.0",
}


async def main(mode: str, payload: str) -> int:
    params = StdioServerParameters(
        command=sys.executable,
        args=["-c", "from factorio_autonomous_engineer.server import main; main()"],
        env=ENV,
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            if mode == "tools":
                tools = await session.list_tools()
                print(json.dumps([t.name for t in tools.tools]))
            elif mode == "status":
                result = await session.call_tool("get_agent_status", {})
                print(result.content[0].text)
            elif mode == "execute":
                args = json.loads(payload)
                result = await session.call_tool("execute_task", args)
                print(result.content[0].text if result.content else "<no content>")
            else:
                raise SystemExit(f"unknown mode {mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "{}")))
