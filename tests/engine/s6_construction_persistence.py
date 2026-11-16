"""Construction persistence and interruption scenarios H.

Covers save/load during clearing and after a chest transfer, Safety Controller
pre-emption with an explicit resume, cancellation, player interference and a player
removing materials from a chest during the task.
"""
from __future__ import annotations

import asyncio
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402

RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    RESULTS.append((name, bool(condition), detail))
    print(f"  {'PASS' if condition else 'FAIL'} {name}" + (f" :: {detail}" if detail else ""))


def fresh(save: str) -> h.Bridge:
    h.load_scenario_save(save)
    b = h.bridge()
    h.clear_main_inventory(b)
    h.clear_test_area(-24, -40, 80, 42, b, keep_resources=True)
    return b


def save_reload(b: h.Bridge, name: str) -> h.Bridge:
    # Freeze the tick so the state observed by the preceding wait() cannot advance
    # between the assertion, the save and the hard stop.
    h.lua("game.tick_paused = true", b)
    print("  save:", repr(h.save_as(name, b)))
    h.stop_server()
    h.start_server(name + ".zip")
    b = h.bridge()
    h.lua("game.tick_paused = false", b)
    return b


def scenario_h1() -> None:
    print("\nScenario H1 — save/load during clearing")
    b = fresh("s6h1-clearing.zip")
    h.create_natural("tree-01", 42, 8, b)
    h.create_natural("big-sand-rock", 48, 8, b)
    h.create_ghost("transport-belt", 42, 8, direction=4, b=b)
    h.create_ghost("transport-belt", 48, 8, direction=4, b=b)
    h.create_ghost("transport-belt", 55, 8, direction=4, b=b)
    h.give_items({"transport-belt": 3}, b)
    h.lua("game.speed = 5", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: (h.status(b)["task"].get("status") == "running"
                    and h.status(b)["task"].get("built_by_agent", 0) >= 1
                    and h.status(b)["task"].get("remaining", 0) >= 1
                    and h.status(b)["task"].get("obstacles_cleared")),
           timeout=120, interval=0.2, what="first obstacle cleared and more work remains")
    before = h.status(b)["task"]
    print("  before save:", h.pretty(before)[:700])
    b = save_reload(b, "s6h1-mid")
    after = h.status(b)["task"]
    print("  after load:", h.pretty(after)[:700])
    check("task id survives", after.get("task_id") == task_id)
    check("task is still running", after.get("status") == "running", after.get("status"))
    check("progress ledger survives", after.get("built_by_agent", 0) >= 1
          and after.get("obstacles_cleared", {}).get("tree-01") == 1)
    result = h.wait_task(task_id, b, timeout=240)
    print("  final:", h.pretty(result))
    print("  inventory:", h.pretty(h.snapshot(b)["main"]))
    check("task completes after reload", result.get("status") == "succeeded",
          result.get("reason"))
    check("three objects built exactly once",
          len(h.entities_named(["transport-belt"], b)) == 3)
    check("no ghost remains", len(h.ghosts(b)) == 0)
    check("cleared resources survive save/load",
          h.snapshot(b)["main"].get("wood", 0) > 0
          and h.snapshot(b)["main"].get("stone", 0) > 0,
          h.pretty(h.snapshot(b)["main"]))


def scenario_h2() -> None:
    print("\nScenario H2 — save/load after chest transfer, before building")
    b = fresh("s6h2-transfer.zip")
    h.place_plan("single_furnace", b)
    ghost = h.ghosts(b)[0]
    chest = h.create_chest(60, 10, {"stone-furnace": 1}, b)
    h.lua("game.speed = 5", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: (h.status(b)["task"].get("items_transferred", 0) >= 1
                    and h.status(b)["task"].get("built_by_agent", 0) == 0
                    and h.status(b)["task"].get("phase") == "moving"),
           timeout=120, what="materials transferred and agent walking")
    before = h.status(b)["task"]
    print("  before save:", h.pretty(before)[:650])
    check("chest was debited before save", h.chest_contents(chest["unit"], b) == {})
    check("agent holds the item before save",
          h.snapshot(b)["main"].get("stone-furnace") == 1,
          h.pretty(h.snapshot(b)["main"]))
    b = save_reload(b, "s6h2-mid")
    after = h.status(b)["task"]
    print("  after load:", h.pretty(after)[:650])
    check("task id survives", after.get("task_id") == task_id)
    check("transferred item survives exactly once",
          h.snapshot(b)["main"].get("stone-furnace") == 1,
          h.pretty(h.snapshot(b)["main"]))
    result = h.wait_task(task_id, b, timeout=240)
    print("  final:", h.pretty(result))
    print("  chest:", h.chest_contents(chest["unit"], b),
          "| inventory:", h.pretty(h.snapshot(b)["main"]))
    check("task completes", result.get("status") == "succeeded", result.get("reason"))
    check("chest did not lose a second item", h.chest_contents(chest["unit"], b) == {})
    check("one furnace built", len(h.entities_named(["stone-furnace"], b)) == 1)
    check("agent did not get a duplicate item", not h.snapshot(b)["main"])
    check("built position is correct",
          bool(h.entity_at("stone-furnace", ghost["position"]["x"],
                           ghost["position"]["y"], 3, b)))


async def scenario_h3() -> None:
    print("\nScenario H3 — Safety Controller pre-emption and explicit resume")
    b = fresh("s6h3-safety.zip")
    for x in (42, 48, 52):
        h.create_ghost("transport-belt", x, 8, direction=4, b=b)
    h.give_items({"transport-belt": 3}, b)
    h.lua("game.speed = 5", b)
    runner = h.TaskRunner(b, poll_interval=1.0)
    execute = asyncio.create_task(runner.execute({"task": "assist_construction"}, timeout=600))
    await asyncio.to_thread(
        h.wait, lambda: h.status(b)["task"].get("phase") in {"moving", "pathing"},
        timeout=60, what="construction moving")
    await asyncio.to_thread(h.spawn_attackers, 3, 8.0, b)
    result = await asyncio.wait_for(execute, timeout=120)
    print("  runner result:", h.pretty(result)[:500])
    task = h.status(b)["task"]
    check("runner returns interrupted_by_safety",
          result.get("status") == "interrupted_by_safety", result.get("status"))
    check("task paused for safety", task.get("status") == "paused"
          and task.get("reason") == "safety", h.pretty(task)[:300])
    await asyncio.to_thread(h.clear_enemies, b)
    await asyncio.to_thread(h.wait, lambda: not h.status(b)["safety"]["active"],
                            timeout=180, what="safety resolved")
    await asyncio.sleep(3)
    paused = h.status(b)["task"]
    print("  after safety cleared:", h.pretty(paused)[:500])
    check("task does not resume automatically", paused.get("status") == "paused"
          and paused.get("reason") in {"safety", "awaiting_llm_resume"}, h.pretty(paused)[:300])
    h.lua("game.speed = 60", b)
    print("  resume:", h.pretty(b.call("task_resume", {"task_id": result["task_id"]})["result"]))
    final = await asyncio.to_thread(h.wait_task, result["task_id"], b, timeout=240)
    print("  final:", h.pretty(final))
    check("explicit resume completes the task", final.get("status") == "succeeded",
          final.get("reason"))
    check("all three objects built once", len(h.entities_named(["transport-belt"], b)) == 3)
    check("no ghost remains", len(h.ghosts(b)) == 0)


def scenario_h4() -> None:
    print("\nScenario H4 — cancel during movement")
    b = fresh("s6h4-cancel.zip")
    h.create_ghost("transport-belt", 50, 8, direction=4, b=b)
    h.give_items({"transport-belt": 1}, b)
    before = h.snapshot(b)["main"]
    h.lua("game.speed = 5", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: h.status(b)["task"].get("phase") in {"moving", "pathing"},
           timeout=60, what="agent moving")
    cancelled = b.call("task_cancel", {"task_id": task_id, "reason": "harness_cancel"})["result"]
    time.sleep(2)
    after = h.status(b)["task"]
    print("  cancel:", h.pretty(cancelled)[:450])
    print("  after:", h.pretty(after)[:450])
    check("terminal status is cancelled", after.get("status") == "cancelled"
          and after.get("reason") == "harness_cancel", h.pretty(after)[:250])
    walking = h.agent_lua("return tostring(a.walking_state.walking)", b)
    check("agent stopped walking", walking == "false", walking)
    check("ghost remains", len(h.ghosts(b)) == 1)
    check("inventory unchanged", h.snapshot(b)["main"] == before)
    check("nothing built", not h.entity_at("transport-belt", 50, 8, 2, b))


def scenario_h5() -> None:
    print("\nScenario H5 — player working at a site is not disturbed")
    b = fresh("s6h5-player.zip")
    h.create_ghost("transport-belt", 42, 8, direction=4, b=b)
    h.create_ghost("transport-belt", 55, 8, direction=4, b=b)
    player = h.create_player_character(42, 11, b)
    h.give_items({"transport-belt": 2}, b)
    h.lua("game.speed = 5", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    result = h.wait_task(task_id, b, timeout=120)
    print("  result:", h.pretty(result))
    check("task reports player interference", result.get("status") == "partial"
          and result.get("reason") == "player_interference", h.pretty(result)[:400])
    check("agent built only the free site", result.get("built_by_agent") == 1)
    check("player-occupied ghost remains", len(h.ghosts(b)) == 1)
    check("player character remains", bool(h.entities_named(["character"], b)))
    print("  remove player:", h.remove_entity(player["unit"], b))
    follow = h.task_start({"task": "assist_construction"}, b)["task_id"]
    final = h.wait_task(follow, b, timeout=180)
    print("  follow-up:", h.pretty(final))
    check("follow-up succeeds after the player leaves", final.get("status") == "succeeded",
          final.get("reason"))
    check("both sites now have exactly one belt",
          len(h.entities_named(["transport-belt"], b)) == 2)
    check("no ghosts remain", len(h.ghosts(b)) == 0)


def scenario_h6() -> None:
    print("\nScenario H6 — player removes materials from a chest during the task")
    b = fresh("s6h6-chest-race.zip")
    h.create_ghost("stone-furnace", 42, 8, b=b)
    h.create_ghost("stone-furnace", 50, 8, b=b)
    chest = h.create_chest(32, 16, {"stone-furnace": 2}, b)
    h.lua("game.speed = 5", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: (h.status(b)["task"].get("items_transferred", 0) >= 1
                    and h.status(b)["task"].get("built_by_agent", 0) == 0),
           timeout=120, interval=0.2, what="first chest transfer before building")
    print("  after first transfer:", h.pretty(h.status(b)["task"])[:600])
    removed = h.remove_chest_items(chest["unit"], "stone-furnace", 1, b)
    print("  player removed from chest:", removed)
    h.lua("game.speed = 60", b)
    result = h.wait_task(task_id, b, timeout=180)
    print("  final:", h.pretty(result))
    check("player removal is observed", removed == 1)
    check("task reports missing materials or partial",
          result.get("status") in {"partial", "missing_materials"}, h.pretty(result)[:400])
    check("only one furnace was built", len(h.entities_named(["stone-furnace"], b)) == 1)
    check("one ghost remains", len(h.ghosts(b)) == 1)
    check("no item was duplicated", not h.snapshot(b)["main"])


def scenario_h7() -> None:
    print("\nScenario H7 — death and respawn during construction")
    b = fresh("s6h7-death.zip")
    for x in (42, 48, 52):
        h.create_ghost("transport-belt", x, 8, direction=4, b=b)
    h.give_items({"transport-belt": 3}, b)
    h.lua("game.speed = 5", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: h.status(b)["task"].get("phase") in {"moving", "pathing"},
           timeout=60, what="construction moving")
    print("  kill:", repr(h.agent_lua("a.die() return ''", b)))
    h.wait(lambda: h.status(b)["lifecycle"]["status"] != "alive", timeout=20,
           what="death registered")
    paused = h.status(b)["task"]
    print("  task after death:", h.pretty(paused)[:500])
    h.wait(lambda: h.status(b)["lifecycle"]["status"] == "alive", timeout=90,
           what="respawn")
    recovered = h.snapshot(b)["main"]
    print("  inventory after respawn:", h.pretty(recovered))
    check("task paused for death", paused.get("status") == "paused"
          and paused.get("reason") == "death", h.pretty(paused)[:250])
    check("construction materials survive death", recovered.get("transport-belt") == 3,
          h.pretty(recovered))
    h.lua("game.speed = 60", b)
    print("  resume:", h.pretty(b.call("task_resume", {"task_id": task_id})["result"]))
    final = h.wait_task(task_id, b, timeout=240)
    print("  final:", h.pretty(final))
    check("task completes after respawn", final.get("status") == "succeeded",
          final.get("reason"))
    check("all three belts built once", len(h.entities_named(["transport-belt"], b)) == 3)
    check("no materials lost or duplicated", not h.snapshot(b)["main"],
          h.pretty(h.snapshot(b)["main"]))


async def main() -> int:
    scenario_h1()
    scenario_h2()
    await scenario_h3()
    scenario_h4()
    scenario_h5()
    scenario_h6()
    scenario_h7()
    failed = [name for name, ok, _ in RESULTS if not ok]
    print("\nSUMMARY", h.pretty({"checks": len(RESULTS), "failed": failed}))
    print("RESULT", "PASS" if not failed else "FAIL")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
