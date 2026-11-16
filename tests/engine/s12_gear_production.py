"""Stage 6 D - end-to-end gear production, persistence and interruption."""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402
import stage6_fixture as f  # noqa: E402

RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    f.check(RESULTS, name, condition, detail)


def scenario_a() -> None:
    print("\nScenario A - real ore -> plate -> gear production over ticks")
    b, plan, details = f.prepare("s12a-production.zip")
    before_inventory = h.snapshot(b)["main"]
    tick_before = int(h.lua("rcon.print(game.tick)", b) or 0)
    task_id = f.start_logistics(b)
    result = h.wait_task(task_id, b, timeout=180)
    print("  task:", h.pretty(result)[:900])
    check("the task succeeds only after production", result.get("status") == "succeeded",
          result.get("reason"))
    production = result.get("production") or {}
    check("the task reports actual gear production", production.get("produced") is True
          and production.get("gear_wheels", 0) > 0, h.pretty(production))
    check("ore, coal, plates and the recipe were observed",
          production.get("ore_seen") and production.get("coal_seen")
          and production.get("plate_seen") and production.get("recipe_ok"),
          h.pretty(production))
    gears = f.output_chest_gears(plan, b)
    check("the real output chest contains gear wheels", gears > 0, str(gears))
    after_inventory = h.snapshot(b)["main"]
    usage = dict(f.MODULE_ITEMS)
    for item in (details["physical"]["physical"].get("required_items") or []):
        usage[item["name"]] = usage.get(item["name"], 0) + item["count"]
    paid_exactly = True
    for name, count in usage.items():
        consumed = before_inventory.get(name, 0) - after_inventory.get(name, 0)
        if consumed != count:
            paid_exactly = False
            check(f"construction paid exact {name} cost", False,
                  h.pretty({"before": before_inventory.get(name, 0),
                            "after": after_inventory.get(name, 0),
                            "expected_consumed": count}))
    check("paid construction consumed exactly the live prototype costs",
          paid_exactly, h.pretty({"usage": usage, "before": before_inventory,
                                  "after": after_inventory}))
    tick_after = int(h.lua("rcon.print(game.tick)", b) or 0)
    check("production required real game ticks", tick_after - tick_before > 60,
          f"{tick_before} -> {tick_after}")
    print("  ticks:", tick_before, "->", tick_after)
    print("  gears:", gears)


def scenario_b() -> None:
    print("\nScenario B - save/load during route construction")
    b, plan, details = f.prepare("s12b-save-construction.zip")
    f.set_speed(b, 1)
    task_id = f.start_logistics(b)
    h.wait(lambda: h.status(b)["task"].get("built_by_agent", 0) >= 2
           and h.status(b)["task"].get("remaining", 0) >= 1,
           timeout=120, interval=0.2, what="some ghosts built and work remains")
    before = h.status(b)["task"]
    print("  before save:", h.pretty(before)[:700])
    b = f.save_reload(b, "s12b-mid")
    after = h.status(b)["task"]
    check("the task id survives", after.get("task_id") == task_id, h.pretty(after)[:300])
    check("the task is still running after load", after.get("status") == "running",
          after.get("status"))
    # Progress must survive the save/load: no completed build may be lost. The exact
    # count at the save tick depends on the scheduler's build order, so it is compared
    # with the pre-save status instead of a fixed number.
    check("built progress survives",
          after.get("built_by_agent", 0) >= before.get("built_by_agent", 0)
          and after.get("built_by_agent", 0) > 0,
          h.pretty({"before": before.get("built_by_agent"),
                    "after": after.get("built_by_agent"),
                    "status": after.get("status")}))
    result = h.wait_task(task_id, b, timeout=180)
    print("  final:", h.pretty(result)[:700])
    check("the chain completes after reload", result.get("status") == "succeeded",
          result.get("reason"))
    belts = h.belt_entities(b, radius=80)
    positions = [(round(belt["position"]["x"], 1), round(belt["position"]["y"], 1))
                 for belt in belts]
    check("no belt was duplicated across save/load", len(positions) == len(set(positions)),
          h.pretty(positions))
    check("no ghost remains", not h.ghosts(b), h.pretty(h.ghosts(b)))


def scenario_c() -> None:
    print("\nScenario C - save/load during ordinary-chest material collection")
    b, plan, details = f.prepare("s12c-save-chest.zip", material_chest=True)
    f.set_speed(b, 1)
    task_id = f.start_logistics(b)
    h.wait(lambda: (h.task_debug(b).get("target_kind") == "chest"
                    or h.status(b)["task"].get("items_transferred", 0) > 0)
           and h.status(b)["task"].get("status") == "running",
           timeout=120, interval=0.2, what="chest acquisition")
    before_items = h.snapshot(b)["main"]
    print("  before save inventory:", h.pretty(before_items)[:500])
    b = f.save_reload(b, "s12c-mid")
    after_items = h.snapshot(b)["main"]
    check("transferred materials survive exactly once",
          after_items == before_items, h.pretty({"before": before_items,
                                                 "after": after_items}))
    result = h.wait_task(task_id, b, timeout=180)
    print("  final:", h.pretty(result)[:700])
    check("the chain completes after material-collection reload",
          result.get("status") == "succeeded", result.get("reason"))
    check("no material was duplicated",
          h.snapshot(b)["main"].get("electric-mining-drill", 0) == 0,
          h.pretty(h.snapshot(b)["main"]))
    check("all pending construction materials were fetched in one batch trip",
          result.get("acquisition_trips") == 1
          and result.get("items_transferred", 0) >= 21,
          h.pretty({"trips": result.get("acquisition_trips"),
                    "transferred": result.get("items_transferred")}))


def scenario_d() -> None:
    print("\nScenario D - save/load during production monitoring")
    b, plan, details = f.prepare("s12d-save-monitor.zip")
    f.set_speed(b, 1)
    task_id = f.start_logistics(b)
    h.wait(lambda: h.status(b)["task"].get("phase") == "verifying"
           and h.status(b)["task"].get("status") == "running",
           timeout=150, interval=0.2, what="verification/monitoring phase")
    b = f.save_reload(b, "s12d-mid")
    after = h.status(b)["task"]
    check("task is running in verification after load",
          after.get("status") == "running" and after.get("phase") == "verifying",
          h.pretty(after)[:400])
    result = h.wait_task(task_id, b, timeout=180)
    print("  final:", h.pretty(result)[:700])
    check("production is observed after the monitoring reload",
          result.get("status") == "succeeded" and result["production"]["produced"] is True,
          result.get("reason"))
    check("no duplicate real entities exist",
          len(h.entities_named(["electric-mining-drill"], b)) == 1
          and len(h.entities_named(["stone-furnace"], b)) == 1
          and len(h.entities_named(["assembling-machine-1"], b)) == 1,
          h.pretty(h.real_counts(b)))


async def scenario_e() -> None:
    print("\nScenario E - Safety Controller pre-emption and explicit resume")
    b, plan, details = f.prepare("s12e-safety.zip")
    f.set_speed(b, 5)
    runner = h.TaskRunner(b, poll_interval=1.0)
    execute = asyncio.create_task(runner.execute(
        {"task": "build_logistics", "goal_item": "iron-gear-wheel"}, timeout=300))
    await asyncio.to_thread(
        h.wait, lambda: h.status(b)["task"].get("built_by_agent", 0) >= 1,
        timeout=120, what="first logistics unit built")
    await asyncio.to_thread(h.spawn_attackers, 3, 8.0, b)
    result = await asyncio.wait_for(execute, timeout=180)
    print("  runner:", h.pretty(result)[:600])
    task = h.status(b)["task"]
    check("the runner returns interrupted_by_safety",
          result.get("status") == "interrupted_by_safety", result.get("status"))
    check("the logistics task pauses for safety",
          task.get("status") == "paused" and task.get("reason") == "safety",
          h.pretty(task)[:400])
    await asyncio.to_thread(h.clear_enemies, b)
    await asyncio.to_thread(h.wait, lambda: not h.status(b)["safety"]["active"],
                            timeout=180, what="safety resolved")
    await asyncio.sleep(3)
    paused = h.status(b)["task"]
    check("the task does not resume automatically", paused.get("status") == "paused",
          h.pretty(paused)[:300])
    b.call("task_resume", {"task_id": result["task_id"]})
    f.set_speed(b, 60)
    final = await asyncio.to_thread(h.wait_task, result["task_id"], b, timeout=180)
    print("  final:", h.pretty(final)[:800])
    check("explicit resume completes the physical chain",
          final.get("status") == "succeeded", final.get("reason"))
    check("the resume did not duplicate modules",
          len(h.entities_named(["electric-mining-drill"], b)) == 1
          and len(h.entities_named(["stone-furnace"], b)) == 1
          and len(h.entities_named(["assembling-machine-1"], b)) == 1,
          h.pretty(h.real_counts(b)))


def scenario_f() -> None:
    print("\nScenario F - death, recovery and explicit resume")
    b, plan, details = f.prepare("s12f-death.zip")
    f.set_speed(b, 5)
    task_id = f.start_logistics(b)
    h.wait(lambda: h.status(b)["task"].get("built_by_agent", 0) >= 1,
           timeout=120, what="first build before death")
    h.agent_lua("a.die() return ''", b)
    h.wait(lambda: h.status(b)["lifecycle"]["status"] != "alive", timeout=30,
           what="death registered")
    paused = h.status(b)["task"]
    check("the logistics task pauses with reason death",
          paused.get("status") == "paused" and paused.get("reason") == "death",
          h.pretty(paused)[:400])
    h.wait(lambda: h.status(b)["lifecycle"]["status"] == "alive", timeout=120,
           what="respawn")
    check("the task remains paused until the LLM resumes it",
          h.status(b)["task"].get("status") == "paused",
          h.pretty(h.status(b)["task"])[:300])
    b.call("task_resume", {"task_id": task_id})
    f.set_speed(b, 60)
    final = h.wait_task(task_id, b, timeout=180)
    print("  final:", h.pretty(final)[:800])
    check("resume after death completes the chain",
          final.get("status") == "succeeded", final.get("reason"))
    check("no module was duplicated after death recovery",
          len(h.entities_named(["electric-mining-drill"], b)) == 1
          and len(h.entities_named(["stone-furnace"], b)) == 1
          and len(h.entities_named(["assembling-machine-1"], b)) == 1,
          h.pretty(h.real_counts(b)))


def scenario_g() -> None:
    print("\nScenario G - empty coal chest is missing fuel, never fabricated")
    b, plan, details = f.prepare("s12g-no-fuel.zip")
    chest_unit = details["coal_chest"]["unit"]
    removed = h.remove_chest_items(chest_unit, "coal", 1000, b)
    print("  withdrawn coal:", removed)
    task_id = f.start_logistics(b)
    result = h.wait_task(task_id, b, timeout=180)
    print("  task:", h.pretty(result)[:900])
    check("the demo does not succeed without fuel",
          result.get("status") == "blocked", result.get("status"))
    check("the terminal reason names the missing fuel source",
          "missing_fuel_source" in str(result.get("reason"))
          or "fuel" in str(result.get("reason")),
          result.get("reason"))
    check("no gear was fabricated", (result.get("production") or {})
          .get("produced") is not True, h.pretty(result.get("production")))
    check("the coal chest remains empty", (h.chest_contents(chest_unit, b) or {})
          .get("coal", 0) == 0, h.pretty(h.chest_contents(chest_unit, b)))


def scenario_h() -> None:
    print("\nScenario H - player blocks a route while the agent works")
    b, plan, details = f.prepare("s12h-player.zip")
    f.set_speed(b, 1)
    task_id = f.start_logistics(b)
    h.wait(lambda: h.status(b)["task"].get("built_by_agent", 0) >= 1
           and h.status(b)["task"].get("remaining", 0) >= 1,
           timeout=120, interval=0.2, what="agent building")
    # A real player-owned building on the not-yet-built fuel corridor removes that ghost
    # and makes the planned route invalid. The agent must not silently claim success.
    physical = h.logistics_plan_create(plan["id"], b)["physical"]
    route_keys = set()
    for connection in physical.get("connections") or []:
        for step in connection.get("steps") or []:
            tile = step.get("tile") or {}
            if "x" in tile and "y" in tile:
                route_keys.add((tile["x"] + 0.5, tile["y"] + 0.5))
    fuel_route = (physical.get("fuel") or {}).get("route") or {}
    for tile in fuel_route.get("path") or []:
        if "x" in tile and "y" in tile:
            route_keys.add((tile["x"] + 0.5, tile["y"] + 0.5))
    ghosts = h.ghosts(b, radius=80)
    target_tile = None
    target_unit = None
    for ghost in ghosts:
        point = (round(ghost["position"]["x"], 1), round(ghost["position"]["y"], 1))
        if point in route_keys:
            target_tile = {"x": int(point[0] - 0.5), "y": int(point[1] - 0.5)}
            target_unit = ghost["unit"]
            break
    if target_tile is None and ghosts:
        # The reach-aware scheduler builds zone by zone, so every route ghost may
        # already be complete while module ghosts remain. Blocking any remaining
        # required ghost still invalidates the planned construction; a player-built
        # object is never counted as the agent's build.
        for ghost in ghosts:
            if ghost["name"] != "wooden-chest":
                point = (round(ghost["position"]["x"], 1), round(ghost["position"]["y"], 1))
                target_tile = {"x": int(point[0] - 0.5), "y": int(point[1] - 0.5)}
                target_unit = ghost["unit"]
                break
    assert target_tile is not None, "no remaining ghost to replace"
    h.lua(f"""
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{type="entity-ghost"}}) do
      if e.unit_number == {target_unit} then e.destroy() return end
    end
    """, b)
    placed = h.create_chest(target_tile["x"] + 0.5, target_tile["y"] + 0.5,
                            {"wood": 1}, b)
    print("  player placed:", h.pretty(placed))
    f.set_speed(b, 60)
    result = h.wait_task(task_id, b, timeout=180)
    print("  task:", h.pretty(result)[:900])
    check("the task does not report success after a player route conflict",
          result.get("status") != "succeeded", result.get("status"))
    check("the player building is preserved",
          bool(h.entity_at("wooden-chest", target_tile["x"] + 0.5,
                           target_tile["y"] + 0.5, 2, b)),
          h.pretty(placed))


def scenario_i() -> None:
    print("\nScenario I - a distant real player does not block the whole chain")
    b, plan, details = f.prepare("s12i-distant-player.zip")
    anchor = details["anchor"]
    player = h.create_player_character(anchor["x"] + 1.5, anchor["y"] - 12.5, b)
    print("  player:", h.pretty(player))
    task_id = f.start_logistics(b)
    result = h.wait_task(task_id, b, timeout=180)
    print("  final:", h.pretty(result)[:800])
    check("a player inside the scan area but outside the chain does not block planning",
          result.get("status") == "succeeded", result.get("reason"))
    check("the distant player character is preserved",
          bool(h.entity_at("character", player["position"]["x"],
                           player["position"]["y"], 2, b)),
          h.pretty(player))
    h.remove_entity(player["unit"], b)


def scenario_j() -> None:
    print("\nScenario J - step out of a pending module ghost")
    b, plan, details = f.prepare("s12j-stepout.zip")
    f.set_speed(b, 1)
    task_id = f.start_logistics(b)
    h.wait(lambda: any(
        entry["name"] in {"stone-furnace", "electric-mining-drill",
                          "assembling-machine-1"}
        and entry["status"] == "pending"
        for entry in (h.task_entries(b).get("entries") or [])),
        timeout=120, interval=0.2, what="a pending module ghost")
    entries = h.task_entries(b).get("entries") or []
    target = next(entry for entry in entries
                  if entry["name"] in {"stone-furnace", "electric-mining-drill",
                                       "assembling-machine-1"}
                  and entry["status"] == "pending")
    # Test scaffolding: place the character inside the agent-owned ghost, then let the
    # executor recover. This is not a production movement mechanism.
    h.lua("game.tick_paused = true", b)
    h.agent_lua(
        f"a.teleport({{x={target['position']['x']}, y={target['position']['y']}}}) return ''",
        b)
    h.lua("game.tick_paused = false", b)
    h.wait(lambda: h.status(b)["task"].get("status") in
           {"succeeded", "failed", "blocked", "partial"},
           timeout=180, interval=0.2, what="task terminal after ghost teleport")
    f.set_speed(b, 60)
    result = h.wait_task(task_id, b, timeout=180)
    print("  final:", h.pretty(result)[:900])
    check("the task recovers and completes after being inside a ghost",
          result.get("status") == "succeeded", result.get("reason"))
    # Stage 7.1 only steps out of a ghost on an actual conflict; while a valid route
    # exists the character simply walks out. The observable contract is that the
    # character ends outside the built module footprint and the module exists in
    # place, with no teleport and no destroyed ghost.
    inside_built = h.lua(f"""
    local a = remote.call('factorio_autonomous_engineer','get_agent')
    local e = a.surface.find_entity('{target['name']}',
      {{x={target['position']['x']}, y={target['position']['y']}}})
    if not e then rcon.print('missing') return end
    local box = e.bounding_box
    rcon.print(tostring(a.position.x > box.left_top.x and a.position.x < box.right_bottom.x
      and a.position.y > box.left_top.y and a.position.y < box.right_bottom.y))
    """, b)
    check("the character left the ghost footprint by ordinary walking",
          inside_built == "false",
          h.pretty({"inside_built_module": inside_built, "ghost": target["position"],
                    "agent": h.status(b)["lifecycle"]["position"]}))
    check("the ghost was revived in place, not destroyed or recreated",
          bool(h.entity_at(target["name"], target["position"]["x"],
                           target["position"]["y"], 2, b)),
          h.pretty(target))
    check("the ghost recovery used normal walking rather than the emergency teleport",
          result.get("step_out_teleports", 0) == 0,
          h.pretty(result.get("step_out_teleports")))


def scenario_k() -> None:
    print("\nScenario K - step off a working belt before construction")
    h.load_scenario_save("s12k-belt.zip")
    b = h.bridge()
    h.lua("game.speed = 60", b)
    h.research_all(b)
    h.clear_main_inventory(b)
    h.clear_test_area(-20, -20, 40, 20, b, keep_resources=True)
    h.set_home({"x": 0.5, "y": 0.5}, b)
    belt = h.create_real_entity("transport-belt", 10.5, 0.5, direction=4, b=b)
    ghost = h.create_ghost("transport-belt", 10.5, 4.5, direction=4, b=b)
    h.give_items({"transport-belt": 1}, b)
    h.lua("game.tick_paused = true", b)
    h.agent_lua(
        f"a.teleport({{x={belt['position']['x']}, y={belt['position']['y']}}}) return ''",
        b)
    h.lua("game.tick_paused = false", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    result = h.wait_task(task_id, b, timeout=90)
    print("  final:", h.pretty(result)[:900])
    check("the construction task succeeds after starting on a belt",
          result.get("status") == "succeeded", result.get("reason"))
    # Starting on a belt is not by itself a recovery reason, but when the route
    # conflicts with the belt the controller must step off by ordinary walking.
    check("the character walked off the working belt",
          result.get("belt_step_offs", 0) >= 1,
          h.pretty({"belt_step_offs": result.get("belt_step_offs"),
                    "teleports": result.get("step_out_teleports")}))
    check("the belt recovery used normal walking",
          result.get("step_out_teleports", 0) == 0,
          h.pretty(result.get("step_out_teleports")))
    check("the requested belt ghost was built",
          bool(h.entity_at("transport-belt", ghost["position"]["x"],
                           ghost["position"]["y"], 2, b)), h.pretty(ghost))
    check("the working belt was preserved",
          bool(h.entity_at("transport-belt", belt["position"]["x"],
                           belt["position"]["y"], 1, b)), h.pretty(belt))


def scenario_l() -> None:
    print("\nScenario L - resume while standing inside a pending module ghost")
    # Regression for the Stage 7.1 recovery storm: after a death/respawn the character
    # can stand inside a planned module footprint. The executor used to cancel the
    # controller's step-out and re-target the same inside-footprint approach point,
    # producing thousands of ghost recoveries/path requests that only ended at the task
    # deadline. The step-out must be delegated to the movement controller and awaited.
    b, plan, details = f.prepare("s12l-inside-ghost.zip")
    f.set_speed(b, 1)
    task_id = f.start_logistics(b)
    module_names = {"stone-furnace", "electric-mining-drill", "assembling-machine-1"}

    def pending_module():
        for entry in h.task_entries(b).get("entries") or []:
            if entry["name"] in module_names and entry["status"] in {"pending", "building"}:
                return entry
        return None

    h.wait(lambda: h.status(b)["task"].get("built_by_agent", 0) >= 1
           and pending_module() is not None,
           timeout=180, interval=0.2, what="a build and a pending module ghost")
    target = pending_module()
    h.agent_lua("a.die() return ''", b)
    h.wait(lambda: h.status(b)["lifecycle"]["status"] == "alive", timeout=180,
           what="respawn")
    still_pending = any(
        entry["key"] == target["key"] and entry["status"] in {"pending", "building"}
        for entry in h.task_entries(b).get("entries") or [])
    check("the module ghost is still pending after the death", still_pending,
          h.pretty(target))
    if not still_pending:
        return
    # Test scaffolding: reproduce the respawn-inside-the-plan geometry deterministically.
    h.lua("game.tick_paused = true", b)
    h.agent_lua(
        f"a.teleport({{x={target['position']['x']}, y={target['position']['y']}}}) return ''",
        b)
    h.lua("game.tick_paused = false", b)
    baseline = b.call("movement_status")["result"]["stats"]
    b.call("task_resume", {"task_id": task_id})
    f.set_speed(b, 60)
    result = h.wait_task(task_id, b, timeout=180)
    stats = b.call("movement_status")["result"]["stats"]
    delta = {name: stats.get(name, 0) - baseline.get(name, 0) for name in (
        "ghost_recoveries", "position_recoveries", "belt_recoveries",
        "path_requests", "no_path")}
    print("  final:", h.pretty(result)[:700])
    print("  movement delta:", h.pretty(delta))
    check("the task completes after resuming inside a module ghost",
          result.get("status") == "succeeded", result.get("reason"))
    check("the ghost recovery was bounded rather than a request storm",
          delta["ghost_recoveries"] <= 8 and delta["position_recoveries"] <= 8
          and delta["path_requests"] <= 60,
          h.pretty(delta))
    check("no path request was retried without bound",
          delta["no_path"] <= 6, h.pretty(delta))


async def main() -> int:
    scenario_a()
    scenario_b()
    scenario_c()
    scenario_d()
    await scenario_e()
    scenario_f()
    scenario_g()
    scenario_h()
    scenario_i()
    scenario_j()
    scenario_k()
    scenario_l()
    failed = [name for name, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:", failed)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
