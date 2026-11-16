"""Scenario 3: death, inventory + equipment recovery, respawn, no loss or duplication."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402


def flat(snap: dict) -> dict:
    out = {}
    for part in ("main", "guns", "ammo", "armor", "equipment"):
        for name, count in (snap.get(part) or {}).items():
            out[f"{part}:{name}"] = count
    return out


def main() -> int:
    h.load_scenario_save("s3-death.zip")
    b = h.bridge()
    print("kit:", h.pretty(h.give_kit(b)))
    before = h.snapshot(b)
    print("initial:", h.pretty(flat(before)))

    request = {"task": "gather_resource", "resource": "iron-ore", "amount": 60}
    task = b.call("task_start", request)["result"]
    print("task:", task)
    h.wait(lambda: h.status(b)["task"].get("phase") in {"mining", "moving"}, timeout=60,
           what="task phase mining/moving")
    print("phase before kill:", h.status(b)["task"].get("phase"))

    # Conservation is asserted across the death, so the baseline is the inventory at
    # the moment of death. Anything the agent mined before dying is legitimate and is
    # carried through the loot recovery; comparing with the pre-task inventory would
    # report that as duplication.
    before = h.snapshot(b)
    print("before death:", h.pretty(flat(before)),
          "| collected:", h.status(b)["task"].get("collected"))
    unit_before = before["unit"]
    print("kill:", repr(h.agent_lua("a.die() return ''", b)))
    h.wait(lambda: h.status(b)["lifecycle"]["status"] != "alive", timeout=20,
           what="death registered")
    print("lifecycle:", h.pretty(h.status(b)["lifecycle"]))
    print("task after death:", h.pretty(h.status(b)["task"]))
    print("recovery_item_count:", h.status(b)["lifecycle"].get("recovery_item_count"))
    events = b.call("agent_events", {"limit": 10, "after_id": 0})["result"]["events"]
    print("events:", h.pretty(events)[:900])

    h.wait(lambda: h.status(b)["lifecycle"]["status"] == "alive", timeout=90, what="respawn")
    after = h.snapshot(b)
    print("after:", h.pretty(flat(after)))

    b_flat, a_flat = flat(before), flat(after)
    missing = {k: v for k, v in b_flat.items() if a_flat.get(k, 0) < v}
    extra = {k: v for k, v in a_flat.items() if b_flat.get(k, 0) != v}
    print("unit numbers:", unit_before, "->", after["unit"])
    print("MISSING (loss):", h.pretty(missing))
    print("DIFFERENT (dup/loss):", h.pretty(extra))
    print("recovery_item_count after respawn:", h.status(b)["lifecycle"].get("recovery_item_count"))

    status = b.call("task_status", {"task_id": task["task_id"]})["result"]
    print("task while paused:", h.pretty(status)[:300])
    print("resume:", h.pretty(b.call("task_resume", {"task_id": task["task_id"]})["result"]))
    result = h.wait(lambda: (lambda s: s if s.get("status") in
                             {"succeeded", "failed", "cancelled"} else None)(
        b.call("task_status", {"task_id": task["task_id"]})["result"]),
        timeout=400, interval=3, what="task completion")
    print("final task:", h.pretty(result))
    h.clear_enemies(b)
    print("RESULT", "PASS" if not missing and not extra else "FAIL")
    return 0 if not missing and not extra else 1


if __name__ == "__main__":
    raise SystemExit(main())
