"""Construction scenarios A-G: ghost placement, payment, chests, clearing, collaboration."""
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
    h.load_scenario_save(save)
    b = h.bridge()
    h.clear_main_inventory(b)
    return b


def clear_build_area(b: h.Bridge) -> None:
    h.clear_test_area(-24, -40, 80, 42, b, keep_resources=True)


def real_count(b: h.Bridge, names: list[str]) -> list[dict]:
    return h.entities_named(names, b)


def scenario_a(b: h.Bridge) -> None:
    print("\nScenario A — agent places a plan of ghosts")
    clear_build_area(b)
    before = h.snapshot(b)["main"]
    print("  before inventory:", h.pretty(before))
    placed = h.place_plan("test_basic", b)
    print("  placement:", h.pretty(placed))
    ghosts = h.ghosts(b)
    after = h.snapshot(b)["main"]
    real = real_count(b, ["stone-furnace", "wooden-chest", "transport-belt"])
    check("plan reported success", placed.get("success") is True, h.pretty(placed))
    check("three ghosts exist", len(ghosts) == 3, str([g["name"] for g in ghosts]))
    check("no real buildings exist", len(real) == 0, h.pretty(real))
    check("inventory unchanged", after == before, f"{before} -> {after}")
    check("every ghost has an inner name", all(g.get("name") for g in ghosts))


def scenario_b(b: h.Bridge) -> None:
    print("\nScenario B — build from the agent's own materials")
    clear_build_area(b)
    h.give_items({"stone-furnace": 7, "wooden-chest": 5, "transport-belt": 4}, b)
    before = h.snapshot(b)["main"]
    print("  inventory before:", h.pretty(before))
    placed = h.place_plan("test_basic", b)
    check("plan placement", placed.get("success") is True)
    start = h.status(b)["lifecycle"]["position"]
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    result = h.wait_task(task_id, b, timeout=240)
    after = h.snapshot(b)["main"]
    real = real_count(b, ["stone-furnace", "wooden-chest", "transport-belt"])
    final = h.status(b)["lifecycle"]["position"]
    print("  result:", h.pretty(result))
    print("  inventory after:", h.pretty(after))
    print("  real entities:", h.pretty(real))
    print("  agent moved:", start, "->", final)
    check("task succeeded", result.get("status") == "succeeded", result.get("reason"))
    check("three real buildings", len(real) == 3, h.pretty(real))
    check("no ghost remains", len(h.ghosts(b)) == 0)
    check("exactly one of each building", len({e["name"] for e in real}) == 3
          and all(len([x for x in real if x["name"] == n]) == 1
                  for n in ("stone-furnace", "wooden-chest", "transport-belt")))
    expected = {"stone-furnace": 6, "wooden-chest": 4, "transport-belt": 3}
    check("materials deducted exactly once", after == expected, f"{after} != {expected}")
    distance_moved = ((final["x"] - start["x"]) ** 2 + (final["y"] - start["y"]) ** 2) ** 0.5
    check("agent physically walked to the work area", distance_moved > 4,
          f"moved {distance_moved:.2f} tiles to {final}")


def scenario_c(b: h.Bridge) -> None:
    print("\nScenario C — ordinary chest provides materials")
    clear_build_area(b)
    h.place_plan("single_furnace", b)
    ghost = h.ghosts(b)[0]
    x, y = ghost["position"]["x"], ghost["position"]["y"]
    chest = h.create_chest(x + 3, y + 3, {"stone-furnace": 1}, b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    result = h.wait_task(task_id, b, timeout=180)
    contents = h.chest_contents(chest["unit"], b)
    entity = h.entity_at("stone-furnace", x, y, 3, b)
    print("  result:", h.pretty(result))
    print("  chest after:", h.pretty(contents), "| inventory:", h.pretty(h.snapshot(b)["main"]))
    check("task succeeded", result.get("status") == "succeeded", result.get("reason"))
    check("materials were physically fetched", result.get("items_transferred") == 1)
    check("chest lost exactly the needed item", contents == {}, h.pretty(contents))
    check("furnace was built and ghost consumed", bool(entity) and len(h.ghosts(b)) == 0)

    print("\nScenario C2 — partial chest supply across two ghosts")
    b = fresh("s5c2-chest-partial.zip")
    clear_build_area(b)
    h.create_ghost("stone-furnace", 42, 8, b=b)
    h.create_ghost("stone-furnace", 49, 8, b=b)
    chest = h.create_chest(44, 12, {"stone-furnace": 1}, b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    result = h.wait_task(task_id, b, timeout=180)
    print("  result:", h.pretty(result))
    check("partial result is explicit", result.get("status") == "partial"
          and result.get("reason") == "missing_materials", h.pretty(result))
    check("one object was built", result.get("built_by_agent") == 1)
    check("one ghost remains", len(h.ghosts(b)) == 1)
    check("chest supplied only one item", h.chest_contents(chest["unit"], b) == {})

    print("\nScenario C3 — full inventory cannot receive chest items")
    b = fresh("s5c3-chest-full.zip")
    clear_build_area(b)
    h.place_plan("single_furnace", b)
    ghost = h.ghosts(b)[0]
    chest = h.create_chest(ghost["position"]["x"] + 3, ghost["position"]["y"] + 3,
                           {"stone-furnace": 1}, b)
    filled = h.fill_main_inventory("iron-plate", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    result = h.wait_task(task_id, b, timeout=90)
    print("  fill:", h.pretty(filled), "| result:", h.pretty(result))
    check("inventory-full is reported", result.get("status") == "blocked"
          and result.get("reason") == "inventory_full", h.pretty(result))
    check("ghost remains", len(h.ghosts(b)) == 1)
    check("chest is untouched", h.chest_contents(chest["unit"], b)
          == [{"name": "stone-furnace", "quality": "normal", "count": 1}],
          h.pretty(h.chest_contents(chest["unit"], b)))
    check("nothing was built", not h.entity_at("stone-furnace", ghost["position"]["x"],
                                               ghost["position"]["y"], 3, b))


def scenario_d(b: h.Bridge) -> None:
    print("\nScenario D — no materials anywhere")
    clear_build_area(b)
    placed = h.place_plan("single_furnace", b)
    check("plan placed", placed.get("success") is True)
    ghost = h.ghosts(b)[0]
    x, y = ghost["position"]["x"], ghost["position"]["y"]
    before = h.snapshot(b)["main"]
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    result = h.wait_task(task_id, b, timeout=90)
    print("  result:", h.pretty(result))
    check("missing materials is the terminal status", result.get("status") == "missing_materials",
          result.get("reason"))
    check("ghost remains", len(h.ghosts(b)) == 1)
    check("no real building", not h.entity_at("stone-furnace", x, y, 3, b))
    check("inventory unchanged", h.snapshot(b)["main"] == before)
    missing = result.get("missing_materials", {})
    check("missing count is reported", missing.get("stone-furnace") == 1,
          h.pretty(missing))


def scenario_e(b: h.Bridge) -> None:
    print("\nScenario E — player blueprint with one already built object")
    clear_build_area(b)
    h.create_ghost("transport-belt", 42, 8, direction=4, b=b)
    g2 = h.create_ghost("transport-belt", 48, 8, direction=4, b=b)
    h.create_ghost("transport-belt", 50, 8, direction=4, b=b)
    built = h.build_ghost_as_player(g2["unit"], b)
    print("  player built:", h.pretty(built))
    h.give_items({"transport-belt": 2}, b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    result = h.wait_task(task_id, b, timeout=180)
    real = h.entities_named(["transport-belt"], b)
    print("  result:", h.pretty(result))
    print("  real:", h.pretty(real))
    check("task succeeded", result.get("status") == "succeeded", result.get("reason"))
    check("agent built the two remaining ghosts", result.get("built_by_agent") == 2)
    check("exactly three real belts exist", len(real) == 3, h.pretty(real))
    check("no duplicate at the player-built position", len(
        [e for e in real if abs(e["position"]["x"] - built["position"]["x"]) < 1.5
         and abs(e["position"]["y"] - built["position"]["y"]) < 1.5]) == 1)
    check("all ghosts resolved", len(h.ghosts(b)) == 0)


def scenario_f(b: h.Bridge) -> None:
    print("\nScenario F — player changes the blueprint while the agent works")
    clear_build_area(b)
    g1 = h.create_ghost("transport-belt", 42, 8, direction=4, b=b)
    g2 = h.create_ghost("transport-belt", 48, 8, direction=4, b=b)
    g3 = h.create_ghost("transport-belt", 52, 8, direction=4, b=b)
    h.give_items({"transport-belt": 3, "stone-furnace": 1}, b)
    h.lua("game.speed = 5", b)
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    start_x = h.status(b)["lifecycle"]["position"]["x"]
    h.wait(lambda: (h.status(b)["task"].get("phase") in {"moving", "pathing"})
           and h.status(b)["lifecycle"]["position"]["x"] > start_x + 4,
           timeout=60, what="agent moving toward the first ghost")
    print("  agent position at intervention:",
          h.status(b)["lifecycle"]["position"])
    check("cancel one ghost", h.cancel_ghost(g1["unit"], b))
    built = h.build_ghost_as_player(g2["unit"], b)
    print("  player built second ghost:", h.pretty(built))
    changed = h.create_ghost("stone-furnace", 52, 8, b=b)
    print("  replacement ghost:", h.pretty(changed))
    check("cancel third ghost for a plan change", h.cancel_ghost(g3["unit"], b))
    h.lua("game.speed = 60", b)
    result = h.wait_task(task_id, b, timeout=240)
    real_belts = h.entities_named(["transport-belt"], b)
    real_furnaces = h.entities_named(["stone-furnace"], b)
    print("  result:", h.pretty(result))
    print("  belts:", h.pretty(real_belts), "| furnaces:", h.pretty(real_furnaces))
    check("task succeeds after adapting", result.get("status") == "succeeded", result.get("reason"))
    check("cancelled ghost was not restored", not h.entity_at(
        "transport-belt", 42, 8, 2, b))
    check("player-built object is not duplicated", len(real_belts) == 1, h.pretty(real_belts))
    check("modified blueprint was built as the new entity", len(real_furnaces) == 1,
          h.pretty(real_furnaces))
    check("no pending ghosts remain", len(h.ghosts(b)) == 0)
    check("only the actually built object was paid for",
          h.snapshot(b)["main"].get("transport-belt", 0) == 3
          and h.snapshot(b)["main"].get("stone-furnace", 0) == 0,
          h.pretty(h.snapshot(b)["main"]))


def scenario_g(b: h.Bridge) -> None:
    print("\nScenario G — clear a tree and a rock, then build")
    clear_build_area(b)
    h.create_natural("tree-01", 42, 8, b)
    h.create_natural("big-sand-rock", 48, 8, b)
    h.create_ghost("transport-belt", 42, 8, direction=4, b=b)
    h.create_ghost("transport-belt", 48, 8, direction=4, b=b)
    chest = h.create_real_entity("wooden-chest", 44, 12, b=b)
    furnace = h.create_real_entity("stone-furnace", 49, 12, b=b)
    h.give_items({"transport-belt": 2}, b)
    before = h.snapshot(b)["main"]
    task_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    result = h.wait_task(task_id, b, timeout=240)
    after = h.snapshot(b)["main"]
    print("  result:", h.pretty(result))
    print("  inventory:", h.pretty(after))
    check("task succeeded", result.get("status") == "succeeded", result.get("reason"))
    check("tree and rock were cleared", result.get("obstacles_cleared", {}).get("tree-01") == 1
          and result.get("obstacles_cleared", {}).get("big-sand-rock") == 1,
          h.pretty(result.get("obstacles_cleared")))
    check("ordinary resources were collected",
          after.get("wood", 0) > before.get("wood", 0)
          and after.get("stone", 0) > before.get("stone", 0), h.pretty(after))
    check("both belts were built", len(h.entities_named(["transport-belt"], b)) == 2)
    check("nearby chest was not destroyed", bool(h.entity_at("wooden-chest", 44, 12, 2, b)))
    check("nearby real furnace was not destroyed",
          h.entity_at("stone-furnace", 49, 12, 2, b) is not None)
    check("nearby entities are still owned by the player",
          bool(chest) and bool(furnace))


def main() -> int:
    b = fresh("s5a-plan.zip")
    scenario_a(b)
    b = fresh("s5b-build.zip")
    scenario_b(b)
    b = fresh("s5c-chest.zip")
    scenario_c(b)
    b = fresh("s5d-missing.zip")
    scenario_d(b)
    b = fresh("s5e-blueprint.zip")
    scenario_e(b)
    b = fresh("s5f-change.zip")
    scenario_f(b)
    b = fresh("s5g-clearing.zip")
    scenario_g(b)
    failed = [name for name, ok, _ in RESULTS if not ok]
    print("\nSUMMARY", h.pretty({"checks": len(RESULTS), "failed": failed}))
    print("RESULT", "PASS" if not failed else "FAIL")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
