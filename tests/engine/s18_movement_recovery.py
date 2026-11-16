"""Stage 7.1 A/C/D - dynamic movement recovery.

Covers the two displacement classes required by the movement controller:

* belt displacement: the character is carried by a real transport belt / splitter
  while following a waypoint list. Recovery must walk to a non-belt position,
  re-request a route from the actual position and continue the original intent.
* ghost obstruction: the character is placed inside an agent-owned ghost. Recovery
  must leave the footprint by normal walking, without destroying the ghost and
  without teleporting.

The scenario verifies recovery through observable state only: movement intents,
recovery counters, real ghost/real entity positions and the agent position trace.
"""
from __future__ import annotations

import json
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
    h.lua("game.speed = 5", b)
    h.research_all(b)
    h.lua("game.surfaces.nauvis.always_day = true", b)
    h.clear_test_area(-24, -24, 60, 32, b, keep_resources=True)
    h.set_home({"x": 0.5, "y": 0.5}, b)
    return b


def movement(b: h.Bridge) -> dict:
    return b.call("movement_status")["result"]


def install_trace(b: h.Bridge) -> None:
    """Harness-only position trace so the scenario can see actual displacement."""
    h.lua(
        "storage.ae_trace = {samples = {}, active = true}\n"
        "local function tick()\n"
        "  local t = storage.ae_trace\n"
        "  if not t or not t.active then return end\n"
        "  local a = remote.call('factorio_autonomous_engineer','get_agent')\n"
        "  if not a or not a.valid then return end\n"
        "  t.samples[#t.samples+1] = {tick = game.tick, x = a.position.x, y = a.position.y}\n"
        "end\n"
        "script.on_event(defines.events.on_tick, tick)", b)


def trace(b: h.Bridge) -> list:
    out = h.lua("rcon.print(helpers.table_to_json(storage.ae_trace and storage.ae_trace.samples "
                "or {}))", b)
    return json.loads(out or "[]")


def scenario_belt() -> None:
    print("Scenario A - real belt displacement is detected and recovered by walking")
    b = fresh("s18a-belt.zip")
    # A real running belt line pointing west, lying across the eastward route.
    for bx in range(10, 30):
        for by in range(0, 9):
            h.create_real_entity("transport-belt", bx + 0.5, by + 0.5, direction=12, b=b)
    belt_real = h.entities_named(["transport-belt"], b)
    print("  real belt entities:", len(belt_real))
    h.create_ghost("stone-furnace", 40, 4, b=b)
    h.create_ghost("stone-furnace", 46, 4, b=b)
    h.give_items({"stone-furnace": 2}, b)
    b.call("movement_reset_stats")
    install_trace(b)
    h.lua("game.speed = 5", b)
    # Test scaffolding: put the character in the middle of the real belt field,
    # then start the task. The first task movement is a normal path, and the
    # controller must detect that the belt is carrying the character.
    h.lua("game.tick_paused = true", b)
    h.agent_lua("a.teleport({x=20.5, y=4.5}) return ''", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.lua("game.tick_paused = false", b)
    h.wait(lambda: (movement(b)["stats"].get("belt_recoveries", 0) >= 1
                    or h.status(b)["task"].get("status") in
                    {"succeeded", "partial", "blocked", "missing_materials"}),
           timeout=180, interval=0.2, what="belt recovery")
    h.lua("game.speed = 60", b)
    result = h.wait_task(task_id, b, timeout=180)
    status = movement(b)
    print("  task:", h.pretty(result))
    print("  movement stats:", h.pretty(status.get("stats")))
    samples = trace(b)
    print("  position samples:", len(samples))
    check("the belt displacement was detected", status["stats"].get("belt_recoveries", 0) >= 1,
          h.pretty(status.get("stats")))
    check("recovery resumed the original destination",
          status["stats"].get("recovery_resumes", 0) >= 1
          or (status["stats"].get("path_requests", 0) >= 2
              and result.get("status") == "succeeded"),
          h.pretty(status.get("stats")))
    check("the character was actually carried by the real belt",
          any(s["y"] == 4.5 and s["x"] < 20.5 for s in samples), str(samples[:6]))
    check("the task completed after belt recovery",
          result.get("status") == "succeeded", result.get("reason"))
    check("the character walked off the belt by a normal path",
          result.get("belt_step_offs", 0) >= 1,
          h.pretty({"belt_step_offs": result.get("belt_step_offs"),
                    "teleports": result.get("step_out_teleports")}))
    check("recovery never used teleportation",
          result.get("step_out_teleports", 0) == 0, h.pretty(result.get("step_out_teleports")))
    real = h.entities_named(["stone-furnace"], b)
    print("  built:", h.pretty(real))
    check("both ghosts were built from the recovered position", len(real) == 2, h.pretty(real))
    check("the original belt infrastructure was preserved",
          len(h.entities_named(["transport-belt"], b)) == len(belt_real),
          h.pretty(h.entities_named(["transport-belt"], b)))


def scenario_aligned_belt() -> None:
    print("\nScenario A2 - aligned conveyor assistance does not trigger recovery")
    b = fresh("s18d-aligned.zip")
    for bx in range(-4, 25):
        h.create_real_entity("transport-belt", bx + 0.5, 0.5, direction=4, b=b)
    belt_count = len(h.entities_named(["transport-belt"], b))
    h.lua("game.tick_paused = true", b)
    h.agent_lua("a.teleport({x=0.5, y=0.5}) return ''", b)
    h.lua("game.tick_paused = false", b)
    b.call("movement_reset_stats")
    install_trace(b)
    h.lua(
        "storage.ae_path_trace = {}\n"
        "script.on_event(defines.events.on_script_path_request_finished, function(e)\n"
        "  local paths = storage.ae_path_trace\n"
        "  if #paths < 8 then paths[#paths+1] = {id=e.id, path=e.path} end\n"
        "end)", b)
    requested = b.call("movement_request", {
        "owner": "aligned-belt-test", "purpose": "aligned_ride",
        "destination": {"x": 20.5, "y": 0.5}, "arrival_tolerance": 0.8,
    })["result"]
    check("aligned movement intent was accepted", requested.get("ok") is True,
          h.pretty(requested))
    h.wait(lambda: movement(b)["movement"].get("state") in {"arrived", "blocked"},
           timeout=90, interval=0.1, what="aligned belt arrival")
    status = movement(b)
    samples = trace(b)
    print("  aligned movement:", h.pretty(status["movement"]))
    print("  aligned stats:", h.pretty(status.get("stats")))
    print("  returned paths:", h.lua(
        "rcon.print(helpers.table_to_json(storage.ae_path_trace or {}))", b))
    check("aligned conveyor reached the original target",
          status["movement"].get("state") == "arrived", status["movement"].get("reason"))
    check("aligned conveyor caused no belt step-off",
          status["stats"].get("belt_recoveries", 0) == 0,
          h.pretty(status.get("stats")))
    check("aligned conveyor used ordinary pathfinding and physical travel",
          status["stats"].get("path_requests", 0) >= 1
          and any(sample["x"] > 18 for sample in samples),
          h.pretty({"stats": status.get("stats"), "last": samples[-1:] }))
    check("aligned conveyor infrastructure was preserved",
          len(h.entities_named(["transport-belt"], b)) == belt_count)


def scenario_ghost() -> None:
    print("\nScenario B - character embedded in a ghost is walked out without destroying it")
    b = fresh("s18b-ghost.zip")
    h.create_ghost("stone-furnace", 8, 0, b=b)
    h.give_items({"stone-furnace": 1}, b)
    b.call("movement_reset_stats")
    install_trace(b)
    h.lua("game.tick_paused = true", b)
    # Test scaffolding: place the character inside the agent-owned ghost footprint.
    h.agent_lua("a.teleport({x=8, y=0}) return ''", b)
    h.lua("game.tick_paused = false", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: (movement(b)["stats"].get("ghost_recoveries", 0) >= 1
                    or h.status(b)["task"].get("status") in
                    {"succeeded", "partial", "blocked", "missing_materials"}),
           timeout=150, interval=0.2, what="ghost recovery")
    h.lua("game.speed = 60", b)
    result = h.wait_task(task_id, b, timeout=150)
    status = movement(b)
    print("  task:", h.pretty(result))
    print("  movement stats:", h.pretty(status.get("stats")))
    samples = trace(b)
    check("the embedded ghost was detected", status["stats"].get("ghost_recoveries", 0) >= 1,
          h.pretty(status.get("stats")))
    check("recovery resumed the original destination",
          status["stats"].get("recovery_resumes", 0) >= 1
          or (status["stats"].get("path_requests", 0) >= 2
              and result.get("status") == "succeeded"),
          h.pretty(status.get("stats")))
    check("the ghost was not destroyed", bool(h.entity_at("entity-ghost", 8, 0, 1, b))
          or result.get("built_by_agent") == 1,
          h.pretty({"ghosts": h.ghosts(b)}))
    check("the task succeeded after walking out",
          result.get("status") == "succeeded", result.get("reason"))
    check("the ghost recovery used normal walking, never teleportation",
          result.get("step_out_teleports", 0) == 0,
          h.pretty({"step_out": result.get("step_out_count"),
                    "teleports": result.get("step_out_teleports")}))
    print("  samples around recovery:", h.pretty(samples[:6]))


def start_conflicting_belt_intent(b: h.Bridge, owner: str, *, pause: bool = False) -> None:
    for bx in range(10, 30):
        for by in range(0, 9):
            h.create_real_entity("transport-belt", bx + 0.5, by + 0.5, direction=12, b=b)
    h.lua("game.tick_paused = true", b)
    h.agent_lua("a.teleport({x=20.5, y=4.5}) return ''", b)
    h.lua("game.tick_paused = false", b)
    b.call("movement_reset_stats")
    requested = b.call("movement_request", {
        "owner": owner, "purpose": "belt_lifecycle",
        "destination": {"x": 40.5, "y": 4.5}, "arrival_tolerance": 0.8,
    })["result"]
    assert requested.get("ok"), requested

    def recovering() -> bool:
        if movement(b)["movement"].get("state") != "recovering":
            return False
        if pause:
            h.lua("game.tick_paused = true", b)
        return True

    h.wait(recovering, timeout=90, interval=0.05, what="active belt recovery")


def scenario_belt_save_load() -> None:
    print("\nScenario D - save/load during belt recovery restores the original target")
    b = fresh("s18e-belt-save.zip")
    h.lua("game.speed = 1", b)
    b.call("movement_save_on_recovery", {"save": "s18e-mid"})
    start_conflicting_belt_intent(b, "belt-save-test")
    h.wait(lambda: h.lua("rcon.print(game.tick_paused)", b) == "true",
           timeout=90, interval=0.05, what="engine-captured belt recovery save")
    h.stop_server()
    h.start_server("s18e-mid.zip")
    b = h.bridge()
    h.lua("game.speed = 60", b)
    restored = movement(b)
    restored_primary = restored["detail"].get("primary")
    restored_intent = next((intent for intent in restored["detail"].get("intents", [])
                            if intent.get("id") == restored_primary), {})
    destination = (restored_intent.get("original_destination")
                   or restored["movement"].get("destination"))
    check("reloaded recovery retained the original destination",
          destination == {"x": 40.5, "y": 4.5}, h.pretty(destination))
    check("reloaded recovery returned to a routable state",
          restored["movement"].get("state") in {"idle", "path_pending", "following_path",
                                                 "recovering", "arrived"},
          restored["movement"].get("state"))
    h.lua("game.tick_paused = false", b)
    h.wait(lambda: movement(b)["movement"].get("state") in {"arrived", "blocked"},
           timeout=120, interval=0.1, what="post-load original destination")
    final = movement(b)
    check("the original target was reached after save/load",
          final["movement"].get("state") == "arrived",
          h.pretty(final["movement"]))
    check("post-load movement requested fresh paths instead of teleporting",
          final["stats"].get("path_requests", 0) >= 2
          and final["stats"].get("step_out_teleports", 0) == 0,
          h.pretty(final.get("stats")))


def scenario_belt_safety() -> None:
    print("\nScenario E - safety pre-empts an active belt recovery")
    b = fresh("s18f-belt-safety.zip")
    start_conflicting_belt_intent(b, "belt-safety-test")
    h.spawn_attackers(3, 8, b)
    h.wait(lambda: h.status(b)["safety"].get("active") is True,
           timeout=60, interval=0.1, what="safety during belt recovery")
    interrupted = movement(b)
    detail = interrupted["detail"]
    primary = next((intent for intent in detail.get("intents", [])
                    if intent.get("id") == detail.get("primary")), {})
    check("safety created an emergency movement intent", detail.get("emergency") is not None,
          h.pretty(detail))
    check("safety interrupted the ordinary belt recovery", primary.get("state") == "interrupted",
          h.pretty(primary))
    h.clear_enemies(b)
    h.wait(lambda: h.status(b)["safety"].get("active") is False,
           timeout=120, interval=0.2, what="emergency resolved")
    resolved = movement(b)
    check("emergency movement was released after evacuation",
          resolved["detail"].get("emergency") is None,
          h.pretty(resolved["detail"]))


def scenario_stuck() -> None:
    print("\nScenario C - blocked route is reported after bounded retries")
    b = fresh("s18c-stuck.zip")
    b.call("movement_reset_stats")
    # Seal a small area with real walls and place the ghost inside it.
    h.lua(
        "local s = game.surfaces.nauvis\n"
        "for x = -1, 1 do\n"
        "  for y = -1, 1 do\n"
        "    if math.abs(x) == 1 or math.abs(y) == 1 then\n"
        "      s.create_entity{name='stone-wall', position={x=30+x,y=14+y},"
        " force=game.forces.player}\n"
        "    end\n"
        "  end\n"
        "end\n"
        "rcon.print('sealed')", b)
    h.create_ghost("stone-furnace", 30, 14, b=b)
    h.give_items({"stone-furnace": 1}, b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    result = h.wait_task(task_id, b, timeout=180)
    status = movement(b)
    print("  task:", h.pretty(result))
    print("  movement stats:", h.pretty(status.get("stats")))
    check("the unreachable construction site is reported",
          result.get("status") in {"partial", "blocked"}, result.get("reason"))
    check("the movement controller stayed idle rather than looping",
          status["movement"].get("state") == "idle", status["movement"].get("state"))
    check("the attempt count stayed bounded",
          status["stats"].get("path_requests", 0) <= 12, h.pretty(status["stats"]))


def main() -> int:
    scenario_belt()
    scenario_aligned_belt()
    scenario_ghost()
    scenario_belt_save_load()
    scenario_belt_safety()
    scenario_stuck()
    failed = [name for name, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:", failed)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())