"""Stage-7 multi-consumer expansion beside a working Stage-6 factory.

Builds the Stage-6 linear chain first, snapshots every real entity in its footprint,
then builds the Stage-7 parallel multi-consumer cell in the same shared world. The old
factory must remain byte-for-byte present and keep its output, while the new cell proves
two ore consumers, two coal consumers, two plate consumers and a merged gear output.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402
import stage6_fixture as s6  # noqa: E402
import stage7_fixture as f  # noqa: E402


def snapshot_area(b: h.Bridge, box: dict) -> list[dict]:
    code = f"""
    local s = game.surfaces.nauvis
    local out = {{}}
    for _, e in pairs(s.find_entities_filtered{{
        area={{{{x={box['left']},y={box['top']}}},{{x={box['right']},y={box['bottom']}}}}}}}) do
      if e.valid and e.type ~= "resource" and e.type ~= "entity-ghost"
         and e.type ~= "character" and e.type ~= "item-entity" and e.type ~= "corpse"
         and e.type ~= "smoke" and e.type ~= "fish" then
        out[#out+1] = {{unit=e.unit_number, name=e.name,
          position={{x=e.position.x,y=e.position.y}}, direction=e.direction}}
      end
    end
    table.sort(out, function(a,b) return a.unit < b.unit end)
    rcon.print(helpers.table_to_json(out))
    """
    return h.lua_json(code, b) or []


def output_gears(plan: dict, b: h.Bridge) -> int:
    return s6.output_chest_gears(plan, b)


def wait_with_timeline(task_id: str, b: h.Bridge, *, timeout: float,
                       baseline_stats: dict) -> dict:
    """Capture bounded task transitions and counter deltas, never per-tick logs."""
    snapshots: list[dict] = []
    baseline: dict | None = baseline_stats
    last_signature: tuple | None = None
    last_sample_tick: int | None = None
    truncated = 0
    stat_names = (
        "path_requests", "path_callbacks", "paths_received", "stale_path_callbacks",
        "stale_callbacks", "try_again_later", "no_path", "path_timeouts", "replans",
        "world_change_replans", "belt_recoveries", "ghost_recoveries", "recovery_resumes",
        "distance_travelled",
    )

    def poll() -> dict | None:
        nonlocal baseline, last_signature, last_sample_tick, truncated
        status = h.task_status(task_id, b)
        debug = h.task_debug(b)
        request_id = debug.get("movement_request")
        params = {"request_id": request_id} if request_id else {}
        movement = b.call("movement_status", params)["result"]
        current = movement.get("movement") or {}
        stats = movement.get("stats") or {}
        if baseline is None:
            baseline = {name: stats.get(name, 0) for name in stat_names}
        counters = {
            name: round(stats.get(name, 0) - baseline.get(name, 0), 6)
            for name in stat_names
        }
        counters["path_retries"] = sum(counters[name] for name in (
            "try_again_later", "no_path", "path_timeouts", "replans",
            "world_change_replans",
        ))
        tick = int(debug.get("current_tick") or 0)
        snapshot = {
            "task_id": task_id,
            "tick": tick,
            "task_start_tick": debug.get("started_tick"),
            "task_deadline_tick": debug.get("deadline_tick"),
            "deadline_remaining_ticks": debug.get("remaining_ticks"),
            "phase": debug.get("phase"),
            "movement_request_id": current.get("request_id") or request_id,
            "movement_owner": current.get("owner"),
            "movement_state": current.get("state"),
            "work_zone_id": debug.get("active_zone"),
            "zone_transitions": debug.get("zone_transitions", 0),
            "construction_completed": status.get("built_by_agent", 0),
            "material_acquisition_trips": status.get("acquisition_trips", 0),
            "counters": counters,
        }
        terminal = status.get("status") in h.TERMINAL
        if terminal:
            snapshot["completion_or_timeout_tick"] = debug.get("finished_tick") or tick
            snapshot["terminal_status"] = status.get("status")
            snapshot["terminal_reason"] = status.get("reason")
        signature = (
            snapshot["phase"], snapshot["movement_request_id"],
            snapshot["movement_state"], snapshot["work_zone_id"],
            snapshot["construction_completed"], snapshot["material_acquisition_trips"],
        )
        periodic = last_sample_tick is None or tick - last_sample_tick >= 600
        if terminal or signature != last_signature or periodic:
            if len(snapshots) < 64 or terminal:
                snapshots.append(snapshot)
            else:
                truncated += 1
            last_signature = signature
            last_sample_tick = tick
        return status if terminal else None

    result = h.wait(poll, timeout=timeout, interval=0.5, what=f"task {task_id}")
    print("  bounded task timeline:", json.dumps({
        "task_id": task_id, "samples": snapshots, "truncated_samples": truncated,
    }, sort_keys=True))
    return result


def main() -> int:
    results: list[tuple[str, bool, str]] = []
    b, stage6_plan, stage6_details = s6.prepare("s15a-baseline.zip",
                                                baseline="s7-baseline.zip")
    stats6 = b.call("movement_status")["result"]["stats"]
    tid6 = s6.start_logistics(b)
    task6 = wait_with_timeline(tid6, b, timeout=600, baseline_stats=stats6)
    f.check(results, "Stage-6 baseline succeeds before expansion",
            task6.get("status") == "succeeded", json.dumps(task6.get("reason")))
    stage6_physical = stage6_details["physical"]["physical"]
    gears_before = output_gears(stage6_plan, b)
    boxes = [module["bounds"] for module in stage6_plan["modules"]]
    left = min(box[0]["x"] for box in boxes) - 3
    top = min(box[0]["y"] for box in boxes) - 3
    right = max(box[1]["x"] for box in boxes) + 3
    bottom = max(box[1]["y"] for box in boxes) + 3
    old_world = snapshot_area(b, {"left": left, "top": top,
                                  "right": right, "bottom": bottom})
    old_units = {record["unit"]: record for record in old_world}
    f.check(results, "Stage-6 snapshot contains real production infrastructure",
            len(old_world) >= 20, str(len(old_world)))

    # Plan the Stage-7 parallel cell in the existing shared world.
    expansion = h.layout_multi_consumer_plan(b=b)
    f.check(results, "Stage-7 expansion plan is available beside the old factory",
            expansion.get("ok") is True, json.dumps(expansion.get("reason")))
    if not expansion.get("ok"):
        passed = sum(1 for _, ok, _ in results if ok)
        print(f"\n{passed}/{len(results)} checks passed")
        return 1
    plan7 = expansion["plan"]
    cell = plan7["logistics"]["cell"]
    old_module_boxes = [(m["bounds"][0]["x"], m["bounds"][0]["y"],
                          m["bounds"][1]["x"], m["bounds"][1]["y"])
                         for m in stage6_plan["modules"]]
    new_module_boxes = [(m["bounds"][0]["x"], m["bounds"][0]["y"],
                          m["bounds"][1]["x"], m["bounds"][1]["y"])
                         for m in plan7["modules"]]
    module_overlap = any(
        a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]
        for a in old_module_boxes for b in new_module_boxes)
    f.check(results, "new module footprints do not overlap the old modules",
            not module_overlap, json.dumps({"old": old_module_boxes,
                                            "new": new_module_boxes}))
    applied = h.apply_layout(plan7["id"], b)
    f.check(results, "new module ghosts apply without touching old modules",
            applied.get("ok") is True, json.dumps(applied.get("failed")))

    # Scenario prerequisites near the new cell: a real powered network and ordinary coal.
    left7 = cell["bounds"]["left"]
    top7 = cell["bounds"]["top"]
    power = h.create_solar_fixture(left7 - 9.5, top7 - 9.5, b)
    f.check(results, "new cell has a legal powered network nearby",
            power.get("ok") is not False, json.dumps(power))
    coal_tile = cell["coal_chest_tile"]
    h.create_chest(coal_tile["x"] + 0.5, coal_tile["y"] + 0.5,
                    {"coal": 100}, b)
    time.sleep(2)
    expanded = h.logistics_plan_expansion(plan7["id"], b)
    f.check(results, "multi-consumer physical plan resolves in the shared world",
            expanded.get("ok") is True, json.dumps(expanded.get("reason")))
    if not expanded.get("ok"):
        passed = sum(1 for _, ok, _ in results if ok)
        print(f"\n{passed}/{len(results)} checks passed")
        return 1
    physical7 = expanded["physical"]

    h.clear_main_inventory(b)
    h.give_items(f.CONSTRUCTION_ITEMS, b)
    stats7 = b.call("movement_status")["result"]["stats"]
    tid7 = f.start_expansion(b, plan7, physical7)
    task7 = wait_with_timeline(tid7, b, timeout=700, baseline_stats=stats7)
    f.check(results, "Stage-7 multi-consumer expansion succeeds",
            task7.get("status") == "succeeded", json.dumps(task7.get("reason")))
    verify7 = h.logistics_verify(physical7["id"], b)
    f.check(results, "14 routes and five splitters are engine-connected",
            verify7.get("routes_connected") is True
            and len(verify7.get("junctions", [])) == 5)
    consumers = verify7.get("consumers", {})
    f.check(results, "both stages' consumers supplied",
            all(consumers.get("ore", {}).values())
            and all(consumers.get("fuel", {}).values())
            and all(consumers.get("plate", {}).values())
            and all(consumers.get("gear", {}).values()))
    f.check(results, "merged gear output verified", verify7.get("output_verified") is True)

    # Old factory preservation.
    time.sleep(3)
    old_after = snapshot_area(b, {"left": left, "top": top,
                                  "right": right, "bottom": bottom})
    after_units = {record["unit"]: record for record in old_after}
    missing = [unit for unit in old_units if unit not in after_units]
    changed = [unit for unit in old_units if unit in after_units
               and old_units[unit] != after_units[unit]]
    extra = [unit for unit in after_units if unit not in old_units]
    f.check(results, "no Stage-6 real entity was removed", not missing, str(missing[:10]))
    f.check(results, "no Stage-6 real entity was moved or rotated",
            not changed, str(changed[:10]))
    # New parallel belts may run close to the old factory, but no old unit may be
    # replaced. Missing/changed checks above are the authoritative preservation proof.
    old_positions = {(record["position"]["x"], record["position"]["y"])
                     for record in old_units.values()}
    extra_positions = {(after_units[unit]["position"]["x"],
                        after_units[unit]["position"]["y"]) for unit in extra}
    f.check(results, "no new unit reuses an old position",
            not (old_positions & extra_positions), str(extra[:10]))
    gears_after = output_gears(stage6_plan, b)
    f.check(results, "Stage-6 output chest keeps its production",
            gears_after >= gears_before, f"{gears_before} -> {gears_after}")
    stage6_verify = h.logistics_verify(stage6_physical["id"], b)
    f.check(results, "Stage-6 factory still verifies its entities and power",
            stage6_verify.get("entities") is True and stage6_verify.get("power") is True,
            json.dumps({k: stage6_verify.get(k) for k in ("entities", "power", "fuel")}))
    f.check(results, "every Stage-6 unit is still present after both runs",
            all(unit in after_units for unit in old_units),
            str([unit for unit in old_units if unit not in after_units][:10]))

    passed = sum(1 for _, ok, _ in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
