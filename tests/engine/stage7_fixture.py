"""Shared Stage-7 engine fixtures.

Scenario prerequisites only: isolated test area, all research, a legitimate
solar-powered network and an ordinary coal chest. The agent builds every module,
belt, splitter, underground-belt pair, inserter, pole and the output chest through
the paid construction executor.
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402

GAME_SPEED = float(os.environ.get("FACTORIO_GAME_SPEED", "60"))

MODULE_ITEMS = {
    "electric-mining-drill": 1,
    "stone-furnace": 2,
    "assembling-machine-1": 2,
}

LOGISTICS_ITEMS = {
    "inserter": 30,
    "medium-electric-pole": 12,
    "splitter": 8,
    "transport-belt": 100,
    "underground-belt": 8,
    "wooden-chest": 3,
}

CONSTRUCTION_ITEMS = {**MODULE_ITEMS, **LOGISTICS_ITEMS}


def set_speed(b: h.Bridge, speed: float) -> None:
    h.lua(f"game.speed = {speed}", b)


def check(results: list[tuple[str, bool, str]], name: str, condition: bool,
          detail: str = "") -> None:
    results.append((name, bool(condition), detail))
    print(f"  {'PASS' if condition else 'FAIL'} {name}" + (f" :: {detail}" if detail else ""))


def prepare(save: str, *, power: bool = True, coal: bool = True,
            materials: bool = True, material_chest: bool = False,
            apply_modules: bool = True,
            create_physical: bool = True,
            baseline: str = "s7-baseline.zip") -> tuple[h.Bridge, dict, dict | None, dict]:
    """Create a disposable Stage-7 world and return (bridge, plan, physical, details)."""
    h.load_scenario_save(save, baseline=baseline)
    b = h.bridge()
    set_speed(b, GAME_SPEED)
    h.research_all(b)
    h.lua("game.surfaces.nauvis.always_day = true", b)
    h.clear_main_inventory(b)
    anchor = h.find_resource_anchor("iron-ore", 3, 3, 9, 240, b)
    assert anchor, "baseline has no suitable iron patch"
    h.clear_test_area(anchor["x"] - 34, anchor["y"] - 34,
                      anchor["x"] + 64, anchor["y"] + 44, b, keep_resources=True)
    h.set_home({"x": anchor["x"] + 1.5, "y": anchor["y"] + 1.5}, b)
    details: dict = {"anchor": anchor}
    if power:
        power_fixture = h.create_solar_fixture(anchor["x"] - 12.5,
                                               anchor["y"] - 10.5, b)
        assert power_fixture.get("ok") is not False, power_fixture
        details["power"] = power_fixture
        time.sleep(2)
    plan_result = h.layout_multi_consumer_plan(b=b)
    assert plan_result.get("ok") is True, plan_result
    plan = plan_result["plan"]
    cell = plan["logistics"]["cell"]
    details["cell"] = cell
    if apply_modules:
        applied = h.apply_layout(plan["id"], b)
        assert applied.get("ok") is True, applied
        details["apply"] = applied
    if coal:
        chest_tile = cell["coal_chest_tile"]
        details["coal_chest"] = h.create_chest(
            chest_tile["x"] + 0.5, chest_tile["y"] + 0.5, {"coal": 100}, b)
        details["coal_chest_tile"] = chest_tile
    time.sleep(1)
    physical = None
    if create_physical:
        physical_result = h.logistics_plan_expansion(plan["id"], b)
        assert physical_result.get("ok") is True, physical_result
        physical = physical_result["physical"]
        details["physical"] = physical
    if materials:
        details["materials"] = dict(CONSTRUCTION_ITEMS)
        if material_chest:
            h.create_chest(anchor["x"] + 1.5, anchor["y"] + 6.5,
                           CONSTRUCTION_ITEMS, b)
        else:
            h.give_items(CONSTRUCTION_ITEMS, b)
    return b, plan, physical, details


def start_expansion(b: h.Bridge, plan: dict, physical: dict) -> str:
    result = h.task_start({
        "task": "build_logistics", "goal_item": "iron-gear-wheel",
        "mode": "multi_consumer", "plan_id": plan["id"],
        "logistics_plan_id": physical["id"],
    }, b)
    return result["task_id"]


def save_reload(b: h.Bridge, name: str) -> h.Bridge:
    h.lua("game.tick_paused = true", b)
    print("  save:", repr(h.save_as(name, b)))
    h.stop_server()
    h.start_server(name + ".zip")
    b = h.bridge()
    set_speed(b, GAME_SPEED)
    h.lua("game.tick_paused = false", b)
    return b
