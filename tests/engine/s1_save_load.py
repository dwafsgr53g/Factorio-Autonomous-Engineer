"""Scenario 1: save/load while gathering — the executor must continue or recover safely."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402


def main() -> int:
    h.load_scenario_save("s1-save-load.zip")
    b = h.bridge()
    request = {"task": "gather_resource", "resource": "iron-ore", "amount": 120}
    task = b.call("task_start", request)["result"]
    print("task:", task)

    h.wait(lambda: h.status(b)["task"].get("collected", 0) >= 5, timeout=240, what="some ore mined")
    mid_task = b.call("task_status", {"task_id": task["task_id"]})["result"]
    print("before save:", h.pretty(mid_task)[:260])

    print("save:", repr(h.save_as("s1-mid", b)))
    # Hard kill: no graceful save, mimics a crash of the game process.
    h.stop_server()
    print("server killed")

    h.start_server("s1-mid.zip")
    b = h.bridge()
    after = b.call("task_status", {"task_id": task["task_id"]})["result"]
    print("after reload:", h.pretty(after)[:320])
    print("agent:", h.pretty(h.status(b)["lifecycle"])[:200])

    result = h.wait(lambda: (lambda s: s if s.get("status") in
                             {"succeeded", "failed", "cancelled"} else None)(
        b.call("task_status", {"task_id": task["task_id"]})["result"]),
        timeout=900, interval=3, what="task completion")
    print("final:", h.pretty(result))

    inventory = h.snapshot(b)["main"]
    print("inventory:", h.pretty(inventory))
    carried = after.get("collected", 0)
    ok = (result.get("status") == "succeeded" and result.get("collected") == 120
          and inventory.get("iron-ore", 0) == 120 and carried >= 5
          and after.get("task_id") == task["task_id"])
    print("collected before reload:", carried, "| final collected:", result.get("collected"))
    print("RESULT", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
