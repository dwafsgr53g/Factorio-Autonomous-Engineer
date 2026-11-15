"""Stage 5 Layout Planner: dependency graph, placement, persistence and MCP surface.

Run against disposable copies of the baseline save in the isolated engine profile:

    FACTORIO_RCON_PASSWORD=... uv run python tests/engine/s8_layout_planner.py

Every check prints its evidence and the script exits non-zero if any check fails.
"""
from __future__ import annotations

import json
import math
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402

RESULTS: list[tuple[str, bool, str]] = []

MINING = "nauvis.electric_mining.iron"
FURNACE = "nauvis.stone_furnace.iron_smelting"
ASSEMBLER = "nauvis.assembling_machine_1.gear"
FORBIDDEN_PUBLIC_KEYS = {
    "anchor", "bounds", "reserved", "ports", "entities", "position", "unit_number",
    "ghost_units", "instance_key", "surface_index", "center", "x", "y",
}


def check(name: str, condition: bool, detail: str = "") -> None:
    RESULTS.append((name, bool(condition), detail))
    print(f"  {'PASS' if condition else 'FAIL'} {name}" + (f" :: {detail}" if detail else ""))


def prepare(save: str) -> tuple[h.Bridge, dict]:
    """Disposable save, all research, one cleared iron patch and a nearby home."""
    h.load_scenario_save(save)
    b = h.bridge()
    h.research_all(b)
    h.clear_main_inventory(b)
    anchor = h.find_resource_anchor("iron-ore", 3, 3, 9, 240, b)
    assert anchor, "baseline has no suitable iron patch"
    h.clear_test_area(anchor["x"] - 26, anchor["y"] - 26,
                      anchor["x"] + 36, anchor["y"] + 36, b, keep_resources=True)
    h.set_home({"x": anchor["x"] + 1.5, "y": anchor["y"] + 1.5}, b)
    return b, anchor


def resource_amount(bounds: list[dict], b: h.Bridge) -> dict:
    code = f"""
    local out = {{amount=0, count=0}}
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{
        name="iron-ore", type="resource",
        area={{{{{bounds[0]['x']},{bounds[0]['y']}}},
               {{{bounds[1]['x']},{bounds[1]['y']}}}}}}}) do
      if e.valid and e.amount > 0 then out.amount=out.amount+e.amount out.count=out.count+1 end
    end
    rcon.print(helpers.table_to_json(out))
    """
    return h.lua_json(code, b) or {}


def point_in_bounds(point: dict, bounds: list[dict]) -> bool:
    return (bounds[0]["x"] <= point["x"] <= bounds[1]["x"]
            and bounds[0]["y"] <= point["y"] <= bounds[1]["y"])


def point_rect_distance(point: dict, bounds: list[dict]) -> float:
    x = min(max(point["x"], bounds[0]["x"]), bounds[1]["x"])
    y = min(max(point["y"], bounds[0]["y"]), bounds[1]["y"])
    return math.hypot(point["x"] - x, point["y"] - y)


def plan_modules(plan: dict, module_id: str) -> dict:
    return next(module for module in plan["modules"] if module["module_id"] == module_id)


def collect_keys(value) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        for key, item in value.items():
            found.add(key)
            found |= collect_keys(item)
    elif isinstance(value, list):
        for item in value:
            found |= collect_keys(item)
    return found


def scenario_a() -> None:
    print("\nScenario A — iron gear dependency graph and deterministic plan creation")
    b, anchor = prepare("s8a-plan.zip")
    before_inventory = h.snapshot(b)["main"]
    result = h.plan_layout("iron-gear-wheel", b=b)
    plan = result.get("plan", {})
    print("  plan:", h.pretty({
        "id": plan.get("id"), "status": plan.get("status"),
        "placement": plan.get("placement_status"), "reused": result.get("reused"),
        "order": plan.get("order"),
        "external": [(record["kind"], record["item"])
                     for record in plan.get("external_dependencies", [])],
    }))
    modules = {module["node_id"]: module for module in plan.get("modules", [])}
    check("the plan is created", result.get("ok") is True and bool(plan.get("id")),
          h.pretty(result.get("reason")))
    check("the three Stage-4 modules are selected",
          {module["module_id"] for module in modules.values()}
          == {MINING, FURNACE, ASSEMBLER}, h.pretty(list(modules)))
    check("dependency order is upstream to downstream",
          plan.get("order") == ["mining_1", "smelting_1", "production_1"],
          h.pretty(plan.get("order")))
    mining = plan_modules(plan, MINING)
    furnace = plan_modules(plan, FURNACE)
    assembler = plan_modules(plan, ASSEMBLER)
    check("mining footprint actually covers iron ore",
          resource_amount(mining["bounds"], b).get("amount", 0) >= 9,
          h.pretty(resource_amount(mining["bounds"], b)))
    check("furnace process recipe is inferred from live data",
          furnace["recipe"]["name"] == "iron-plate"
          and furnace["recipe"]["source"] == "inferred_output_recipe",
          h.pretty(furnace["recipe"]))
    check("gear recipe comes from the assembling machine",
          assembler["recipe"]["name"] == "iron-gear-wheel"
          and assembler["recipe"]["source"] == "entity_recipe",
          h.pretty(assembler["recipe"]))
    check("the plan is partial but ghost-materializable",
          plan.get("status") == "partial" and plan.get("placement_status") == "valid"
          and plan.get("materializable") is True,
          h.pretty({"status": plan.get("status"),
                    "placement": plan.get("placement_status")}))
    external = {(record["kind"], record["item"])
                for record in plan.get("external_dependencies", [])}
    check("coal fuel supply is an explicit missing dependency",
          ("fuel", "coal") in external, h.pretty(sorted(external)))
    check("electric infrastructure is an explicit missing dependency",
          ("infrastructure", "electric-network") in external, h.pretty(sorted(external)))
    check("two item connections need physical routing",
          plan["connection_counts"].get("route_required") == 2,
          h.pretty(plan["connection_counts"]))
    check("every routed edge carries a measurable port distance",
          all(edge.get("distance") is not None for edge in plan["edges"]
              if edge.get("status") == "route_required"),
          h.pretty([edge for edge in plan["edges"]
                    if edge.get("status") == "route_required"]))
    check("no ghost or real module was created by planning",
          len(h.ghosts(b)) == 0 and not h.entities_named(
              ["electric-mining-drill", "stone-furnace", "assembling-machine-1"], b),
          h.pretty(h.ghosts(b)))
    check("planning leaves the agent inventory unchanged",
          h.snapshot(b)["main"] == before_inventory,
          f"{before_inventory} -> {h.snapshot(b)['main']}")
    stored = h.layout_plan_status(plan["id"], b)
    check("the plan is persisted with the same fingerprint",
          stored.get("ok") is True
          and stored["plan"]["fingerprint"] == plan["fingerprint"],
          h.pretty(stored.get("plan", {}).get("fingerprint")))
    repeated = h.plan_layout("iron-gear-wheel", force_new=True, b=b)
    repeated_plan = repeated.get("plan", {})
    check("identical world and goal reproduce the same plan",
          repeated_plan.get("id") == plan["id"]
          and repeated_plan.get("fingerprint") == plan["fingerprint"]
          and [(m["node_id"], m["anchor"], m["orientation"])
               for m in repeated_plan.get("modules", [])]
          == [(m["node_id"], m["anchor"], m["orientation"])
              for m in plan.get("modules", [])],
          h.pretty({"id": repeated_plan.get("id"),
                    "fingerprint": repeated_plan.get("fingerprint")}))
    public = h.plan_layout_public("iron-gear-wheel", b)
    check("the public plan reuses the persisted plan id", public.get("plan_id") == plan["id"],
          h.pretty(public.get("plan_id")))
    leaked = FORBIDDEN_PUBLIC_KEYS & collect_keys(public)
    check("the public plan exposes no coordinates, ports or entity records",
          not leaked, h.pretty(sorted(leaked)))
    check("the public plan recommends no unsupported throughput claim",
          public.get("throughput_analysis") == "not_implemented",
          h.pretty(public.get("throughput_analysis")))
    mcp = subprocess.run(
        [sys.executable, str(Path(__file__).resolve().parent / "mcp_client.py"),
         "plan_layout", "iron-gear-wheel"],
        capture_output=True, text=True, cwd=h.ROOT, env={**os.environ}, timeout=90)
    mcp_payload = {}
    if mcp.returncode == 0 and mcp.stdout.strip():
        try:
            mcp_payload = json.loads(mcp.stdout.strip().splitlines()[-1])
        except ValueError:
            mcp_payload = {}
    print("  MCP plan_layout:", h.pretty(mcp_payload))
    check("the MCP plan_layout tool returns the compact plan",
          mcp.returncode == 0 and mcp_payload.get("plan_id") == plan["id"]
          and not (FORBIDDEN_PUBLIC_KEYS & collect_keys(mcp_payload)),
          mcp.stderr.strip()[-300:])


def scenario_b(b: h.Bridge) -> None:
    print("\nScenario B — every supported mining-module rotation")
    expected = {
        0: ((3, 4), 4), 90: ((4, 3), 8),
        180: ((3, 4), 12), 270: ((4, 3), 0),
    }
    ids = set()
    for orientation in (0, 90, 180, 270):
        result = h.plan_layout("iron-gear-wheel", force_new=True,
                               orientation_hints={MINING: orientation}, b=b)
        plan = result.get("plan", {})
        mining = plan_modules(plan, MINING)
        output = next(port for port in mining["ports"] if port["id"] == "ore_output")
        footprint = (mining["footprint"]["width"], mining["footprint"]["height"])
        ids.add(plan.get("id"))
        check(f"orientation {orientation} produces a materializable plan",
              plan.get("materializable") is True
              and plan.get("placement_status") == "valid",
              h.pretty(plan.get("unplaced")))
        check(f"orientation {orientation} preserves the module footprint and output",
              mining["orientation"] == orientation and footprint == expected[orientation][0]
              and output["direction"] == expected[orientation][1],
              h.pretty({"anchor": mining["anchor"], "footprint": footprint,
                        "output": output}))
        check(f"orientation {orientation} keeps the mining entity inside the footprint",
              point_in_bounds(output["position"], mining["bounds"]),
              h.pretty(output))
    check("all four orientations produce distinct deterministic plan identities",
          len(ids) == 4, h.pretty(sorted(ids)))
    check("rotation planning creates no ghosts", len(h.ghosts(b)) == 0)


def scenario_c(b: h.Bridge, anchor: dict) -> None:
    print("\nScenario C — existing buildings, player ghosts, players and natural obstacles")
    plan = h.plan_layout("iron-gear-wheel", force_new=True, b=b)["plan"]
    furnace = plan_modules(plan, FURNACE)
    centre = {"x": (furnace["bounds"][0]["x"] + furnace["bounds"][1]["x"]) / 2,
              "y": (furnace["bounds"][0]["y"] + furnace["bounds"][1]["y"]) / 2}
    chest = h.create_chest(centre["x"], centre["y"], {}, b)
    replanned = h.plan_layout("iron-gear-wheel", force_new=True, b=b)["plan"]
    check("an existing building is never covered by a replanned module",
          all(not point_in_bounds(chest["position"], module["bounds"])
              for module in replanned["modules"]),
          h.pretty([(module["node_id"], module["bounds"])
                    for module in replanned["modules"]]))
    applied = h.apply_layout(replanned["id"], b)
    check("a plan made around an existing building applies without stale rejection",
          applied.get("status") == "applied", h.pretty(applied))
    check("the existing building is unchanged",
          bool(h.entity_at("wooden-chest", chest["position"]["x"],
                           chest["position"]["y"], 2, b)))
    h.clear_test_area(anchor["x"] - 26, anchor["y"] - 26,
                      anchor["x"] + 36, anchor["y"] + 36, b, keep_resources=True)

    mining = plan_modules(plan, MINING)
    ghost_point = {"x": (mining["bounds"][0]["x"] + mining["bounds"][1]["x"]) / 2,
                   "y": (mining["bounds"][0]["y"] + mining["bounds"][1]["y"]) / 2}
    player_ghost = h.create_ghost("stone-furnace", ghost_point["x"], ghost_point["y"], b=b)
    ghost_plan = h.plan_layout("iron-gear-wheel", force_new=True, b=b)["plan"]
    check("an existing player construction ghost is never covered",
          all(not point_in_bounds(ghost_point, module["bounds"])
              for module in ghost_plan["modules"]),
          h.pretty([(module["node_id"], module["bounds"])
                    for module in ghost_plan["modules"]]))
    check("the player construction ghost remains in the world",
          any(item["unit"] == player_ghost["unit"] for item in h.ghosts(b)))
    check("the player ghost forces a different, deterministic plan",
          ghost_plan["id"] != plan["id"], h.pretty(ghost_plan["id"]))
    h.cancel_ghost(player_ghost["unit"], b)

    player = h.create_player_character(anchor["x"] + 12.5, anchor["y"] + 1.5, b)
    player_plan = h.plan_layout("iron-gear-wheel", force_new=True, b=b)["plan"]
    near = [(module["node_id"], round(point_rect_distance(player["position"],
                                                          module["bounds"]), 2))
            for module in player_plan["modules"]]
    safety_radius = h.bridge().call(
        "layout_planner_limits")["result"]["limits"]["player_safety_radius"]
    check("no placed module is inside the player's current work radius",
          all(distance > safety_radius for _, distance in near),
          h.pretty({"modules": near, "materializable": player_plan.get("materializable")}))
    h.remove_entity(player["unit"], b)

    trees = 0
    code = f"""
    local s = game.surfaces.nauvis
    local made = 0
    for x = {anchor['x']} - 2, {anchor['x']} + 4 do
      for y = {anchor['y']} - 2, {anchor['y']} + 4 do
        local ok, tree = pcall(function()
          return s.create_entity{{name="tree-05", position={{x=x+0.5,y=y+0.5}},
            force="neutral"}}
        end)
        if ok and tree then made = made + 1 end
      end
    end
    rcon.print(made)
    """
    trees = int(h.lua(code, b) or 0)
    clearing_plan = h.plan_layout("iron-gear-wheel", force_new=True, b=b)["plan"]
    print("  clearing plan:", h.pretty(clearing_plan.get("clearing")))
    check("natural trees are recorded as clearing preparation",
          trees > 0 and clearing_plan.get("placement_status") == "requires_clearing"
          and clearing_plan.get("clearing", {}).get("modules", 0) > 0,
          h.pretty(clearing_plan.get("clearing")))
    clearing_apply = h.apply_layout(clearing_plan["id"], b)
    check("a clearing-required plan still materializes only ghosts",
          clearing_apply.get("status") == "applied"
          and len(h.ghosts(b)) == len(clearing_plan["modules"]),
          h.pretty(clearing_apply))


def scenario_d() -> None:
    print("\nScenario D — ghost-only apply, idempotency, cancellation and save/load")
    b, anchor = prepare("s8d-apply.zip")
    plan = h.plan_layout("iron-gear-wheel", b=b)["plan"]
    pid = plan["id"]
    before_inventory = h.snapshot(b)["main"]
    before_real = h.entities_named(
        ["electric-mining-drill", "stone-furnace", "assembling-machine-1"], b)
    first = h.apply_layout_public(pid, b)
    ghosts = h.ghosts(b)
    tags = h.ghost_tags(b)
    print("  apply:", h.pretty(first))
    check("apply creates one ghost per selected module",
          first.get("status") == "applied" and first.get("created_module_count") == 3
          and len(ghosts) == 3, h.pretty(first))
    check("ghosts have the expected inner names",
          sorted(ghost["name"] for ghost in ghosts)
          == ["assembling-machine-1", "electric-mining-drill", "stone-furnace"],
          h.pretty([ghost["name"] for ghost in ghosts]))
    check("all ghosts carry the plan identity",
          {tag["tags"].get("ae_plan_id") for tag in tags} == {pid},
          h.pretty([tag["tags"] for tag in tags]))
    check("no real module entity was created",
          h.entities_named(
              ["electric-mining-drill", "stone-furnace", "assembling-machine-1"], b)
          == before_real)
    check("apply spends no inventory", h.snapshot(b)["main"] == before_inventory,
          f"{before_inventory} -> {h.snapshot(b)['main']}")
    instances = b.call("module_instances")["result"]["instances"]
    plan_instances = [item for item in instances if ":" + pid + ":" in item["key"]]
    check("all module instances are pending ghosts",
          len(plan_instances) == 3
          and all(item["status"] == "pending" for item in plan_instances),
          h.pretty([(item["key"], item["status"]) for item in plan_instances]))

    ghost_units = [ghost["unit"] for ghost in ghosts]
    second = h.apply_layout_public(pid, b)
    check("repeated apply is idempotent",
          second.get("status") == "already_applied"
          and second.get("created_module_count") == 0
          and [ghost["unit"] for ghost in h.ghosts(b)] == ghost_units,
          h.pretty(second))

    h.save_as("s8d-ghosts", b)
    h.stop_server()
    h.start_server("s8d-ghosts.zip")
    b = h.bridge()
    reloaded = h.layout_plan_status(pid, b)
    check("the plan survives save/load",
          reloaded.get("ok") is True
          and reloaded["plan"]["fingerprint"] == plan["fingerprint"]
          and reloaded["plan"]["application"]["status"] in {"applied", "already_applied"},
          h.pretty(reloaded.get("plan", {}).get("application")))
    check("ghost identities survive save/load",
          sorted(ghost["unit"] for ghost in h.ghosts(b)) == sorted(ghost_units)
          and {tag["tags"].get("ae_plan_id") for tag in h.ghost_tags(b)} == {pid},
          h.pretty(h.ghosts(b)))
    after_load = h.apply_layout_public(pid, b)
    check("apply after save/load stays idempotent",
          after_load.get("status") == "already_applied"
          and after_load.get("created_module_count") == 0, h.pretty(after_load))

    cancelled_unit = ghost_units[1]
    h.cancel_ghost(cancelled_unit, b)
    after_cancel = h.apply_layout(pid, b)
    check("a player-cancelled plan ghost is not recreated",
          after_cancel.get("status") == "partially_applied"
          and len(after_cancel.get("cancelled", [])) == 1
          and len(h.ghosts(b)) == 2, h.pretty(after_cancel))
    check("the cancelled ghost remains absent",
          not any(ghost["unit"] == cancelled_unit for ghost in h.ghosts(b)))

    remaining = h.ghosts(b)
    built_key = next(tag["tags"]["ae_instance_key"] for tag in h.ghost_tags(b)
                     if tag["unit"] == remaining[0]["unit"])
    built = h.build_ghost_as_player(remaining[0]["unit"], b)
    instance_after_build = h.module_instance_status(built_key, b)["instance"]
    after_build = h.apply_layout(pid, b)
    print("  built by player:", h.pretty(built), "| instance:", instance_after_build["status"])
    check("a player-built plan entity is recognised and not duplicated",
          instance_after_build["status"] == "built"
          and after_build.get("status") == "partially_applied"
          and len(after_build.get("cancelled", [])) == 1
          and len(h.entities_named([built["name"]], b)) >= 1,
          h.pretty(after_build))

    h.save_as("s8d-reconciled", b)
    h.stop_server()
    h.start_server("s8d-reconciled.zip")
    b = h.bridge()
    after_reload_apply = h.apply_layout(pid, b)
    check("cancel/build reconciliation survives save/load",
          after_reload_apply.get("status") == "partially_applied"
          and len(after_reload_apply.get("cancelled", [])) == 1,
          h.pretty(after_reload_apply))

    h.clear_test_area(anchor["x"] - 26, anchor["y"] - 26,
                      anchor["x"] + 36, anchor["y"] + 36, b, keep_resources=True)
    staged = h.place_plan("test_basic", b)
    check("the Stage-3 named ghost plan still works",
          staged.get("success") is True and len(h.ghosts(b)) == 3,
          h.pretty(staged))


def scenario_e() -> None:
    print("\nScenario E — stale plan rejection")
    b, anchor = prepare("s8e-stale-building.zip")
    plan = h.plan_layout("iron-gear-wheel", b=b)["plan"]
    furnace = plan_modules(plan, FURNACE)
    centre = {"x": (furnace["bounds"][0]["x"] + furnace["bounds"][1]["x"]) / 2,
              "y": (furnace["bounds"][0]["y"] + furnace["bounds"][1]["y"]) / 2}
    chest = h.create_chest(centre["x"], centre["y"], {}, b)
    stale = h.apply_layout(plan["id"], b)
    check("a new real building invalidates the stored plan",
          stale.get("status") == "stale_plan" and len(h.ghosts(b)) == 0,
          h.pretty(stale))
    check("the stale plan does not delete or overwrite the new building",
          bool(h.entity_at("wooden-chest", chest["position"]["x"],
                           chest["position"]["y"], 2, b)))
    check("stale rejection reports the changed world",
          "world_changed" in stale.get("reasons", []), h.pretty(stale.get("reasons")))

    b, anchor = prepare("s8e-stale-ghost.zip")
    plan = h.plan_layout("iron-gear-wheel", b=b)["plan"]
    mining = plan_modules(plan, MINING)
    point = {"x": (mining["bounds"][0]["x"] + mining["bounds"][1]["x"]) / 2,
             "y": (mining["bounds"][0]["y"] + mining["bounds"][1]["y"]) / 2}
    ghost = h.create_ghost("transport-belt", point["x"], point["y"], b=b)
    stale = h.apply_layout(plan["id"], b)
    check("a new player construction ghost invalidates the stored plan",
          stale.get("status") == "stale_plan" and len(h.ghosts(b)) == 1,
          h.pretty(stale))
    check("the player construction ghost is preserved",
          h.ghosts(b)[0]["unit"] == ghost["unit"])
    h.cancel_ghost(ghost["unit"], b)

    b, anchor = prepare("s8e-stale-player.zip")
    plan = h.plan_layout("iron-gear-wheel", b=b)["plan"]
    furnace = plan_modules(plan, FURNACE)
    centre = {"x": (furnace["bounds"][0]["x"] + furnace["bounds"][1]["x"]) / 2,
              "y": (furnace["bounds"][0]["y"] + furnace["bounds"][1]["y"]) / 2}
    player = h.create_player_character(centre["x"], centre["y"], b)
    stale = h.apply_layout(plan["id"], b)
    check("player activity at a planned site invalidates the stored plan",
          stale.get("status") == "stale_plan" and len(h.ghosts(b)) == 0,
          h.pretty(stale))
    h.remove_entity(player["unit"], b)

    b, anchor = prepare("s8e-stale-resource.zip")
    plan = h.plan_layout("iron-gear-wheel", b=b)["plan"]
    mining = plan_modules(plan, MINING)
    h.clear_test_area(mining["bounds"][0]["x"], mining["bounds"][0]["y"],
                      mining["bounds"][1]["x"], mining["bounds"][1]["y"], b,
                      keep_resources=False)
    stale = h.apply_layout(plan["id"], b)
    check("resource removal invalidates the mining placement",
          stale.get("status") == "stale_plan" and len(h.ghosts(b)) == 0,
          h.pretty(stale))


def main() -> int:
    scenario_a()
    print("\nScenario B — rotation coverage on the same disposable world")
    h.load_scenario_save("s8b-rotations.zip")
    b = h.bridge()
    h.research_all(b)
    h.clear_main_inventory(b)
    anchor = h.find_resource_anchor("iron-ore", 3, 3, 9, 240, b)
    h.clear_test_area(anchor["x"] - 26, anchor["y"] - 26,
                      anchor["x"] + 36, anchor["y"] + 36, b, keep_resources=True)
    h.set_home({"x": anchor["x"] + 1.5, "y": anchor["y"] + 1.5}, b)
    scenario_b(b)
    scenario_c(b, anchor)
    scenario_d()
    scenario_e()
    failed = [name for name, ok, _ in RESULTS if not ok]
    print("\nSUMMARY", h.pretty({"checks": len(RESULTS), "failed": failed}))
    print("RESULT", "PASS" if not failed else "FAIL")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
