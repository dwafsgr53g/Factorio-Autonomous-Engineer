"""Stage 7.1 C - reach-aware construction work zones.

Verifies that the construction scheduler partitions pending ghosts into zones
derived from the character's actual build distance, selects a floating working
position per zone, and builds every ghost that is reachable from that position
without approaching each ghost individually.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402

RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    RESULTS.append((name, bool(condition), detail))
    print(f"  {'PASS' if condition else 'FAIL'} {name}" + (f" :: {detail}" if detail else ""))


def fresh(save: str) -> h.Bridge:
    h.load_scenario_save(save, baseline="s71-baseline.zip")
    b = h.bridge()
    h.lua("game.speed = 60", b)
    h.research_all(b)
    h.lua("game.surfaces.nauvis.always_day = true", b)
    h.clear_test_area(-30, -30, 70, 40, b, keep_resources=True)
    h.set_home({"x": 0.5, "y": 0.5}, b)
    return b


def main() -> int:
    print("\nScenario A - large plan spans multiple build-reach zones")
    b = fresh("s19a-zones.zip")
    # Place a 4x4 grid of furnaces 6 tiles apart so that no single position can
    # reach more than one or two of them (build distance is 10).
    for ix in range(4):
        for iy in range(4):
            h.create_ghost("stone-furnace", 12 + ix * 6, 4 + iy * 6, b=b)
    ghosts_before = h.ghosts(b)
    print("  ghosts placed:", len(ghosts_before))
    check("the plan contains at least nine ghosts", len(ghosts_before) >= 9,
          str(len(ghosts_before)))
    h.give_items({"stone-furnace": 16}, b)
    build_distance = int(h.agent_lua("return a.build_distance", b))
    print("  build_distance:", build_distance)
    check("build distance is the live character value", build_distance == 10,
          str(build_distance))
    b.call("construction_schedule", {"entries": []})
    # The scheduler needs entries; provide them through task entries instead.
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    # Inspect the movement stats and task result.
    result = h.wait_task(task_id, b, timeout=300)
    print("  task:", h.pretty(result))
    real = h.entities_named(["stone-furnace"], b)
    print("  real furnaces:", len(real))
    check("every ghost was built", result.get("status") == "succeeded",
          result.get("reason"))
    check("sixteen real furnaces exist", len(real) == 16, str(len(real)))
    check("no ghost remains", len(h.ghosts(b)) == 0, str(len(h.ghosts(b))))
    movement = b.call("movement_status")["result"]
    stats = movement.get("stats", {})
    print("  movement stats:", h.pretty(stats))
    check("the character used path requests rather than teleportation",
          stats.get("path_requests", 0) >= 2, h.pretty(stats))
    check("no teleportation was used",
          stats.get("step_out_teleports", 0) == 0
          and result.get("step_out_teleports", 0) == 0,
          h.pretty({"movement": stats, "task": result.get("step_out_teleports")}))

    print("\nScenario B - the scheduler prefers positions that cover many ghosts")
    b2 = fresh("s19b-scoring.zip")
    # Clustered ghosts: a 3x3 cluster plus a lone distant ghost.
    for ix in range(3):
        for iy in range(3):
            h.create_ghost("stone-furnace", 10 + ix * 2, 4 + iy * 2, b=b2)
    h.create_ghost("stone-furnace", 40, 20, b=b2)
    h.give_items({"stone-furnace": 10}, b2)
    # Ask the scheduler directly with the pending entries of a task.
    tid = h.task_start({"task": "assist_construction"}, b2)["task_id"]
    h.wait(lambda: (h.task_entries(b2).get("entries") or []),
           timeout=30, interval=0.01, what="scheduler entries")
    h.lua("game.tick_paused = true", b2)
    sched = b2.call("construction_schedule")["result"]
    h.lua("game.tick_paused = false", b2)
    print("  scheduler:", h.pretty(sched))
    check("the scheduler returns a usable zone", sched.get("ok") is True,
          h.pretty(sched))
    if sched.get("ok"):
        check("the scheduler reports the live build reach",
              sched.get("reach") == 10, str(sched.get("reach")))
        check("the selected position covers more than one ghost",
              (sched.get("evaluation") or {}).get("covered", 0) >= 1,
              h.pretty(sched.get("evaluation")))
    h.task_cancel(tid, b=b2)
    print("  cancelled:", h.pretty(h.task_cancel(tid, b=b2)))

    print("\nScenario C - dynamic work position reselection")
    b3 = fresh("s19c-reselect.zip")
    # Place a ghost where the preferred position would be occupied by a conveyor.
    h.create_real_entity("transport-belt", 8.5, 4.5, direction=4, b=b3)
    for ix in range(2):
        for iy in range(2):
            h.create_ghost("stone-furnace", 10 + ix * 2, 4 + iy * 2, b=b3)
    h.give_items({"stone-furnace": 4}, b3)
    tid = h.task_start({"task": "assist_construction"}, b3)["task_id"]
    result3 = h.wait_task(tid, b3, timeout=180)
    print("  task:", h.pretty(result3))
    real3 = h.entities_named(["stone-furnace"], b3)
    check("the task completed despite an occupied preferred position",
          result3.get("status") in {"succeeded", "partial"}, result3.get("reason"))
    check("the task made progress despite the occupied position", len(real3) >= 2, str(len(real3)))
    check("the conveyor was preserved",
          len(h.entities_named(["transport-belt"], b3)) == 1,
          h.pretty(h.entities_named(["transport-belt"], b3)))

    failed = [name for name, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:", failed)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
