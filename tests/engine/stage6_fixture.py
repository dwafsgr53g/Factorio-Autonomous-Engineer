"""Shared Stage-6 engine fixtures.

These helpers create *scenario prerequisites* only: a disposable save, all research,
an isolated flat area, a real solar-powered electric network and an ordinary chest
containing coal. They never place modules, belts, inserters or poles for the agent's
production chain. The agent builds the chain through ``execute_task(task="build_logistics")``
with the same paid construction path used in normal gameplay.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402

MODULE_ITEMS = {
    "electric-mining-drill": 1,
    "stone-furnace": 1,
    "assembling-machine-1": 1,
}


def check(results: list[tuple[str, bool, str]], name: str, condition: bool,
          detail: str = "") -> None:
    results.append((name, bool(condition), detail))
    print(f"  {'PASS' if condition else 'FAIL'} {name}" + (f" :: {detail}" if detail else ""))


def prepare(save: str, *, coal: bool = True, power: bool = True,
            materials: bool = True, coal_offset: tuple[int, int] = (2, 0),
            material_chest: bool = False,
            block_route: bool = False) -> tuple[h.Bridge, dict, dict]:
    """Create a disposable Stage-6 world and return (bridge, plan, fixture_details)."""
    h.load_scenario_save(save)
    b = h.bridge()
    h.research_all(b)
    h.lua("game.surfaces.nauvis.always_day = true", b)
    h.clear_main_inventory(b)
    anchor = h.find_resource_anchor("iron-ore", 3, 3, 9, 240, b)
    assert anchor, "baseline has no suitable iron patch"
    h.clear_test_area(anchor["x"] - 26, anchor["y"] - 26,
                      anchor["x"] + 40, anchor["y"] + 26, b, keep_resources=True)
    h.set_home({"x": anchor["x"] + 1.5, "y": anchor["y"] + 1.5}, b)
    plan_result = h.layout_chain_plan(b=b)
    assert plan_result.get("ok") is True, plan_result
    plan = plan_result["plan"]
    furnace = next(module for module in plan["modules"]
                   if module["category"] == "smelting")
    fuel_port = next(port for port in furnace["ports"] if port["id"] == "fuel_input")
    pickup_tile = {
        "x": int(fuel_port["position"]["x"] // 1),
        "y": int(furnace["bounds"][0]["y"]) - 2,
    }
    chest_position = {
        "x": pickup_tile["x"] + coal_offset[0] + 0.5,
        "y": pickup_tile["y"] + coal_offset[1] + 0.5,
    }
    details: dict = {"anchor": anchor, "plan": plan, "pickup_tile": pickup_tile,
                     "chest_position": chest_position}
    if coal:
        chest = h.create_chest(chest_position["x"], chest_position["y"],
                               {"coal": 100}, b)
        details["coal_chest"] = chest
    left = min(module["bounds"][0]["x"] for module in plan["modules"])
    top = min(module["bounds"][0]["y"] for module in plan["modules"])
    pole_x = left - 6.5
    pole_y = top - 8.5
    details["power_pole_position"] = {"x": pole_x, "y": pole_y}
    if power:
        details["power"] = h.create_solar_fixture(pole_x, pole_y, b)
        assert details["power"].get("ok") is not False, details["power"]
        time.sleep(3)
    if block_route:
        mining = next(module for module in plan["modules"]
                      if module["category"] == "mining")
        belt_row = int(plan["logistics"]["belt_row"] // 1)
        source_tile = {"x": int(mining["bounds"][1]["x"]), "y": belt_row}
        h.create_chest(source_tile["x"] + 0.5, source_tile["y"] + 0.5,
                       {"wood": 1}, b)
        details["route_obstacle"] = source_tile
    physical = h.logistics_plan_create(plan["id"], b)
    details["physical"] = physical
    if materials:
        required = dict(MODULE_ITEMS)
        # A complete linear-chain material set, independent of whether the first
        # physical prerequisite check succeeded. This lets a later run proceed after the
        # player supplies the missing power/fuel infrastructure.
        required.update({"inserter": 8, "medium-electric-pole": 6,
                         "transport-belt": 12, "wooden-chest": 2})
        if physical.get("ok"):
            for item in physical["physical"]["required_items"]:
                required[item["name"]] = max(required.get(item["name"], 0), item["count"])
        details["materials"] = required
        if material_chest:
            # Put the construction materials in an ordinary chest near home. The executor
            # must walk to it and remove the missing items through the normal chest path.
            h.create_chest(anchor["x"] + 1.5, anchor["y"] + 6.5, required, b)
        else:
            h.give_items(required, b)
    return b, plan, details


def save_reload(b: h.Bridge, name: str) -> h.Bridge:
    h.lua("game.tick_paused = true", b)
    print("  save:", repr(h.save_as(name, b)))
    h.stop_server()
    h.start_server(name + ".zip")
    b = h.bridge()
    h.lua("game.tick_paused = false", b)
    return b


def start_logistics(b: h.Bridge, goal: str = "iron-gear-wheel") -> str:
    result = h.task_start({"task": "build_logistics", "goal_item": goal}, b)
    return result["task_id"]


def output_chest_gears(plan: dict, b: h.Bridge) -> int:
    """Read the real output chest from the product edge geometry.

    The physical plan (not this test) decides where the chest goes. The fixture only
    observes the resulting world.
    """
    physical = h.logistics_plan_create(plan["id"], b)
    if not physical.get("ok"):
        return 0
    chest_tile = physical["physical"]["output"]["chest"]["tile"]
    code = f"""
    local out = 0
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{
        area={{{{x={chest_tile['x']},y={chest_tile['y']}}},
               {{x={chest_tile['x']}+1,y={chest_tile['y']}+1}}}},
        name="wooden-chest"}}) do
      local inv = e.get_inventory(defines.inventory.chest)
      out = inv and inv.get_item_count{{name="iron-gear-wheel", quality="normal"}} or 0
    end
    rcon.print(out)
    """
    try:
        return int(h.lua(code, b) or 0)
    except ValueError:
        return 0
