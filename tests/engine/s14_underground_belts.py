"""Stage-7 underground transport belts.

Proves the planner uses live prototype reach, rejects over-range pairs, preserves
orientation and pair identity in the engine, and demonstrates real item transfer through
the expansion's underground crossing. Also proves a player-owned belt at an underground
endpoint blocks the plan and is preserved.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402
import stage7_fixture as f  # noqa: E402


def pair_entities(entrance: dict, exit_tile: dict, b: h.Bridge) -> list[dict]:
    code = (
        "local s = game.surfaces.nauvis; "
        "local out = {}; "
        "for _, e in pairs(s.find_entities_filtered{"
        f"area={{{{x={entrance['x'] - 1},y={entrance['y'] - 1}}},"
        f"{{x={exit_tile['x'] + 2},y={exit_tile['y'] + 2}}}}},"
        "name=\"underground-belt\"}) do "
        "local nb = e.underground_belt_neighbour; "
        "out[#out+1] = {position={x=e.position.x,y=e.position.y}, direction=e.direction, "
        "type=e.belt_to_ground_type, "
        "neighbour=nb and {x=nb.position.x,y=nb.position.y} or nil} end; "
        "rcon.print(helpers.table_to_json(out))"
    )
    return h.lua_json(code, b) or []


def main() -> int:
    results: list[tuple[str, bool, str]] = []
    b, plan, physical, details = f.prepare("s14a-underground.zip")
    cell = details["cell"]

    # Geometry and live reach, planned without touching the world.
    east = h.transport_probe(splitter={"x": 10, "y": 10, "direction": 4}, b=b)
    north = h.transport_probe(splitter={"x": 10, "y": 10, "direction": 0}, b=b)
    f.check(results, "east splitter is 1x2 with two side connectors",
            east["splitter"]["footprint"] == {"width": 1, "height": 2}
            and len(east["splitter"]["inputs"]) == 2
            and len(east["splitter"]["outputs"]) == 2,
            json.dumps(east["splitter"]))
    f.check(results, "north splitter is 2x1 with two side connectors",
            north["splitter"]["footprint"] == {"width": 2, "height": 1}
            and len(north["splitter"]["inputs"]) == 2,
            json.dumps(north["splitter"]))
    minimum = h.transport_probe(
        underground={"x": 140, "y": 140, "direction": 8, "distance": 1}, b=b)
    maximum = h.transport_probe(
        underground={"x": 140, "y": 140, "direction": 8, "distance": 5}, b=b)
    over = h.transport_probe(
        underground={"x": 140, "y": 140, "direction": 8, "distance": 6}, b=b)
    f.check(results, "live yellow underground max distance is five",
            maximum.get("max_distance") == 5, str(maximum.get("max_distance")))
    f.check(results, "minimum distance one is accepted",
            minimum.get("pair") is not None)
    f.check(results, "maximum distance five is accepted",
            maximum.get("pair") is not None)
    f.check(results, "over-range distance six is rejected",
            over.get("pair") is None and over.get("pair_reason") == "underground_distance_exceeded",
            json.dumps(over.get("pair_reason")))

    # A real distance-one pair is recognized by the engine itself.
    h.lua("""
    local s = game.surfaces.nauvis
    s.create_entity{name="underground-belt", position={x=150.5,y=150.5}, direction=8,
      force=game.forces.player}
    s.create_entity{name="underground-belt", position={x=150.5,y=151.5}, direction=0,
      force=game.forces.player}
    """, b)
    real_min = pair_entities({"x": 150, "y": 150}, {"x": 150, "y": 151}, b)
    f.check(results, "real distance-one pair has reciprocal neighbours",
            len(real_min) == 2 and all(e.get("neighbour") for e in real_min)
            and real_min[0]["neighbour"] == real_min[1]["position"]
            and real_min[1]["neighbour"] == real_min[0]["position"],
            json.dumps(real_min))

    # Expansion crossing: real paid construction and item transfer through the pair.
    tid = f.start_expansion(b, plan, physical)
    task = h.wait_task(tid, b, timeout=600)
    f.check(results, "expansion task succeeds", task.get("status") == "succeeded",
            json.dumps(task.get("reason")))
    verify = h.logistics_verify(physical["id"], b)
    pair_plan = cell["underground"]
    exit_tile = {"x": pair_plan["entrance"]["x"],
                 "y": pair_plan["entrance"]["y"] + pair_plan["distance"]}
    built = pair_entities(pair_plan["entrance"], exit_tile, b)
    f.check(results, "paid executor built exactly two underground endpoints",
            len(built) == 2, json.dumps(built))
    f.check(results, "engine reports input and output roles",
            sorted(e.get("type") for e in built) == ["input", "output"], json.dumps(built))
    f.check(results, "both endpoints retain travel direction south",
            all(e.get("direction") == 8 for e in built), json.dumps(built))
    f.check(results, "planned pair is verified by the runtime neighbour relation",
            len(verify.get("underground", [])) == 1
            and verify["underground"][0].get("ok") is True
            and verify["underground"][0].get("distance") == 2,
            json.dumps(verify.get("underground")))
    f.check(results, "coal physically traversed the underground crossing to furnace 2",
            verify.get("consumers", {}).get("fuel", {}).get("smelting_2") is True)

    # Player-owned belt at the planned exit must block planning and be preserved.
    b2, plan2, _, details2 = f.prepare("s14b-player-endpoint.zip", create_physical=False)
    pair_plan2 = details2["cell"]["underground"]
    exit2 = {"x": pair_plan2["entrance"]["x"],
             "y": pair_plan2["entrance"]["y"] + pair_plan2["distance"]}
    player_belt = h.create_ghost("transport-belt", exit2["x"] + 0.5,
                                 exit2["y"] + 0.5, direction=4, b=b2)
    # The fixture helper creates a ghost; revive it as player-built infrastructure.
    h.build_ghost_as_player(player_belt["unit"], b2)
    blocked = h.logistics_plan_expansion(plan2["id"], b2)
    f.check(results, "player-owned underground endpoint blocks the plan",
            blocked.get("ok") is False, json.dumps(blocked.get("reason")))
    preserved = h.entity_at("transport-belt", exit2["x"] + 0.5, exit2["y"] + 0.5, b=b2)
    f.check(results, "player-owned endpoint belt preserved", preserved is not None)

    passed = sum(1 for _, ok, _ in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
