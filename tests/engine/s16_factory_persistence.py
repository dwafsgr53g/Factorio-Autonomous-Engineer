"""Stage-7 persistence, cancellation, repeated execution and interruption.

Covers save/load during construction and production monitoring, cancellation followed by
a clean restart, repeated execution without duplication, a player-removed route that is
not silently rebuilt, safety pre-emption and death recovery.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402
import stage7_fixture as f  # noqa: E402

NAMES = ["transport-belt", "inserter", "splitter", "underground-belt",
         "electric-mining-drill", "stone-furnace", "assembling-machine-1",
         "wooden-chest", "medium-electric-pole"]


def expected_counts(physical: dict) -> dict[str, int]:
    counts: dict[str, int] = {
        "electric-mining-drill": 1, "stone-furnace": 2, "assembling-machine-1": 2,
    }
    for record in physical["entities"]:
        name = record["name"]
        counts[name] = counts.get(name, 0) + 1
    # The coal chest is a scenario prerequisite, not part of the physical ghost plan.
    counts["wooden-chest"] = counts.get("wooden-chest", 0) + 1
    counts["medium-electric-pole"] = counts.get("medium-electric-pole", 0) + 1
    return counts


def actual_counts(b: h.Bridge) -> dict[str, int]:
    return {name: len(h.entities_named([name], b)) for name in NAMES}


def units_for(b: h.Bridge) -> dict[str, list[int]]:
    return {name: sorted(record["unit"] for record in h.entities_named([name], b))
            for name in NAMES}


def scenario_a() -> None:
    print("\nScenario A - save/load during splitter and underground construction")
    b, plan, physical, details = f.prepare("s16a-save-construction.zip")
    f.set_speed(b, 1)
    tid = f.start_expansion(b, plan, physical)
    h.wait(lambda: h.status(b)["task"].get("built_by_agent", 0) >= 12,
           timeout=240, interval=0.2, what="partial splitter construction")
    before = units_for(b)
    b = f.save_reload(b, "s16a-mid")
    task = h.wait_task(tid, b, timeout=600)
    f.check(RESULTS, "A: task survives save/load during construction",
            task.get("status") == "succeeded", json.dumps(task.get("reason")))
    expected = expected_counts(physical)
    actual = actual_counts(b)
    f.check(RESULTS, "A: exact entity counts after save/load",
            all(actual.get(name, 0) == count for name, count in expected.items()),
            json.dumps({"expected": expected, "actual": actual}))
    after = units_for(b)
    for name in before:
        f.check(RESULTS, f"A: no duplicated or lost {name} across save/load",
                len(after[name]) == len(set(after[name]))
                and set(before[name]).issubset(set(after[name])),
                json.dumps({"before": before[name], "after": after[name]})[:400])


def scenario_b() -> None:
    print("\nScenario B - save/load during multi-consumer production monitoring")
    b, plan, physical, details = f.prepare("s16b-save-monitor.zip")
    f.set_speed(b, 60)
    tid = f.start_expansion(b, plan, physical)
    h.wait(lambda: (lambda v: v.get("production_active") is True
                    and v.get("routes_connected") is True)(
                        h.logistics_verify(physical["id"], b)),
           timeout=420, interval=0.5, what="real production active")
    b = f.save_reload(b, "s16b-mid")
    task = h.wait_task(tid, b, timeout=420)
    f.check(RESULTS, "B: task survives save/load during production monitoring",
            task.get("status") == "succeeded", json.dumps(task.get("reason")))
    verify = h.logistics_verify(physical["id"], b)
    f.check(RESULTS, "B: both consumers still supplied after reload",
            verify.get("consumers_supplied") is True
            and verify.get("output_verified") is True)


def scenario_c() -> None:
    print("\nScenario C - repeated execution does not duplicate infrastructure")
    b, plan, physical, details = f.prepare("s16c-repeat.zip")
    tid = f.start_expansion(b, plan, physical)
    first = h.wait_task(tid, b, timeout=600)
    f.check(RESULTS, "C: first run succeeds", first.get("status") == "succeeded",
            json.dumps(first.get("reason")))
    before = units_for(b)
    coal_before = sum(item.get("count", 0) for item in
                      (h.chest_contents(details["coal_chest"]["unit"], b) or [])
                      if item.get("name") == "coal")
    tid2 = f.start_expansion(b, plan, physical)
    second = h.wait_task(tid2, b, timeout=240)
    f.check(RESULTS, "C: repeated execution succeeds",
            second.get("status") == "succeeded", json.dumps(second.get("reason")))
    after = units_for(b)
    f.check(RESULTS, "C: no duplicate belts, splitters or underground pairs",
            all(sorted(before[name]) == sorted(after[name]) for name in NAMES),
            json.dumps({"before": before, "after": after})[:800])
    coal_after = sum(item.get("count", 0) for item in
                     (h.chest_contents(details["coal_chest"]["unit"], b) or [])
                     if item.get("name") == "coal")
    f.check(RESULTS, "C: repeat did not fabricate or refill coal",
            coal_after <= coal_before,
            json.dumps({"before": coal_before, "after": coal_after}))


def scenario_d() -> None:
    print("\nScenario D - cancellation and a clean restart")
    b, plan, physical, details = f.prepare("s16d-cancel.zip")
    f.set_speed(b, 1)
    tid = f.start_expansion(b, plan, physical)
    h.wait(lambda: h.status(b)["task"].get("built_by_agent", 0) >= 8,
           timeout=240, interval=0.2, what="partial construction before cancel")
    cancelled = h.task_cancel(tid, "test_cancel", b)
    f.check(RESULTS, "D: task cancellation is terminal",
            cancelled.get("status") == "cancelled", json.dumps(cancelled.get("status")))
    f.set_speed(b, 60)
    tid2 = f.start_expansion(b, plan, physical)
    final = h.wait_task(tid2, b, timeout=600)
    f.check(RESULTS, "D: restart after cancellation succeeds",
            final.get("status") == "succeeded", json.dumps(final.get("reason")))
    expected = expected_counts(physical)
    actual = actual_counts(b)
    f.check(RESULTS, "D: restart builds exactly the planned entity set",
            all(actual.get(name, 0) == count for name, count in expected.items()),
            json.dumps({"expected": expected, "actual": actual}))


def scenario_e() -> None:
    print("\nScenario E - player-removed route is reported, not silently rebuilt")
    b, plan, physical, details = f.prepare("s16e-player-removed.zip")
    tid = f.start_expansion(b, plan, physical)
    first = h.wait_task(tid, b, timeout=600)
    f.check(RESULTS, "E: pre-removal production succeeds",
            first.get("status") == "succeeded", json.dumps(first.get("reason")))
    route = next(r for r in physical["connections"] if r["id"] == "ore_trunk")
    tile = route["belts"][1]["tile"]
    removed = h.lua(f"""
    local s = game.surfaces.nauvis
    local n = 0
    for _, e in pairs(s.find_entities_filtered{{
        area={{{{x={tile['x']},y={tile['y']}}},{{x={tile['x']}+1,y={tile['y']}+1}}}},
        name="transport-belt"}}) do e.destroy() n = n + 1 end
    rcon.print(n)
    """, b)
    f.check(RESULTS, "E: one agent belt was removed as a player change",
            int(removed or 0) == 1, str(removed))
    tid2 = f.start_expansion(b, plan, physical)
    second = h.wait_task(tid2, b, timeout=240)
    f.check(RESULTS, "E: missing route is not silently rebuilt",
            second.get("status") != "succeeded", json.dumps(second.get("reason")))
    rebuilt = h.entity_at("transport-belt", tile["x"] + 0.5, tile["y"] + 0.5, 0.1, b)
    ghosts = [g for g in h.ghosts(b, radius=80)
              if g["name"] == "transport-belt"
              and abs(g["position"]["x"] - (tile["x"] + 0.5)) < 0.1
              and abs(g["position"]["y"] - (tile["y"] + 0.5)) < 0.1]
    f.check(RESULTS, "E: no replacement ghost or real belt was created",
            rebuilt is None and not ghosts, h.pretty({"rebuilt": rebuilt, "ghosts": ghosts}))


def scenario_f() -> None:
    print("\nScenario F - safety pre-emption and explicit resume")
    b, plan, physical, details = f.prepare("s16f-safety.zip")
    f.set_speed(b, 1)
    tid = f.start_expansion(b, plan, physical)
    h.wait(lambda: h.status(b)["task"].get("built_by_agent", 0) >= 1,
           timeout=180, interval=0.2, what="first build before attack")
    h.spawn_attackers(3, 8.0, b)
    h.wait(lambda: h.status(b)["safety"].get("active") is True, timeout=120,
           interval=0.2, what="safety activation")
    paused = h.status(b)["task"]
    f.check(RESULTS, "F: task pauses for safety",
            paused.get("status") == "paused" and paused.get("reason") == "safety",
            json.dumps(paused)[:400])
    h.clear_enemies(b)
    h.wait(lambda: not h.status(b)["safety"].get("active"), timeout=120,
           interval=0.2, what="safety resolution")
    h.task_resume(tid, b)
    f.set_speed(b, 60)
    final = h.wait_task(tid, b, timeout=600)
    f.check(RESULTS, "F: resume after safety completes the expansion",
            final.get("status") == "succeeded", json.dumps(final.get("reason")))
    expected = expected_counts(physical)
    actual = actual_counts(b)
    f.check(RESULTS, "F: no duplicated infrastructure after safety recovery",
            all(actual.get(name, 0) == count for name, count in expected.items()),
            json.dumps({"expected": expected, "actual": actual}))


def scenario_g() -> None:
    print("\nScenario G - death, respawn and explicit resume")
    b, plan, physical, details = f.prepare("s16g-death.zip")
    f.set_speed(b, 5)
    tid = f.start_expansion(b, plan, physical)
    h.wait(lambda: h.status(b)["task"].get("built_by_agent", 0) >= 1,
           timeout=180, what="first build before death")
    h.agent_lua("a.die() return ''", b)
    h.wait(lambda: h.status(b)["lifecycle"]["status"] != "alive", timeout=30,
           what="death registered")
    paused = h.status(b)["task"]
    f.check(RESULTS, "G: task pauses with reason death",
            paused.get("status") == "paused" and paused.get("reason") == "death",
            json.dumps(paused)[:400])
    h.wait(lambda: h.status(b)["lifecycle"]["status"] == "alive", timeout=180,
           what="respawn")
    f.check(RESULTS, "G: task stays paused until explicit resume",
            h.status(b)["task"].get("status") == "paused")
    h.task_resume(tid, b)
    f.set_speed(b, 60)
    final = h.wait_task(tid, b, timeout=600)
    f.check(RESULTS, "G: resume after death completes the expansion",
            final.get("status") == "succeeded", json.dumps(final.get("reason")))
    expected = expected_counts(physical)
    actual = actual_counts(b)
    f.check(RESULTS, "G: no duplicated infrastructure after death recovery",
            all(actual.get(name, 0) == count for name, count in expected.items()),
            json.dumps({"expected": expected, "actual": actual}))


RESULTS: list[tuple[str, bool, str]] = []


def main() -> int:
    scenario_a()
    scenario_b()
    scenario_c()
    scenario_d()
    scenario_e()
    scenario_f()
    scenario_g()
    failed = [name for name, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:", failed)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
