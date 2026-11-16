"""Stage 7.1 - sequential task movement and scheduler isolation.

Runs two construction tasks back-to-back in one world, then injects a real stale
path callback after a replacement task has started. Production state is observed
through the internal diagnostics surface; no movement micro-action is exposed by MCP.
"""
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


def fresh(save: str, speed: int = 60) -> h.Bridge:
    h.load_scenario_save(save, baseline="s71-baseline.zip")
    b = h.bridge()
    h.lua(f"game.speed = {speed}", b)
    h.research_all(b)
    h.lua("game.surfaces.nauvis.always_day = true", b)
    h.clear_test_area(-30, -30, 80, 40, b, keep_resources=True)
    h.set_home({"x": 0.5, "y": 0.5}, b)
    b.call("movement_reset_stats")
    return b


def movement(b: h.Bridge) -> dict:
    return b.call("movement_status")["result"]


def zone_ids(result: dict) -> set[str]:
    return {zone["id"] for zone in (result.get("zones") or {}).get("zones", [])}


def scenario_immediate_restart() -> None:
    print("Scenario A - immediate sequential tasks have fresh movement and zone state")
    b = fresh("s21a-sequential.zip")
    h.create_ghost("stone-furnace", 12, 0, b=b)
    h.give_items({"stone-furnace": 1}, b)
    first_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    first = h.wait_task(first_id, b, timeout=120)
    check("the first task completed", first.get("status") == "succeeded",
          first.get("reason"))
    first_zones = zone_ids(first)
    check("the first task used its own work-zone plan", bool(first_zones),
          h.pretty(sorted(first_zones)))
    after_first = movement(b)
    check("completion released the active movement intent",
          after_first["movement"].get("state") == "idle",
          h.pretty(after_first["movement"]))

    h.create_ghost("stone-furnace", 42, 0, b=b)
    h.give_items({"stone-furnace": 1}, b)
    second_id = h.task_start({"task": "assist_construction"}, b)["task_id"]
    check("the replacement task received a new task identity", second_id != first_id,
          f"{first_id} -> {second_id}")
    second = h.wait_task(second_id, b, timeout=120)
    check("the immediately started replacement task completed",
          second.get("status") == "succeeded", second.get("reason"))
    second_zones = zone_ids(second)
    check("work-zone ordering and processed ledgers were not shared",
          bool(second_zones) and first_zones.isdisjoint(second_zones),
          h.pretty({"first": sorted(first_zones), "second": sorted(second_zones)}))
    owners = {intent.get("owner") for intent in movement(b)["detail"].get("intents", [])}
    check("movement intents are owned by their respective tasks",
          first_id in owners and second_id in owners, h.pretty(sorted(owners)))


def scenario_stale_callback() -> None:
    print("\nScenario B - a superseded callback cannot alter the replacement task")
    b = fresh("s21b-stale-callback.zip", speed=1)
    h.give_items({"stone-furnace": 1}, b)
    h.lua(
        "storage.ae_old_path_request = nil\n"
        "script.on_event(defines.events.on_script_path_request_finished, function(e)\n"
        "  storage.ae_old_path_request = storage.ae_old_path_request or e.id\n"
        "end)", b)
    old_task = "stale-source"
    requested = b.call("movement_request", {
        "owner": old_task, "purpose": "superseded_route",
        "destination": {"x": 60.5, "y": 0.5}, "arrival_tolerance": 0.8,
    })["result"]
    assert requested.get("ok"), requested
    h.wait(lambda: int(h.lua(
        "rcon.print(tostring(storage.ae_old_path_request or -1))", b)) >= 0,
        timeout=60, interval=0.02, what="old path callback")
    old_request = int(h.lua("rcon.print(storage.ae_old_path_request)", b))
    old_intent = requested["request_id"]

    h.create_ghost("stone-furnace", 42, 8, b=b)
    new_task = h.task_start({"task": "assist_construction"}, b)["task_id"]
    h.wait(lambda: movement(b)["movement"].get("state") == "following_path",
           timeout=60, interval=0.02, what="replacement path following")
    h.lua("game.tick_paused = true", b)
    before = movement(b)
    new_intent = before["movement"]["request_id"]
    before_destination = before["movement"].get("destination")
    stale_before = before["stats"].get("stale_path_callbacks", 0)
    b.call("movement_path_callback", {
        "id": old_request,
        "path": [{"position": {"x": 1, "y": 1}, "needs_destroy_to_reach": False}],
    })
    after = movement(b)
    check("the replacement has new task and movement identities",
          new_task != old_task and new_intent != old_intent,
          h.pretty({"old_task": old_task, "new_task": new_task,
                    "old_intent": old_intent, "new_intent": new_intent}))
    check("the stale callback was ignored",
          after["stats"].get("stale_path_callbacks", 0) > stale_before,
          h.pretty(after.get("stats")))
    check("the stale callback did not change the replacement destination",
          after["movement"].get("destination") == before_destination,
          h.pretty({"before": before_destination,
                    "after": after["movement"].get("destination")}))
    check("the replacement remained on its own route",
          after["movement"].get("state") == "following_path"
          and after["movement"].get("request_id") == new_intent,
          h.pretty(after["movement"]))
    h.lua("game.tick_paused = false", b)
    h.lua("game.speed = 60", b)
    result = h.wait_task(new_task, b, timeout=120)
    check("the replacement task completed after the stale callback",
          result.get("status") == "succeeded", result.get("reason"))


def main() -> int:
    scenario_immediate_restart()
    scenario_stale_callback()
    failed = [name for name, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:", failed)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
