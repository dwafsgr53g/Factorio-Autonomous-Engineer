"""Stage 7.1 D - movement and scheduler persistence.

Verifies that movement intents, recovery state and work-zone progress survive
save/load, and that task cancellation, safety pre-emption and death/respawn
keep the movement controller as the single walking_state writer.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402
import stage6_fixture as f  # noqa: E402

RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    RESULTS.append((name, bool(condition), detail))
    print(f"  {'PASS' if condition else 'FAIL'} {name}" + (f" :: {detail}" if detail else ""))


def main() -> int:
    print("\nScenario A - save/load while following a path")
    h.load_scenario_save("s20a-save.zip", baseline="s71-baseline.zip")
    b = h.bridge()
    h.lua("game.speed = 5", b)
    h.research_all(b)
    h.lua("game.surfaces.nauvis.always_day = true", b)
    h.clear_test_area(-20, -20, 40, 20, b, keep_resources=True)
    h.set_home({"x": 0.5, "y": 0.5}, b)
    h.create_ghost("stone-furnace", 24, 0, b=b)
    h.give_items({"stone-furnace": 1}, b)
    b.call("movement_reset_stats")
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: h.status(b)["task"].get("phase") in {"moving", "pathing"},
           timeout=60, interval=0.2, what="movement in progress")
    before = h.status(b)["task"]
    print("  before save:", h.pretty(before)[:400])
    b2 = f.save_reload(b, "s20a-mid")
    after = h.status(b2)["task"]
    check("the task id survives save/load", after.get("task_id") == task_id,
          h.pretty(after)[:200])
    check("the task is still running after load", after.get("status") == "running",
          after.get("status"))
    movement = b2.call("movement_status")["result"]
    check("movement state was restored to a routable state",
          movement["movement"].get("state") in {"idle", "path_pending", "following_path",
                                                 "pathing", "recovering"},
          movement["movement"].get("state"))
    result = h.wait_task(task_id, b2, timeout=120)
    print("  final:", h.pretty(result))
    check("the task completes after the save/load window",
          result.get("status") == "succeeded", result.get("reason"))

    print("\nScenario B - cancellation stops movement and preserves completed work")
    h.load_scenario_save("s20b-cancel.zip", baseline="s71-baseline.zip")
    b = h.bridge()
    h.lua("game.speed = 60", b)
    h.research_all(b)
    h.lua("game.surfaces.nauvis.always_day = true", b)
    h.clear_test_area(-20, -20, 40, 20, b, keep_resources=True)
    h.set_home({"x": 0.5, "y": 0.5}, b)
    h.create_ghost("stone-furnace", 12, 0, b=b)
    h.create_ghost("stone-furnace", 42, 0, b=b)
    h.create_ghost("stone-furnace", 60, 0, b=b)
    h.give_items({"stone-furnace": 3}, b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: h.status(b)["task"].get("built_by_agent", 0) >= 1,
           timeout=120, interval=0.05, what="first build")
    cancelled = h.task_cancel(task_id, b=b)
    print("  cancelled:", h.pretty(cancelled)[:300])
    check("cancel returns a terminal cancelled status",
          cancelled.get("status") == "cancelled", cancelled.get("status"))
    movement = b.call("movement_status")["result"]
    check("movement is idle after cancellation",
          movement["movement"].get("state") in {"idle", "cancelled"},
          movement["movement"].get("state"))
    check("the character stopped walking",
          h.agent_lua("return tostring(a.walking_state.walking)", b) == "false")
    check("at least one ghost was built before cancellation",
          cancelled.get("built_by_agent", 0) >= 1, str(cancelled.get("built_by_agent")))

    print("\nScenario C - safety pre-emption preserves the movement destination")
    h.load_scenario_save("s20c-safety.zip", baseline="s71-baseline.zip")
    b = h.bridge()
    h.lua("game.speed = 5", b)
    h.research_all(b)
    h.lua("game.surfaces.nauvis.always_day = true", b)
    h.clear_test_area(-20, -20, 40, 20, b, keep_resources=True)
    h.set_home({"x": 0.5, "y": 0.5}, b)
    h.create_ghost("stone-furnace", 20, 0, b=b)
    h.give_items({"stone-furnace": 1}, b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: h.status(b)["task"].get("phase") in {"moving", "pathing"},
           timeout=60, interval=0.2, what="movement in progress")
    h.spawn_attackers(3, 8, b)
    h.wait(lambda: h.status(b)["safety"].get("active") is True,
           timeout=60, interval=0.2, what="safety active")
    check("the task is paused by safety", h.status(b)["task"].get("status") == "paused",
          h.status(b)["task"].get("status"))
    movement = b.call("movement_status")["result"]
    detail = movement.get("detail") or {}
    emergency = detail.get("emergency")
    primary = detail.get("primary")
    primary_state = None
    for intent in detail.get("intents") or []:
        if intent.get("id") == primary:
            primary_state = intent.get("state")
    check("the movement controller was interrupted for safety",
          emergency is not None and primary_state == "interrupted",
          h.pretty({"emergency": emergency, "primary": primary,
                    "primary_state": primary_state}))
    h.clear_enemies(b)
    h.wait(lambda: h.status(b)["safety"].get("active") is False,
           timeout=60, interval=0.2, what="safety cleared")
    # Resume explicitly.
    h.task_resume(task_id, b)
    check("the task resumed", h.status(b)["task"].get("status") == "running",
          h.status(b)["task"].get("status"))
    result = h.wait_task(task_id, b, timeout=120)
    print("  result:", h.pretty(result))
    check("the task completes after safety resume",
          result.get("status") == "succeeded", result.get("reason"))

    print("\nScenario D - death and respawn preserve the movement controller ownership")
    h.load_scenario_save("s20d-death.zip", baseline="s71-baseline.zip")
    b = h.bridge()
    h.lua("game.speed = 5", b)
    h.research_all(b)
    h.lua("game.surfaces.nauvis.always_day = true", b)
    h.clear_test_area(-20, -20, 40, 20, b, keep_resources=True)
    h.set_home({"x": 0.5, "y": 0.5}, b)
    h.give_items({"stone-furnace": 1}, b)
    h.create_ghost("stone-furnace", 12, 0, b=b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: h.status(b)["task"].get("phase") in {"moving", "pathing"},
           timeout=60, interval=0.2, what="movement in progress")
    # Kill the agent.
    h.lua("local a = remote.call('factorio_autonomous_engineer','get_agent') "
          "a.damage(10000, game.forces.enemy, 'physical')", b)
    h.wait(lambda: h.status(b)["lifecycle"].get("status") == "dead",
           timeout=60, interval=0.2, what="agent death")
    check("the task is paused after death",
          h.status(b)["task"].get("status") == "paused",
          h.status(b)["task"].get("status"))
    # Wait for respawn.
    h.wait(lambda: h.status(b)["lifecycle"].get("status") == "alive",
           timeout=120, interval=1, what="respawn")
    check("the agent respawned", h.status(b)["lifecycle"].get("status") == "alive")
    movement = b.call("movement_status")["result"]
    check("movement intents were cleared on death",
          movement["movement"].get("state") in {"idle", "arrived"},
          movement["movement"].get("state"))
    h.task_resume(task_id, b)
    result = h.wait_task(task_id, b, timeout=120)
    print("  result:", h.pretty(result))
    check("the task completes after death and resume",
          result.get("status") == "succeeded", result.get("reason"))

    print("\nScenario E - walking_state has only one writer")
    # Static audit: grep the mod for direct walking_state writes.
    import subprocess
    out = subprocess.run(["grep", "-R", "walking_state", "mod/"],
                         capture_output=True, text=True)
    writers = [line for line in out.stdout.splitlines()
               if "walking_state" in line and "=" in line and "movement.lua" not in line
               and "walking_state for" not in line and "walking_state;" not in line]
    print("  direct walking_state writers outside movement.lua:", writers)
    check("only movement.lua writes walking_state",
          len(writers) == 0, str(writers))

    failed = [name for name, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:", failed)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
