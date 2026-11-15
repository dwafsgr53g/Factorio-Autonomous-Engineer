"""Stage 6 B — inserter geometry, actual item movement and full-output behaviour."""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402
import stage6_fixture as f  # noqa: E402

RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    f.check(RESULTS, name, condition, detail)


def logistics_inserters(physical: dict, b: h.Bridge) -> list[dict]:
    expected = [entity for entity in physical.get("entities", [])
                if entity.get("name") == "inserter"]
    records = []
    for entity in expected:
        x, y = entity["position"]["x"], entity["position"]["y"]
        record = h.lua_json(f"""
        local out = nil
        for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{
            area={{{{x={x}-0.6,y={y}-0.6}},{{x={x}+0.6,y={y}+0.6}}}},
            type="inserter"}}) do
          if e.valid and math.abs(e.position.x-({x})) < 0.1
            and math.abs(e.position.y-({y})) < 0.1 then
            out = {{unit=e.unit_number, role={entity['role']!r},
              position=e.position, direction=e.direction,
              pickup=e.pickup_position and {{x=e.pickup_position.x,y=e.pickup_position.y}} or nil,
              drop=e.drop_position and {{x=e.drop_position.x,y=e.drop_position.y}} or nil,
              pickup_target=e.pickup_target and e.pickup_target.name or nil,
              drop_target=e.drop_target and e.drop_target.name or nil,
              powered=e.is_connected_to_electric_network(),
              status=e.status,
              held=e.held_stack.valid_for_read and e.held_stack.name or nil}}
          end
        end
        rcon.print(helpers.table_to_json(out or {{}}))
        """, b)
        if record:
            records.append(record)
    records.sort(key=lambda item: item.get("unit", 0))
    return records


def contents_count(contents, name: str) -> int:
    """Count an item in Factorio's list-of-{name,quality,count} contents form."""
    if isinstance(contents, dict):
        direct = contents.get(name)
        if isinstance(direct, int):
            return direct
        values = contents.values()
    else:
        values = contents or []
    total = 0
    for item in values:
        if isinstance(item, dict) and item.get("name") == name:
            total += item.get("count", 0)
    return total


def scenario_a() -> None:
    print("\nScenario A — inserter directions and real material movement")
    b, plan, details = f.prepare("s10a-inserters.zip")
    task_id = f.start_logistics(b)
    result = h.wait_task(task_id, b, timeout=900)
    check("the chain task succeeds", result.get("status") == "succeeded",
          result.get("reason"))
    physical = details["physical"]["physical"]
    inserters = logistics_inserters(physical, b)
    print("  inserters:", h.pretty(inserters))
    check("all six logistics inserters were built", len(inserters) == 6,
          h.pretty(inserters))
    roles = {inserter["role"] for inserter in inserters}
    check("the expected roles are present",
          roles == {"output_inserter", "input_inserter", "fuel_inserter",
                    "fuel_chest_inserter"},
          h.pretty(sorted(roles)))
    check("every logistics inserter is electrically powered",
          all(inserter["powered"] for inserter in inserters), h.pretty(inserters))
    check("every logistics inserter picks from the direction of its source",
          all(inserter["pickup"] and inserter["drop"] for inserter in inserters),
          h.pretty(inserters))
    # Feed and output inserters around the eastward chain all face west for pickup.
    westward = {"input_inserter", "output_inserter"}
    check("chain inserters use the verified west pickup direction",
          all(inserter["direction"] == 12 for inserter in inserters
              if inserter["role"] in westward),
          h.pretty([(inserter["role"], inserter["direction"])
                    for inserter in inserters]))
    fuel = [inserter for inserter in inserters if inserter["role"] == "fuel_inserter"]
    coal_feed = [inserter for inserter in inserters
                 if inserter["role"] == "fuel_chest_inserter"]
    check("the furnace fuel inserter picks north and drops south",
          len(fuel) == 1 and fuel[0]["direction"] == 0
          and fuel[0]["pickup_target"] == "transport-belt",
          h.pretty(fuel))
    check("the chest inserter picks directly from the ordinary coal chest",
          len(coal_feed) == 1 and coal_feed[0]["pickup_target"] == "wooden-chest",
          h.pretty(coal_feed))
    # Actual engine-observed inventories. No production code writes these.
    observations = []
    for _ in range(60):
        observation = {
            "furnace": h.machine_contents("stone-furnace", "crafter_input", b),
            "assembler": h.machine_contents("assembling-machine-1", "crafter_input", b),
            "output": h.machine_contents("assembling-machine-1", "crafter_output", b),
            "coal": h.chest_contents(details["coal_chest"]["unit"], b),
        }
        observations.append(observation)
        if any(item.get("iron-gear-wheel", 0) > 0
               for contents in observation["output"].values() for item in contents):
            break
        time.sleep(0.5)
    furnace_ore = sum(contents_count(contents, "iron-ore")
                      for contents in observations[-1]["furnace"].values())
    assembler_plate = sum(contents_count(contents, "iron-plate")
                          for contents in observations[-1]["assembler"].values())
    coal_left = contents_count(observations[-1]["coal"], "coal")
    check("ore physically entered the furnace", furnace_ore > 0
          or any(contents_count(contents, "iron-ore") > 0
                 for observation in observations
                 for contents in observation["furnace"].values()),
          h.pretty(observations[-1]["furnace"]))
    check("plates physically entered the assembling machine", assembler_plate > 0
          or any(contents_count(contents, "iron-plate") > 0
                 for observation in observations
                 for contents in observation["assembler"].values()),
          h.pretty(observations[-1]["assembler"]))
    check("coal was consumed from the ordinary chest", coal_left < 100,
          h.pretty(observations[-1]["coal"]))
    source = "\n".join(path.read_text(encoding="utf-8")
                       for path in (h.ROOT / "mod" / "factorio_autonomous_engineer").rglob("*.lua"))
    bad_lines = [line.strip() for line in source.splitlines()
                 if ("crafter_input" in line or "crafter_output" in line)
                 and any(token in line for token in (".insert", ".remove", ".clear",
                                                     "force_insert", "insert_at"))]
    check("production code only reads crafter inventories",
          not bad_lines, h.pretty(bad_lines))


def scenario_b() -> None:
    print("\nScenario B — full output inventory back-pressure")
    b, plan, details = f.prepare("s10b-full-output.zip")
    task_id = f.start_logistics(b)
    result = h.wait_task(task_id, b, timeout=900)
    check("the chain starts successfully", result.get("status") == "succeeded",
          result.get("reason"))
    physical = details["physical"]["physical"]
    chest_tile = physical["output"]["chest"]["tile"]
    chest_unit = None
    code = f"""
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{
        area={{{{x={chest_tile['x']},y={chest_tile['y']}}},
               {{x={chest_tile['x']}+1,y={chest_tile['y']}+1}}}},
        name="wooden-chest"}}) do
      if e.valid then rcon.print(e.unit_number) return end
    end
    rcon.print(0)
    """
    chest_unit = int(h.lua(code, b) or 0)
    check("the output chest is a real built chest", chest_unit > 0, str(chest_unit))
    filled = h.lua(f"""
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{name="wooden-chest"}}) do
      if e.unit_number == {chest_unit} then
        local inv = e.get_inventory(defines.inventory.chest)
        inv.insert{{name="iron-gear-wheel", count=5000}}
        rcon.print(helpers.table_to_json(inv.get_contents()))
        return
      end
    end
    rcon.print("null")
    """, b)
    print("  filled chest:", filled)
    time.sleep(20)
    inserters = logistics_inserters(physical, b)
    output_inserter = [inserter for inserter in inserters
                       if inserter["role"] == "output_inserter"
                       and inserter["position"]["x"] > chest_tile["x"] - 1]
    assembler_output = h.machine_contents("assembling-machine-1", "crafter_output", b)
    output_gears = sum(contents_count(contents, "iron-gear-wheel")
                       for contents in assembler_output.values())
    check("a full chest stops the output inserter instead of deleting items",
          output_gears > 0 and any(inserter["status"] == 38 for inserter in output_inserter),
          h.pretty({"assembler_output": assembler_output,
                    "inserters": output_inserter}))
    check("the mod does not remove items from the full output chest",
          contents_count(h.chest_contents(chest_unit, b), "iron-gear-wheel") >= 1000,
          h.pretty(h.chest_contents(chest_unit, b)))
    removed = h.remove_chest_items(chest_unit, "iron-gear-wheel", 100000, b)
    print("  removed:", removed)
    produced_again = h.wait(
        lambda: contents_count(h.chest_contents(chest_unit, b), "iron-gear-wheel") > 0,
        timeout=300, interval=1.0, what="production resumes after chest drain")
    check("production resumes through the engine after the chest is drained",
          produced_again, h.pretty(h.chest_contents(chest_unit, b)))


def main() -> int:
    scenario_a()
    scenario_b()
    failed = [name for name, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:", failed)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
