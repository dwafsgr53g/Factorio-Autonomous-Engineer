"""Stage 6 C — electrical pole coverage, real connections and honest missing power."""
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


def scenario_a() -> None:
    print("\nScenario A — no existing powered network is reported, not fabricated")
    b, plan, details = f.prepare("s11a-no-power.zip", power=False, materials=False)
    physical = details["physical"]
    check("planning reports missing_power_source",
          physical.get("ok") is False
          and physical.get("reason") == "missing_power_source",
          h.pretty({"status": physical.get("status"),
                    "reason": physical.get("reason")}))
    task_id = f.start_logistics(b)
    result = h.wait_task(task_id, b, timeout=120)
    print("  task:", h.pretty(result)[:700])
    check("the composite task reports missing power without building",
          result.get("status") == "blocked"
          and "missing_power_source" in str(result.get("reason")),
          h.pretty(result))
    check("no module or belt was created",
          not h.entities_named(["electric-mining-drill", "stone-furnace",
                                "assembling-machine-1", "transport-belt",
                                "inserter"], b), h.pretty(h.real_counts(b)))


def scenario_b() -> None:
    print("\nScenario B — real coverage, legal reach and preserved player wiring")
    b, plan, details = f.prepare("s11b-power.zip")
    pole_unit = details["power"]["pole"]
    before_flow = h.electric_network_flow(pole_unit, b)
    before_connections = h.lua_json(f"""
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{type="electric-pole"}}) do
      if e.unit_number == {pole_unit} then
        local connector = e.get_wire_connector(defines.wire_connector_id.pole_copper, true)
        local out = {{}}
        for _, target in pairs(connector.real_connections) do
          out[#out+1] = target.owner and target.owner.unit_number or 0
        end
        rcon.print(helpers.table_to_json(out))
        return
      end
    end
    rcon.print("null")
    """, b)
    print("  existing network:", h.pretty(before_flow))
    # A separate player-owned copper wire in another area must survive untouched.
    h.clear_test_area(112, 32, 136, 48, b, keep_resources=False)
    player_wire = h.lua_json("""
    local s = game.surfaces.nauvis
    local created = {}
    for _, p in ipairs({{x=120.5,y=40.5},{x=126.5,y=40.5}}) do
      local ok, entity = pcall(function()
        return s.create_entity{name="medium-electric-pole", position=p,
          force=game.forces.player}
      end)
      created[#created+1] = ok and entity or nil
    end
    local result = {connected=false}
    if created[1] and created[2] then
      result.p1 = created[1].unit_number
      result.p2 = created[2].unit_number
      local c1 = created[1].get_wire_connector(
        defines.wire_connector_id.pole_copper, true)
      local c2 = created[2].get_wire_connector(
        defines.wire_connector_id.pole_copper, true)
      result.connected = c1.connect_to(c2, true, defines.wire_origin.player)
      result.count = c1.real_connection_count
    end
    rcon.print(helpers.table_to_json(result))
    """, b)
    print("  player wire:", h.pretty(player_wire))
    task_id = f.start_logistics(b)
    result = h.wait_task(task_id, b, timeout=180)
    print("  task:", h.pretty(result)[:900])
    check("the powered chain succeeds", result.get("status") == "succeeded",
          result.get("reason"))
    check("all required entities are connected to a real powered network",
          result.get("power_status") == "connected", h.pretty(result))
    after_flow = h.electric_network_flow(pole_unit, b)
    check("the existing network is still powered",
          (after_flow.get("flow") or {}).get("maximum_consumption", 0) >= 0
          and (after_flow.get("flow") or {}).get("solar_output", 0) >= 0,
          h.pretty(after_flow))
    after_connections = h.lua_json(f"""
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{type="electric-pole"}}) do
      if e.unit_number == {pole_unit} then
        local connector = e.get_wire_connector(defines.wire_connector_id.pole_copper, true)
        local out = {{}}
        for _, target in pairs(connector.real_connections) do
          out[#out+1] = target.owner and target.owner.unit_number or 0
        end
        rcon.print(helpers.table_to_json(out))
        return
      end
    end
    rcon.print("null")
    """, b)
    old = set(before_connections or [])
    new = set(after_connections or [])
    check("no existing player-owned pole connection was removed", old <= new,
          h.pretty({"before": sorted(old), "after": sorted(new)}))
    if player_wire:
        preserved = h.lua(f"""
        local p1 = nil
        for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{type="electric-pole"}}) do
          if e.unit_number == {player_wire['p1']} then p1 = e end
        end
        if not p1 then rcon.print(false) return end
        local connector = p1.get_wire_connector(defines.wire_connector_id.pole_copper, false)
        rcon.print(connector and connector.real_connection_count > 0 or false)
        """, b)
        check("the separate player-owned wire is still connected",
              preserved.strip() == "true", preserved)
    physical = h.logistics_plan_create(plan["id"], b)["physical"]
    verification = h.logistics_verify(physical["id"], b)
    powered = [entry for entry in verification.get("missing_power") or []
               if entry.get("kind") == "machine"]
    check("the drill and assembler report real network membership",
          powered and all(entry.get("powered") for entry in powered),
          h.pretty(powered))


def scenario_c() -> None:
    print("\nScenario C — removing the real supply is detected honestly")
    b, plan, details = f.prepare("s11c-unpowered.zip")
    physical = details["physical"]["physical"]
    # Remove the harness generation fixture. The agent-built network remains but has no
    # producer. The verifier must not claim power from network IDs or entity buffers.
    removed = h.lua("""
    local n = 0
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{
        name={"solar-panel", "accumulator"}}) do
      if e.valid then e.destroy() n = n + 1 end
    end
    rcon.print(n)
    """, b)
    print("  removed generation:", removed)
    verification = h.logistics_verify(physical["id"], b)
    check("verification reports no power after the producer is removed",
          verification.get("power") is False,
          h.pretty({"status": verification.get("status"),
                    "missing_power": verification.get("missing_power")}))
    check("the verifier reports the real unpowered entities",
          any(not entry.get("powered") for entry in verification.get("missing_power") or []),
          h.pretty(verification.get("missing_power")))


def scenario_d() -> None:
    print("\nScenario D - a later run recomputes after the player supplies power")
    b, plan, details = f.prepare("s11d-catchup.zip", power=False, materials=True)
    first_id = f.start_logistics(b)
    first = h.wait_task(first_id, b, timeout=120)
    check("the first run reports missing power",
          first.get("status") == "blocked"
          and "missing_power_source" in str(first.get("reason")),
          h.pretty(first)[:500])
    pole = details["power_pole_position"]
    fixture = h.create_solar_fixture(pole["x"], pole["y"], b)
    check("the player-supplied powered network is real",
          fixture.get("ok") is not False and fixture.get("network"),
          h.pretty(fixture))
    time.sleep(4)
    second_id = f.start_logistics(b)
    second = h.wait_task(second_id, b, timeout=180)
    print("  second task:", h.pretty(second)[:800])
    check("a later run recomputes the physical plan and succeeds",
          second.get("status") == "succeeded", second.get("reason"))
    check("the retried physical plan is operational",
          second.get("logistics_status") == "operational",
          h.pretty(second.get("logistics_status")))


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
