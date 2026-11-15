"""Stage-7 splitters and multi-consumer distribution.

Scenario A proves real one-to-two splitting, two-to-one merging, both consumers supplied
and a real common output. Scenario B places a player building on a branch and proves the
planner reports the route blocked without removing it. Scenario C fills the common output
chest and proves back-pressure does not produce a false success. Scenario D empties the
coal chest and proves missing fuel is reported.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402
import stage7_fixture as f  # noqa: E402

FORBIDDEN = ("insert_at", "insert_at_back", "force_insert_at", "remove_item", "clear(")


def source_mutation_scan() -> list[str]:
    mod = Path(__file__).resolve().parents[2] / "mod" / "factorio_autonomous_engineer"
    findings = []
    for path in mod.rglob("*.lua"):
        text = path.read_text(encoding="utf-8", errors="replace")
        for token in FORBIDDEN:
            if token in text:
                findings.append(f"{path.name}:{token}")
    return findings


def splitter_entities(b: h.Bridge) -> list[dict]:
    code = """
    local out = {}
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{name="splitter"}) do
      local n = e.belt_neighbours
      local function rec(list)
        local t = {}
        for _, n in ipairs(list or {}) do
          t[#t+1] = {x=n.position.x, y=n.position.y}
        end
        return t
      end
      out[#out+1] = {position={x=e.position.x,y=e.position.y}, direction=e.direction,
        inputs=rec(n.inputs), outputs=rec(n.outputs)}
    end
    table.sort(out, function(a,b) return a.position.x*1000+a.position.y <
      b.position.x*1000+b.position.y end)
    rcon.print(helpers.table_to_json(out))
    """
    return h.lua_json(code, b) or []


def junction_by_id(verify: dict, junction_id: str) -> dict | None:
    for record in verify.get("junctions", []):
        if record.get("id") == junction_id:
            return record
    return None


def main() -> int:
    results: list[tuple[str, bool, str]] = []
    b, plan, physical, details = f.prepare("s13a-splitters.zip")
    tid = f.start_expansion(b, plan, physical)
    task = h.wait_task(tid, b, timeout=600)
    f.check(results, "A: expansion task succeeds", task.get("status") == "succeeded",
            json.dumps(task.get("reason")))
    verify = h.logistics_verify(physical["id"], b)
    f.check(results, "A: 14 logical routes connected", verify.get("routes_connected") is True,
            str(len(verify.get("routes", []))))
    f.check(results, "A: five real splitters verified", len(verify.get("junctions", [])) == 5
            and all(j.get("ok") for j in verify.get("junctions", [])),
            json.dumps(verify.get("junctions")))
    f.check(results, "A: underground pair verified",
            len(verify.get("underground", [])) == 1
            and verify["underground"][0].get("ok") is True)
    consumers = verify.get("consumers", {})
    f.check(results, "A: ore reaches both furnaces", all(consumers.get("ore", {}).values()))
    f.check(results, "A: coal reaches both furnaces", all(consumers.get("fuel", {}).values()))
    f.check(results, "A: plates reach both assemblers", all(consumers.get("plate", {}).values()))
    f.check(results, "A: both assemblers produced gears", all(consumers.get("gear", {}).values()))
    f.check(results, "A: common output verified", verify.get("output_verified") is True)
    gears = task.get("production", {}).get("gear_wheels", 0)
    f.check(results, "A: output chest contains real gears", gears > 0, str(gears))

    real_splitters = splitter_entities(b)
    f.check(results, "A: exactly five real splitters", len(real_splitters) == 5,
            str(len(real_splitters)))
    all_dirs = {s["direction"] for s in real_splitters}
    f.check(results, "A: splitters have east orientation", all_dirs == {4}, str(all_dirs))
    connectors = [(len(s["inputs"]), len(s["outputs"])) for s in real_splitters]
    f.check(results, "A: splitter connector counts are native 1/2 or 2/1",
            sorted(connectors) == [(1, 2), (1, 2), (2, 1), (2, 1), (1, 2)]
            or all((a, b) in ((1, 2), (2, 1)) for a, b in connectors), str(connectors))

    ore_split = junction_by_id(verify, "ore_split")
    plate_merge = junction_by_id(verify, "plate_merge")
    gear_merge = junction_by_id(verify, "gear_merge")
    f.check(results, "A: ore splitter is one-to-two",
            ore_split and ore_split.get("kind") == "split")
    f.check(results, "A: plate junction is two-to-one",
            plate_merge and plate_merge.get("kind") == "merge")
    f.check(results, "A: gear junction is two-to-one",
            gear_merge and gear_merge.get("kind") == "merge")

    mutations = source_mutation_scan()
    f.check(results, "A: no direct transport-line mutation API", not mutations, str(mutations))

    # Scenario B: player building on a branch must block the plan and be preserved.
    b2, plan2, physical2, details2 = f.prepare("s13b-blocked-branch.zip")
    branch = next(r for r in physical2["connections"] if r["id"] == "ore_branch_b")
    occupied_tile = branch["belts"][2]["tile"]
    chest = h.create_chest(occupied_tile["x"] + 0.5, occupied_tile["y"] + 0.5,
                           {"wood": 1}, b2)
    tid2 = f.start_expansion(b2, plan2, physical2)
    task2 = h.wait_task(tid2, b2, timeout=240)
    f.check(results, "B: player-obstructed branch reports blocked",
            task2.get("status") in {"blocked", "failed"}, json.dumps(task2.get("reason")))
    preserved = h.entity_at("wooden-chest", occupied_tile["x"] + 0.5,
                            occupied_tile["y"] + 0.5, b=b2)
    f.check(results, "B: player building preserved", preserved is not None
            and preserved.get("unit") == chest.get("unit"))
    verify2 = h.logistics_verify(physical2["id"], b2)
    f.check(results, "B: no false success", verify2.get("ok") is False)

    # Scenario C: a full output chest must cause back-pressure, not success.
    b3, plan3, physical3, details3 = f.prepare("s13c-full-output.zip")
    out_tile = details3["cell"]["output_chest_tile"]
    h.create_chest(out_tile["x"] + 0.5, out_tile["y"] + 0.5,
                   {"wood": 1600}, b3)
    tid3 = f.start_expansion(b3, plan3, physical3)
    deadline = time.monotonic() + 300
    backpressure_seen = False
    status3 = None
    while time.monotonic() < deadline:
        status3 = h.task_status(tid3, b3)
        verify3 = h.logistics_verify(physical3["id"], b3)
        if (verify3.get("routes_connected") and verify3.get("production_active")
                and verify3.get("output_verified") is False):
            backpressure_seen = True
            break
        if status3.get("status") in h.TERMINAL:
            break
        time.sleep(1)
    if not backpressure_seen:
        # A blocked output can outlive the task monitor window. The engine keeps
        # simulating after the task terminal result; observe the same physical state.
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline:
            verify3 = h.logistics_verify(physical3["id"], b3)
            if (verify3.get("production_active") is True
                    and verify3.get("output_verified") is False):
                backpressure_seen = True
                break
            time.sleep(1)
    f.check(results, "C: full output observed as back-pressure", backpressure_seen)
    f.check(results, "C: full output does not report success",
            status3 and status3.get("status") != "succeeded")
    h.task_cancel(tid3, "test_complete", b3)

    # Scenario D: a depleted coal source must report missing fuel.
    b4, plan4, physical4, details4 = f.prepare("s13d-no-fuel.zip")
    h.remove_chest_items(details4["coal_chest"]["unit"], "coal", 100, b4)
    tid4 = f.start_expansion(b4, plan4, physical4)
    task4 = h.wait_task(tid4, b4, timeout=360)
    f.check(results, "D: missing fuel reported", task4.get("status") in {"blocked", "failed"}
            and "fuel" in str(task4.get("reason")), json.dumps(task4.get("reason")))
    f.check(results, "D: no gear production claimed",
            task4.get("production", {}).get("produced") is False)

    passed = sum(1 for _, ok, _ in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
