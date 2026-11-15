"""Stage 6 A — deterministic belt routing, real connections and blocked routes.

Run against a disposable Stage-6 profile:

    FACTORIO_TEST_DIR=... FACTORIO_RCON_PASSWORD=... \
      FACTORIO_RCON_PORT=27076 FACTORIO_GAME_PORT=27037 \
      uv run python tests/engine/s9_belt_routing.py
"""
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


def belt_positions(b: h.Bridge) -> list[dict]:
    return h.belt_entities(b, radius=80)


def scenario_a() -> None:
    print("\nScenario A — real belt routing, turns and item movement")
    b, plan, details = f.prepare("s9a-belts.zip")
    physical = details["physical"]
    check("the physical plan is produced", physical.get("ok") is True,
          h.pretty(physical.get("reason")))
    body = physical.get("physical", {})
    routes = [connection["route"] for connection in body.get("connections", [])
              if connection.get("route")]
    fuel_route = body.get("fuel", {}).get("route")
    all_paths = routes + ([fuel_route] if fuel_route else [])
    check("the fuel route contains a real turn",
          fuel_route is not None and len(set(fuel_route["directions"])) > 1,
          h.pretty(fuel_route))
    check("belt tiles are unique across all routes",
          len({(tile["x"], tile["y"]) for route in all_paths for tile in route["path"]})
          == sum(len(route["path"]) for route in all_paths), h.pretty(all_paths))
    check("the physical plan requires belts", len(body.get("entities", [])) > 0
          and any(item["name"] == "transport-belt" for item in body["required_items"]),
          h.pretty(body.get("required_items")))
    check("the plan does not claim a connection before construction",
          all(connection["status"] == "route_planned"
              for connection in body["connections"]), h.pretty(body["connections"]))
    task_id = f.start_logistics(b)
    result = h.wait_task(task_id, b, timeout=180)
    print("  task:", h.pretty(result)[:900])
    check("the chain task succeeds", result.get("status") == "succeeded",
          result.get("reason"))
    belts = belt_positions(b)
    positions = {(round(belt["position"]["x"], 1), round(belt["position"]["y"], 1))
                 for belt in belts}
    expected = {(tile["x"] + 0.5, tile["y"] + 0.5)
                for route in all_paths for tile in route["path"]}
    check("every planned belt exists exactly once", expected <= positions,
          h.pretty({"missing": sorted(expected - positions), "count": len(belts)}))
    check("no duplicate belt entity exists",
          len(positions) == len(belts), h.pretty([belt["position"] for belt in belts]))
    check("no belt ghost remains", not h.ghosts(b), h.pretty(h.ghosts(b)))
    # Real engine connectivity: each item-route belt's output points at the next tile.
    connectivity_ok = True
    for route in routes:
        for index in range(len(route["path"]) - 1):
            current = route["path"][index]
            nxt = route["path"][index + 1]
            belt = next((item for item in belts
                         if round(item["position"]["x"], 1) == current["x"] + 0.5
                         and round(item["position"]["y"], 1) == current["y"] + 0.5), None)
            if not belt:
                connectivity_ok = False
                break
            outputs = belt.get("neighbours", {}).get("outputs", {})
            values = outputs.values() if isinstance(outputs, dict) else outputs
            output_positions = {(round(value["x"], 1), round(value["y"], 1))
                                for value in values}
            if (nxt["x"] + 0.5, nxt["y"] + 0.5) not in output_positions:
                connectivity_ok = False
                break
    check("the engine reports the intended physical belt connections",
          connectivity_ok, h.pretty(routes))
    # Actual items on transport lines prove Factorio moved them; the mod never writes.
    observed = {}
    for _ in range(20):
        for x_key in sorted({(tile["x"], tile["y"]) for route in all_paths
                             for tile in route["path"]}):
            contents = h.transport_line_contents(x_key[0] + 0.5, x_key[1] + 0.5, b)
            for item in contents:
                observed[item["name"]] = observed.get(item["name"], 0) + item["count"]
        if observed.get("iron-ore", 0) > 0 or observed.get("coal", 0) > 0:
            break
        time.sleep(0.5)
    check("engine-owned transport lines actually carry ore or coal",
          observed.get("iron-ore", 0) + observed.get("coal", 0) > 0,
          h.pretty(observed))
    source = "\n".join(path.read_text(encoding="utf-8")
                       for path in (h.ROOT / "mod" / "factorio_autonomous_engineer").rglob("*.lua"))
    # Stage 7 permits read-only LuaTransportLine observation for flow diagnostics.
    # Mutating transport-line APIs remain forbidden.
    forbidden = ["force_insert_at", "insert_at(", "insert_at_back", "remove_item("]
    check("production code contains no transport-line mutation API",
          not any(token in source for token in forbidden),
          h.pretty([token for token in forbidden if token in source]))


def scenario_b() -> None:
    print("\nScenario B — impossible routes are reported, never forced")
    b, plan, details = f.prepare("s9b-blocked.zip", materials=False, block_route=True)
    physical = details["physical"]
    check("a blocked physical route is reported",
          physical.get("ok") is False and physical.get("status") == "blocked",
          h.pretty({"status": physical.get("status"), "reason": physical.get("reason")}))
    check("the blocked connection names a route failure",
          any(connection["status"] == "blocked" for connection in
              physical.get("physical", {}).get("connections", [])),
          h.pretty(physical.get("physical", {}).get("connections")))
    task_id = f.start_logistics(b)
    result = h.wait_task(task_id, b, timeout=180)
    print("  task:", h.pretty(result)[:700])
    check("the composite task reports blocked without building",
          result.get("status") == "blocked"
          and "blocked" in str(result.get("reason")).lower(),
          h.pretty(result))
    check("no module or logistics entity was built",
          not h.entities_named(["electric-mining-drill", "stone-furnace",
                                "assembling-machine-1", "transport-belt",
                                "inserter"], b) and not h.ghosts(b),
          h.pretty(h.real_counts(b)))


def scenario_c() -> None:
    print("\nScenario C — missing materials are reported exactly")
    b, plan, details = f.prepare("s9c-missing.zip", materials=False)
    task_id = f.start_logistics(b)
    result = h.wait_task(task_id, b, timeout=180)
    print("  task:", h.pretty(result)[:900])
    check("the task ends in missing_materials", result.get("status") == "missing_materials",
          h.pretty(result))
    missing = result.get("missing_materials") or {}
    check("the exact missing requirements are listed",
          missing.get("electric-mining-drill") == 1
          and missing.get("transport-belt", 0) >= 1
          and missing.get("inserter", 0) >= 1,
          h.pretty(missing))
    check("nothing was fabricated for free",
          not h.entities_named(["electric-mining-drill", "stone-furnace",
                                "assembling-machine-1", "transport-belt",
                                "inserter"], b), h.pretty(h.real_counts(b)))


def scenario_d() -> None:
    print("\nScenario D — cancellation stops future construction")
    b, plan, details = f.prepare("s9d-cancel.zip")
    f.set_speed(b, 1)
    task_id = f.start_logistics(b)
    h.wait(lambda: h.status(b)["task"].get("built_by_agent", 0) >= 2
           and h.status(b)["task"].get("remaining", 0) >= 1,
           timeout=120, interval=0.2, what="some logistics built and work remains")
    before = len(h.entities_named(["transport-belt", "inserter", "medium-electric-pole",
                                   "wooden-chest"], b))
    cancelled = b.call("task_cancel", {"task_id": task_id, "reason": "stage6_test"})["result"]
    check("cancellation is terminal", cancelled.get("status") == "cancelled",
          h.pretty(cancelled))
    time.sleep(6)
    after = len(h.entities_named(["transport-belt", "inserter", "medium-electric-pole",
                                  "wooden-chest"], b))
    check("no further construction occurs after cancellation", after == before,
          f"{before} -> {after}")


def main() -> int:
    scenario_a()
    scenario_b()
    scenario_c()
    scenario_d()
    failed = [name for name, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:", failed)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
