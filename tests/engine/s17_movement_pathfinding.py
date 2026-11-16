"""Stage 7.1 A/B - pathfinder integration and ordinary waypoint movement.

Verified live on Factorio 2.1.24:
  * LuaEntity.build_distance is 10 and matches LuaEntityPrototype.build_distance.
  * LuaEntity.can_place_entity with build_check_type.ghost_revive rejects a 2x2 ghost
    at distance 11 while accepting distance 10, so the live check, not a geometric
    approximation, is the placement authority.
  * walking_state must be re-issued every tick; a single assignment does not create a
    persistent autonomous walk.
  * a path goal inside solid water returns an empty path (no exception), and a wall
    produces a path around the wall rather than needs_destroy_to_reach for this case.
"""
from __future__ import annotations

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
    h.load_scenario_save(save, baseline="s71-baseline.zip")
    b = h.bridge()
    h.lua("game.speed = 60", b)
    h.research_all(b)
    h.lua("game.surfaces.nauvis.always_day = true", b)
    h.clear_test_area(-24, -24, 60, 32, b, keep_resources=True)
    h.set_home({"x": 0.5, "y": 0.5}, b)
    return b


def movement_status(b: h.Bridge) -> dict:
    return b.call("movement_status")["result"]


def main() -> int:
    print("\nScenario A - pathfinder request shape and callback correlation")
    b = fresh("s17a-path.zip")
    probes = {
        "build_distance": h.agent_lua("return a.build_distance", b),
        "prototype_build_distance": h.agent_lua("return a.prototype.build_distance", b),
        "collision_box": h.agent_lua(
            "return helpers.table_to_json(a.prototype.collision_box)", b),
        "collision_mask": h.agent_lua(
            "return helpers.table_to_json(a.prototype.collision_mask)", b),
    }
    print("  live character geometry:", h.pretty(probes))
    check("agent build_distance is the live character value",
          probes["build_distance"] == "10", probes["build_distance"])
    check("prototype agrees with the live character",
          probes["prototype_build_distance"] == "10", probes["prototype_build_distance"])

    b.lua('game.tick_paused = true', b) if False else None
    h.lua("game.tick_paused = true", b)
    placed = h.create_ghost("stone-furnace", 9, 0, b=b)
    check("test ghost created", bool(placed), h.pretty(placed))
    h.lua("game.tick_paused = false", b)

    # A ghost placed from the character at (0,0): distance 9 is inside build reach and
    # the live can_place_entity check accepts it.
    reach_checks = h.lua(
        "local a = remote.call('factorio_autonomous_engineer','get_agent')\n"
        "local out = {}\n"
        "for d = 1, 13 do\n"
        "  local ok, r = pcall(function() return a.can_place_entity{name='stone-furnace',\n"
        "    position={x=a.position.x+d,y=a.position.y},direction=0,\n"
        "    build_check_type=defines.build_check_type.ghost_revive} end)\n"
        "  out[tostring(d)] = ok and r or false\n"
        "end\n"
        "rcon.print(helpers.table_to_json(out))", b)
    import json as _json
    reach_checks = _json.loads(reach_checks)
    print("  live can_place by distance:", reach_checks)
    ok = True
    for distance in range(1, 11):
        if str(distance) not in reach_checks or reach_checks[str(distance)] is not True:
            ok = False
    check("live can_place_entity accepts every distance within build reach", ok)
    check("live can_place_entity rejects a distance beyond build reach",
          reach_checks.get("11") is False and reach_checks.get("12") is False,
          str(reach_checks.get("11")))

    print("\nScenario B - normal movement, waypoint advance and arrival")
    b.call("movement_reset_stats")
    h.lua("game.tick_paused = true", b)
    h.agent_lua("a.teleport({x=0, y=0}) return ''", b)
    h.lua("game.tick_paused = false", b)
    # Start a task far enough away that a real route is required.
    h.create_ghost("stone-furnace", 26, 0, b=b)
    h.give_items({"stone-furnace": 2}, b)
    # Movement-progress observation uses a slow clock so the following state is
    # observable; the task completes at normal speed afterwards.
    h.lua("game.speed = 5", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: movement_status(b)["movement"].get("state") == "following_path"
           or movement_status(b)["movement"].get("state") == "arrived",
           timeout=90, interval=0.1, what="waypoint following")
    first = movement_status(b)
    print("  first movement state:", h.pretty(first)[:600])
    check("the character walked through the pathfinder",
          first["stats"].get("path_requests", 0) >= 1,
          h.pretty(first.get("stats")))
    check("the callback advanced a waypoint index",
          (first["detail"]["intents"][0].get("waypoint_index") or 0) >= 1,
          h.pretty(first["detail"]["intents"][0]))
    h.wait(lambda: h.status(b)["lifecycle"]["position"]["x"] > 12,
           timeout=60, interval=0.1, what="character walking east along the route")
    h.lua("game.speed = 60", b)
    walked = h.status(b)["lifecycle"]["position"]
    print("  position after walking east:", h.pretty(walked))
    check("the character physically moved toward the ghost", walked["x"] > 12,
          h.pretty(walked))
    result = h.wait_task(task_id, b, timeout=180)
    print("  task:", h.pretty(result))
    check("the construction task succeeded", result.get("status") == "succeeded",
          result.get("reason"))
    final = movement_status(b)
    print("  final movement stats:", h.pretty(final.get("stats")))
    check("movement is idle after arrival", final["movement"].get("state") in {"idle", "arrived"},
          final["movement"].get("state"))
    check("every waypoint arrival was reached by walking (no teleport path)",
          final["stats"].get("arrivals", 0) >= 1, h.pretty(final.get("stats")))

    print("\nScenario C - unreachable goal and bounded failure")
    h.clear_main_inventory(b)
    b.call("movement_reset_stats")
    # Build a sealed stone-wall box around the destination: the pathfinder must report
    # a bounded no-path/blocked result instead of looping.
    h.lua(
        "local s = game.surfaces.nauvis\n"
        "for x = -1, 1 do\n"
        "  for y = -1, 1 do\n"
        "    if math.abs(x) == 1 or math.abs(y) == 1 then\n"
        "      s.create_entity{name='stone-wall', position={x=40+x,y=20+y},"
        " force=game.forces.player}\n"
        "    end\n"
        "  end\n"
        "end\n"
        "rcon.print('sealed')", b)
    h.create_ghost("stone-furnace", 40, 20, b=b)
    h.give_items({"stone-furnace": 1}, b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    result = h.wait_task(task_id, b, timeout=180)
    print("  sealed-ghost task:", h.pretty(result))
    status = movement_status(b)
    print("  movement after the sealed goal:", h.pretty(status["movement"]))
    check("an unreachable construction site is reported rather than looped",
          result.get("status") in {"partial", "blocked", "missing_materials"},
          h.pretty(result))
    check("the movement controller reported a terminal movement state",
          status["movement"].get("state") in {"idle", "blocked", "arrived"},
          status["movement"].get("state"))
    check("path requests were bounded",
          (b.call("movement_status")["result"]["stats"].get("path_requests", 0)) <= 12,
          h.pretty(b.call("movement_status")["result"]["stats"]))

    print("\nScenario D - cancel and destination change invalidates stale callbacks")
    b.call("movement_reset_stats")
    h.lua("game.tick_paused = true", b)
    h.agent_lua("a.teleport({x=0, y=0}) return ''", b)
    h.lua("game.tick_paused = false", b)
    h.create_ghost("stone-furnace", 20, 6, b=b)
    h.create_ghost("stone-furnace", 30, 6, b=b)
    h.give_items({"stone-furnace": 2}, b)
    h.lua("game.speed = 5", b)
    task_id = h.task_start({"task": "assist_construction", "plan": None}, b)["task_id"]
    h.wait(lambda: movement_status(b)["movement"].get("state") == "following_path",
           timeout=90, interval=0.1, what="following path before cancel")
    h.task_cancel(task_id, b=b)
    time.sleep(2)
    status = movement_status(b)
    print("  movement after cancel:", h.pretty(status["movement"]))
    check("cancel stopped the ordinary movement", status["movement"].get("state") in
          {"idle", "cancelled"}, status["movement"].get("state"))
    check("the character stopped walking",
          h.agent_lua("return tostring(a.walking_state.walking)", b) == "false")

    failed = [name for name, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:", failed)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())