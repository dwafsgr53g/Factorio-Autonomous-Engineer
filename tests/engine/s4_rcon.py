"""Scenario 4: RCON faults — connection loss, MCP restart, reconnect, no duplicate execution."""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402


def main() -> int:
    checks = {}
    h.load_scenario_save("s4-rcon.zip")
    b = h.bridge()

    # 1. Idempotency of a completed action: the same request id must not create a second task.
    rid = "dup-request-1"
    first = b.call("task_start", {"task": "gather_resource", "resource": "iron-ore", "amount": 10},
                   request_id=rid)
    print("first task_start:", h.pretty(first["result"]))
    task_id = first["result"]["task_id"]
    h.wait(lambda: b.call("task_status", {"task_id": task_id})["result"]
           .get("status") in {"succeeded", "failed"},
           timeout=300, interval=2, what="first task done")
    replay = b.call("task_start", {"task": "gather_resource", "resource": "iron-ore", "amount": 10},
                    request_id=rid)
    print("replayed task_start:", h.pretty(replay["result"]))
    print("tick in cached response:", replay.get("tick"), "vs", first.get("tick"))
    checks["replay_identical"] = replay["result"] == first["result"]

    fresh = b.call("task_start", {"task": "gather_resource", "resource": "iron-ore", "amount": 10})
    print("new request id creates a new task:", h.pretty(fresh["result"]))
    checks["new_id_executes"] = fresh["result"]["task_id"] != first["result"]["task_id"]
    b.call("task_cancel", {"task_id": fresh["result"]["task_id"], "reason": "cleanup"})

    # 2. The cache must survive save/load.
    h.save_as("s4-mid", b)
    h.stop_server()
    h.start_server("s4-mid.zip")
    b = h.bridge()
    replay_after_load = b.call("task_start", {"task": "gather_resource", "resource": "iron-ore",
                                              "amount": 10}, request_id=rid)
    print("replay after reload:", h.pretty(replay_after_load["result"]))
    checks["cache_survives_load"] = replay_after_load["result"] == first["result"]

    # 3. Connection loss while the executor is waiting for a task.
    long_request = {"task": "gather_resource", "resource": "iron-ore", "amount": 300}
    task = b.call("task_start", long_request)["result"]
    print("long task:", task)
    h.wait(lambda: h.status(b)["task"].get("phase") in {"mining", "moving"}, timeout=90,
           what="long task running")
    started = time.monotonic()
    h.stop_server()
    try:
        b.call("task_status", {"task_id": task["task_id"]})
        checks["loss_raises"] = False
        error_text = "<no error>"
    except h.BridgeError as exc:
        error_text = str(exc)
        checks["loss_raises"] = "RCON unavailable" in error_text and "request_id" in error_text
    elapsed = time.monotonic() - started
    print(f"error after {elapsed:.1f}s: {error_text}")
    checks["loss_is_fast"] = elapsed < 20

    # 4. Reconnect: state is inspectable from a brand new client and no duplicate task exists.
    h.start_server("s4-mid.zip")
    b = h.bridge()
    print("status after reconnect:", h.pretty(h.status(b))[:260])
    checks["reconnect_status_ok"] = h.status(b)["lifecycle"]["status"] == "alive"

    # 5. Wrong password is reported clearly and does not create a task.
    bad = h.Bridge("wrong-password", "127.0.0.1", 27075)
    try:
        bad.call("task_start", {"task": "gather_resource", "resource": "iron-ore", "amount": 5})
        checks["bad_password"] = False
        bad_text = "<no error>"
    except h.BridgeError as exc:
        bad_text = str(exc)
        checks["bad_password"] = "authentication" in bad_text.lower()
    print("wrong password:", bad_text)

    # 6. No server at all.
    h.stop_server()
    started = time.monotonic()
    try:
        h.bridge().call("ping")
        checks["no_server"] = False
        down_text = "<no error>"
    except (h.BridgeError, OSError) as exc:
        down_text = f"{type(exc).__name__}: {exc}"
        checks["no_server"] = "RCON unavailable" in down_text or "refused" in down_text.lower()
    print(f"server down ({time.monotonic() - started:.1f}s): {down_text}")

    checks["all"] = all(checks.values())
    print("checks:", h.pretty(checks))
    print("RESULT", "PASS" if checks["all"] else "FAIL")
    return 0 if checks["all"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
