"""Scenario 4b: kill the MCP process mid-task, restart it, confirm no duplicate task/execution."""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402

CLIENT = [sys.executable, str(Path(__file__).resolve().parent / "mcp_client.py")]


def client(*args, timeout=30) -> str:
    done = subprocess.run([*CLIENT, *args], capture_output=True, text=True, timeout=timeout,
                          cwd=str(h.ROOT))
    return done.stdout.strip()


def main() -> int:
    h.load_scenario_save("s4b-mcp.zip")
    b = h.bridge()
    print("tools via MCP:", client("tools"))

    # Long task driven through the MCP tool, then the MCP process is killed.
    proc = subprocess.Popen([*CLIENT, "execute",
                             json.dumps({"task": "gather_resource", "resource": "iron-ore",
                                         "amount": 400})],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            cwd=str(h.ROOT))
    h.wait(lambda: h.status(b)["task"].get("status") == "running"
           and h.status(b)["task"].get("phase") in {"mining", "moving"},
           timeout=90, what="task running under MCP")
    running = h.status(b)["task"]
    print("task under MCP:", h.pretty(running)[:220])

    proc.kill()
    proc.wait(timeout=10)
    print("MCP client killed (SIGKILL), exit:", proc.returncode)
    time.sleep(3)

    # The game keeps the task; a fresh MCP process must see the same task, not a duplicate.
    alive = h.status(b)["task"]
    print("after MCP restart:", h.pretty(alive)[:220])
    fresh_status = json.loads(client("status"))
    print("fresh MCP status:", json.dumps(fresh_status, ensure_ascii=False)[:260])

    same_task = alive.get("task_id") == running.get("task_id")
    still_governed = alive.get("status") in {"running", "paused"}
    reported = fresh_status.get("task", {}).get("task_id") == running.get("task_id")
    print("same task id:", same_task, "| task still tracked:", still_governed,
          "| reported by new MCP:", reported)

    # Nothing was executed twice: a second execute_task with the same request id cannot exist here,
    # so the check is that only one task exists and the remaining amount is consistent.
    if alive.get("status") == "paused":
        print("resume:", h.pretty(b.call("task_resume", {"task_id": alive["task_id"]})["result"]))
    final = h.wait(lambda: (lambda s: s if s.get("status") in
                            {"succeeded", "failed", "cancelled"} else None)(
        b.call("task_status", {"task_id": alive["task_id"]})["result"]),
        timeout=900, interval=3, what="task completion")
    print("final:", h.pretty(final))
    total = h.snapshot(b)["main"].get("iron-ore", 0)
    print("iron-ore in inventory:", total)
    ok = same_task and still_governed and reported and final.get("collected") == 400
    print("RESULT", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
