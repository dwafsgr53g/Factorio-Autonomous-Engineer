"""Stage 4 module catalog, geometry, ghost instantiation, construction and persistence.

Run against a disposable copy of the baseline save in the isolated engine profile:

    uv run python tests/engine/s7_module_catalog.py

Every check prints its evidence and the script exits non-zero if any check fails.
"""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402

RESULTS: list[tuple[str, bool, str]] = []

FURNACE = "nauvis.stone_furnace.iron_smelting"
MINING = "nauvis.electric_mining.iron"
ASSEMBLER = "nauvis.assembling_machine_1.gear"
MODULES = (ASSEMBLER, MINING, FURNACE)


def check(name: str, condition: bool, detail: str = "") -> None:
    RESULTS.append((name, bool(condition), detail))
    print(f"  {'PASS' if condition else 'FAIL'} {name}" + (f" :: {detail}" if detail else ""))


def fresh(save: str, *, research: bool = True) -> h.Bridge:
    h.load_scenario_save(save)
    b = h.bridge()
    if research:
        h.research_all(b)
    h.clear_main_inventory(b)
    h.clear_test_area(-28, -48, 90, 40, b, keep_resources=True)
    return b


def destroy_ghosts_around(anchor: dict, radius: int = 10, b: h.Bridge | None = None) -> None:
    h.clear_test_area(anchor["x"] - radius, anchor["y"] - radius,
                      anchor["x"] + radius, anchor["y"] + radius, b, keep_resources=True)


def entity_details(names: list[str], b: h.Bridge) -> list[dict]:
    code = f"""
    local out = {{}}
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{
        name = {{{",".join(json.dumps(name) for name in names)}}}}}) do
      local recipe = nil
      if e.type == "assembling-machine" then
        local ok, value = pcall(function() return e.get_recipe() end)
        recipe = ok and value and value.name or nil
      end
      out[#out+1] = {{name=e.name, direction=e.direction, position=e.position,
        recipe=recipe, unit=e.unit_number}}
    end
    table.sort(out, function(a, b) return a.unit < b.unit end)
    rcon.print(helpers.table_to_json(out))
    """
    return h.lua_json(code, b) or []


def scenario_a() -> None:
    print("\nScenario A — catalog loading, stable ids and invalid definitions")
    b = fresh("s7a-catalog.zip", research=False)
    before = h.module_catalog(b)
    print("  catalog before research:", h.pretty({
        "loaded": before["loaded"], "invalid": before["invalid"],
        "errors": before["errors"],
    }))
    modules = {module["id"]: module for module in before["modules"]}
    check("all initial modules load", before["loaded"] == 3 and before["invalid"] == 0,
          h.pretty(before["errors"]))
    check("stable ids resolve", set(modules) == set(MODULES), h.pretty(list(modules)))
    check("furnace is available in the baseline force",
          modules[FURNACE]["available"] is True)
    check("electric mining drill is unavailable before research",
          modules[MINING]["available"] is False
          and any("electric-mining-drill" in reason
                  for reason in modules[MINING]["availability_reasons"]),
          h.pretty(modules[MINING]["availability_reasons"]))
    check("assembler is unavailable before automation",
          modules[ASSEMBLER]["available"] is False
          and any("automation" in reason for reason in modules[ASSEMBLER]["availability_reasons"]),
          h.pretty(modules[ASSEMBLER]["availability_reasons"]))

    h.research_all(b)
    after = h.module_catalog(b)
    modules_after = {module["id"]: module for module in after["modules"]}
    check("all modules become available after their requirements",
          all(modules_after[module_id]["available"] for module_id in MODULES),
          h.pretty({module_id: modules_after[module_id]["availability_reasons"]
                    for module_id in MODULES}))
    for module_id in MODULES:
        resolved = h.module_resolve(module_id, {"x": 20, "y": 20}, b=b)
        check(f"stable id resolves: {module_id}",
              resolved.get("ok") is True and resolved["module"]["id"] == module_id,
              h.pretty(resolved.get("details")))

    definition = h.module_definition(MINING, b)

    def mutate(label: str, change) -> tuple[str, dict]:
        invalid = copy.deepcopy(definition)
        change(invalid)
        return label, invalid

    cases = [
        mutate("schema version", lambda value: value.__setitem__("schema_version", 2)),
        mutate("unknown entity", lambda value: value["geometry"]["entities"][0]
               .__setitem__("name", "not-a-real-entity")),
        mutate("invalid direction", lambda value: value["geometry"]["entities"][0]
               .__setitem__("direction", 2)),
        mutate("invalid position", lambda value: value["geometry"]["entities"][0]
               .__setitem__("position", {"x": 1.25, "y": 1.5})),
        mutate("malformed footprint", lambda value: value["geometry"]["footprint"]
               .__setitem__("width", 0)),
        mutate("duplicate port id", lambda value: value["geometry"]["ports"][1]
               .__setitem__("id", value["geometry"]["ports"][0]["id"])),
        mutate("port outside footprint", lambda value: value["geometry"]["ports"][0]
               .__setitem__("position", {"x": 9, "y": 1.5})),
        mutate("unknown recipe", lambda value: value["requirements"]
               .__setitem__("recipes", ["not-a-recipe"])),
        mutate("unknown technology", lambda value: value["requirements"]
               .__setitem__("technologies", ["not-a-technology"])),
        mutate("unsupported entity field", lambda value: value["geometry"]["entities"][0]
               .__setitem__("insert_plan", {})),
        mutate("unsupported parameter type", lambda value: value["parameters"]
               .__setitem__("bad", {"type": "formula", "default": 1})),
    ]
    expected_codes = {
        "schema version": "unsupported_schema_version",
        "unknown entity": "unknown_entity_prototype",
        "invalid direction": "invalid_direction",
        "invalid position": "invalid_position",
        "malformed footprint": "invalid_dimension",
        "duplicate port id": "duplicate_port_id",
        "port outside footprint": "port_outside_footprint",
        "unknown recipe": "unknown_recipe",
        "unknown technology": "unknown_technology",
        "unsupported entity field": "unknown_field",
        "unsupported parameter type": "unsupported_parameter_type",
    }
    for label, invalid in cases:
        result = h.module_validate(invalid, b)
        found = {error["code"] for error in result.get("errors", [])}
        check(f"invalid definition rejected: {label}",
              result.get("ok") is False and expected_codes[label] in found,
              h.pretty(sorted(found)))


def scenario_b() -> None:
    print("\nScenario B — ghost instantiation of every supported module")
    b = fresh("s7b-ghosts.zip")
    mining_anchor = h.find_resource_anchor("iron-ore", 3, 3, 9, 200, b)
    check("a test resource footprint was found", mining_anchor is not None,
          h.pretty(mining_anchor))
    placements = []
    if mining_anchor:
        h.clear_test_area(mining_anchor["x"] - 3, mining_anchor["y"] - 3,
                          mining_anchor["x"] + 6, mining_anchor["y"] + 7, b,
                          keep_resources=True)
        placements.append((MINING, mining_anchor, 0, {}, 1,
                           ["electric-mining-drill"]))
    placements.extend([
        (FURNACE, {"x": 46, "y": 8}, 0, {"unit_count": 3}, 3, ["stone-furnace"]),
        (ASSEMBLER, {"x": 56, "y": 8}, 0, {}, 1, ["assembling-machine-1"]),
    ])
    for module_id, anchor, orientation, parameters, expected, names in placements:
        before = h.snapshot(b)["main"]
        result = h.module_instantiate(module_id, anchor, orientation=orientation,
                                      parameters=parameters,
                                      instance_key="s7b-" + module_id, b=b)
        ghosts = h.ghosts(b)
        real = h.entities_named(names, b)
        after = h.snapshot(b)["main"]
        print(f"  {module_id}:", h.pretty({
            "ok": result.get("ok"), "reason": result.get("reason"),
            "ghosts": len(ghosts), "real": len(real),
        }))
        check(f"{module_id} instantiates", result.get("ok") is True,
              h.pretty(result.get("details")))
        check(f"{module_id} creates only ghosts",
              len(ghosts) == expected and len(real) == 0,
              f"ghosts={len(ghosts)} real={len(real)}")
        check(f"{module_id} inventory unchanged", before == after,
              f"{before} -> {after}")
        check(f"{module_id} instance is pending",
              result["instance"]["status"] == "pending",
              h.pretty(result["instance"].get("counts")))
        destroy_ghosts_around(anchor, 14, b)


def scenario_c() -> None:
    print("\nScenario C — geometry, orientations, ports, reserved areas and collisions")
    b = fresh("s7c-geometry.zip")
    mining_anchor = h.find_resource_anchor("iron-ore", 3, 3, 9, 200, b)
    check("mining resource footprint", mining_anchor is not None, h.pretty(mining_anchor))
    if mining_anchor:
        h.clear_test_area(mining_anchor["x"] - 3, mining_anchor["y"] - 3,
                          mining_anchor["x"] + 6, mining_anchor["y"] + 7, b,
                          keep_resources=True)
        expected_output = {
            0: ({"x": 3, "y": 1.5}, 4, {"x": 0, "y": 3, "width": 3, "height": 1},
                {"x": 1.5, "y": 1.5}),
            90: ({"x": 2.5, "y": 3}, 8, {"x": 0, "y": 0, "width": 1, "height": 3},
                 {"x": 2.5, "y": 1.5}),
            180: ({"x": 0, "y": 2.5}, 12, {"x": 0, "y": 0, "width": 3, "height": 1},
                  {"x": 1.5, "y": 2.5}),
            270: ({"x": 1.5, "y": 0}, 0, {"x": 3, "y": 0, "width": 1, "height": 3},
                  {"x": 1.5, "y": 1.5}),
        }
        for orientation in (0, 90, 180, 270):
            resolved = h.module_resolve(MINING, mining_anchor, orientation=orientation, b=b)
            result = h.module_instantiate(
                MINING, mining_anchor, orientation=orientation,
                instance_key=f"s7c-mining-{orientation}", b=b)
            ghosts = [g for g in h.ghosts(b) if g["name"] == "electric-mining-drill"]
            (expected_local, expected_direction, expected_reserved,
             expected_entity) = expected_output[orientation]
            port = next((p for p in resolved.get("ports", [])
                         if p["id"] == "ore_output"), {})
            absolute_output = {"x": mining_anchor["x"] + expected_local["x"],
                               "y": mining_anchor["y"] + expected_local["y"]}
            reserved_area = resolved.get("reserved", [{}])[0].get("area", [])
            reserved_ok = False
            if reserved_area:
                reserved_ok = (
                    reserved_area[0]["x"] == mining_anchor["x"] + expected_reserved["x"]
                    and reserved_area[0]["y"] == mining_anchor["y"] + expected_reserved["y"]
                    and reserved_area[1]["x"] == mining_anchor["x"]
                    + expected_reserved["x"] + expected_reserved["width"]
                    and reserved_area[1]["y"] == mining_anchor["y"]
                    + expected_reserved["y"] + expected_reserved["height"])
            check(f"mining orientation {orientation} instantiates",
                  result.get("ok") is True and len(ghosts) == 1,
                  h.pretty(result.get("details")))
            check(f"mining orientation {orientation} ghost position and direction",
                  bool(ghosts) and ghosts[0]["position"] == {
                      "x": mining_anchor["x"] + expected_entity["x"],
                      "y": mining_anchor["y"] + expected_entity["y"]}
                  and ghosts[0]["direction"] == (orientation // 90 * 4) % 16,
                  h.pretty(ghosts))
            check(f"mining orientation {orientation} transformed output port",
                  port.get("position") == absolute_output
                  and port.get("direction") == expected_direction,
                  h.pretty(port))
            check(f"mining orientation {orientation} transformed reserved area",
                  reserved_ok, h.pretty(reserved_area))
            destroy_ghosts_around({"x": mining_anchor["x"], "y": mining_anchor["y"]}, 12, b)

        # A real entity in the footprint is a hard collision. Shift the anchor because
        # the same module/anchor/orientation is deliberately deduplicated above.
        blocked_anchor = {"x": mining_anchor["x"] + 1, "y": mining_anchor["y"]}
        h.create_chest(blocked_anchor["x"] + 1.5, blocked_anchor["y"] + 1.5, {}, b)
        blocked = h.module_instantiate(MINING, blocked_anchor,
                                       instance_key="s7c-blocked", b=b)
        check("collision with a real entity is reported",
              blocked.get("ok") is False
              and blocked.get("reason") in {"blocked_by_existing_entity", "reserved_area_blocked"},
              h.pretty(blocked))
        h.clear_test_area(mining_anchor["x"] - 3, mining_anchor["y"] - 3,
                          mining_anchor["x"] + 6, mining_anchor["y"] + 7, b,
                          keep_resources=True)

    # Furnace repeat expansion and port IDs.
    furnace_anchor = {"x": 46, "y": 8}
    h.clear_test_area(40, 2, 58, 18, b, keep_resources=False)
    resolved = h.module_resolve(FURNACE, furnace_anchor, orientation=0,
                                parameters={"unit_count": 3}, b=b)
    result = h.module_instantiate(FURNACE, furnace_anchor, orientation=0,
                                  parameters={"unit_count": 3},
                                  instance_key="s7c-furnace", b=b)
    ghosts = [g for g in h.ghosts(b) if g["name"] == "stone-furnace"]
    check("furnace bank instantiates three ghosts",
          result.get("ok") is True and len(ghosts) == 3, h.pretty(result.get("details")))
    check("furnace repeat positions are deterministic",
          [g["position"] for g in ghosts] == [
              {"x": furnace_anchor["x"] + 1, "y": furnace_anchor["y"] + 1},
              {"x": furnace_anchor["x"] + 3, "y": furnace_anchor["y"] + 1},
              {"x": furnace_anchor["x"] + 5, "y": furnace_anchor["y"] + 1},
          ], h.pretty(ghosts))
    check("furnace bank footprint is expanded",
          resolved["footprint"] == {"width": 6, "height": 2},
          h.pretty(resolved["footprint"]))
    port_ids = [port["id"] for port in resolved["ports"]]
    check("furnace ports are repeated with stable ids",
          {"ore_input", "ore_input_2", "ore_input_3",
           "plate_output", "plate_output_2", "plate_output_3",
           "fuel_input", "fuel_input_2", "fuel_input_3"} <= set(port_ids),
          h.pretty(port_ids))
    destroy_ghosts_around(furnace_anchor, 12, b)

    # Assembler reserved area and ports.
    assembler_anchor = {"x": 56, "y": 8}
    h.clear_test_area(50, 2, 70, 18, b, keep_resources=False)
    resolved = h.module_resolve(ASSEMBLER, assembler_anchor, b=b)
    result = h.module_instantiate(ASSEMBLER, assembler_anchor,
                                  instance_key="s7c-assembler", b=b)
    ghosts = [g for g in h.ghosts(b) if g["name"] == "assembling-machine-1"]
    reserved = resolved.get("reserved", [{}])[0].get("area", [])
    check("assembler instantiates one ghost",
          result.get("ok") is True and len(ghosts) == 1,
          h.pretty(result.get("details")))
    check("assembler ghost position and direction",
          bool(ghosts) and ghosts[0]["position"] == {
              "x": assembler_anchor["x"] + 1.5, "y": assembler_anchor["y"] + 1.5}
          and ghosts[0]["direction"] == 0, h.pretty(ghosts))
    check("assembler reserved area is returned",
          bool(reserved)
          and reserved[0] == {"x": assembler_anchor["x"], "y": assembler_anchor["y"] + 3}
          and reserved[1] == {"x": assembler_anchor["x"] + 3,
                              "y": assembler_anchor["y"] + 4},
          h.pretty(reserved))
    destroy_ghosts_around(assembler_anchor, 12, b)

    # A module that needs a resource must reject a clear site.
    h.clear_test_area(70, -20, 80, -10, b, keep_resources=False)
    off_resource = h.module_instantiate(MINING, {"x": 72, "y": -18},
                                        instance_key="s7c-off-resource", b=b)
    check("resource-dependent placement is rejected off-resource",
          off_resource.get("ok") is False
          and off_resource.get("reason") == "constraint_failed"
          and any(item.get("code") == "resource_patch_missing"
                  for item in off_resource.get("details", [])),
          h.pretty(off_resource))


def scenario_d() -> None:
    print("\nScenario D — existing paid construction builds module ghosts")
    b = fresh("s7d-build.zip")
    h.clear_test_area(36, 2, 56, 18, b, keep_resources=False)
    result = h.module_instantiate(FURNACE, {"x": 42, "y": 8}, orientation=0,
                                  parameters={"unit_count": 2},
                                  instance_key="s7d-furnace", b=b)
    check("furnace module ghosts placed", result.get("ok") is True,
          h.pretty(result.get("details")))
    h.give_items({"stone-furnace": 2}, b)
    before = h.snapshot(b)["main"]
    task = h.task_start({"task": "assist_construction"}, b)
    final = h.wait_task(task["task_id"], b, timeout=300)
    after = h.snapshot(b)["main"]
    details = entity_details(["stone-furnace"], b)
    status = h.module_instance_status("s7d-furnace", b)["instance"]
    print("  result:", h.pretty(final))
    print("  real:", h.pretty(details))
    print("  inventory:", h.pretty(after))
    check("furnace module construction succeeds", final.get("status") == "succeeded",
          final.get("reason"))
    check("both module entities are real exactly once", len(details) == 2,
          h.pretty(details))
    check("real positions and directions match the module",
          [(entity["position"], entity["direction"]) for entity in details] == [
              ({"x": 43, "y": 9}, 0), ({"x": 45, "y": 9}, 0)],
          h.pretty(details))
    check("exact items were consumed", before == {"stone-furnace": 2}
          and after == {}, f"{before} -> {after}")
    check("no ghosts remain", len(h.ghosts(b)) == 0)
    check("module instance is built", status.get("status") == "built",
          h.pretty(status.get("counts")))

    # Assembler recipe configuration survives the paid revival.
    b = fresh("s7d-assembler.zip")
    h.clear_test_area(36, 2, 60, 18, b, keep_resources=False)
    result = h.module_instantiate(ASSEMBLER, {"x": 46, "y": 8}, orientation=0,
                                  instance_key="s7d-assembler", b=b)
    check("assembler module ghosts placed", result.get("ok") is True,
          h.pretty(result.get("details")))
    h.give_items({"assembling-machine-1": 1}, b)
    before = h.snapshot(b)["main"]
    task = h.task_start({"task": "assist_construction"}, b)
    final = h.wait_task(task["task_id"], b, timeout=300)
    after = h.snapshot(b)["main"]
    details = entity_details(["assembling-machine-1"], b)
    status = h.module_instance_status("s7d-assembler", b)["instance"]
    print("  assembler result:", h.pretty(final))
    print("  assembler real:", h.pretty(details))
    check("assembler module construction succeeds", final.get("status") == "succeeded",
          final.get("reason"))
    check("assembler recipe was applied after revival",
          len(details) == 1 and details[0]["recipe"] == "iron-gear-wheel",
          h.pretty(details))
    check("assembler configuration errors are absent",
          final.get("configuration_errors") == 0, h.pretty(final))
    check("assembler exact items were consumed", before == {"assembling-machine-1": 1}
          and after == {}, f"{before} -> {after}")
    check("assembler module instance is built",
          status.get("status") == "built" and status["entities"][0]["recipe"]
          == "iron-gear-wheel", h.pretty(status))


def scenario_e() -> None:
    print("\nScenario E — save/load, instance identity and construction resume")
    b = fresh("s7e-save.zip")
    h.clear_test_area(36, 2, 60, 18, b, keep_resources=False)
    result = h.module_instantiate(FURNACE, {"x": 42, "y": 8}, orientation=0,
                                  parameters={"unit_count": 2},
                                  instance_key="s7e-instance", b=b)
    check("module ghosts placed before save", result.get("ok") is True
          and len(h.ghosts(b)) == 2, h.pretty(result.get("details")))
    print("  save:", repr(h.save_as("s7e-mid", b)))
    h.stop_server()
    h.start_server("s7e-mid.zip")
    b = h.bridge()
    status = h.module_instance_status("s7e-instance", b)["instance"]
    instances = h.module_instances(b)
    check("instance identity survives save/load",
          status.get("key") == "s7e-instance" and status.get("module_id") == FURNACE,
          h.pretty(status))
    check("instance status remains pending after load",
          status.get("status") == "pending", h.pretty(status.get("counts")))
    check("ghost count remains exact after load", len(h.ghosts(b)) == 2,
          h.pretty(h.ghosts(b)))
    duplicate = h.module_instantiate(FURNACE, {"x": 42, "y": 8}, orientation=0,
                                     parameters={"unit_count": 2},
                                     instance_key="s7e-instance", b=b)
    check("re-instantiation with the same key is deduplicated",
          duplicate.get("ok") is True and duplicate.get("deduplicated") is True
          and len(h.ghosts(b)) == 2, h.pretty(duplicate))
    check("no duplicate instance record was created", len(instances) == 1,
          h.pretty(instances))

    h.give_items({"stone-furnace": 2}, b)
    task = h.task_start({"task": "assist_construction"}, b)
    h.wait(lambda: h.status(b)["task"].get("phase") in {"moving", "pathing"}
           and h.status(b)["task"].get("status") == "running",
           timeout=90, interval=0.25, what="construction task moving")
    print("  save during construction:", repr(h.save_as("s7e-task", b)))
    h.stop_server()
    h.start_server("s7e-task.zip")
    b = h.bridge()
    resumed = h.task_status(task["task_id"], b)
    check("construction task id survives the second load",
          resumed.get("task_id") == task["task_id"], h.pretty(resumed))
    final = h.wait_task(task["task_id"], b, timeout=300)
    after = h.snapshot(b)["main"]
    details = entity_details(["stone-furnace"], b)
    status = h.module_instance_status("s7e-instance", b)["instance"]
    print("  final:", h.pretty(final))
    print("  real:", h.pretty(details))
    check("construction resumes and succeeds after load",
          final.get("status") == "succeeded", final.get("reason"))
    check("two furnaces exist exactly once", len(details) == 2, h.pretty(details))
    check("materials were consumed exactly once", after == {}, h.pretty(after))
    check("no ghosts remain", len(h.ghosts(b)) == 0)
    check("module instance is built after resume", status.get("status") == "built",
          h.pretty(status.get("counts")))


def main() -> int:
    scenario_a()
    scenario_b()
    scenario_c()
    scenario_d()
    scenario_e()
    failed = [name for name, ok, _ in RESULTS if not ok]
    print("\nSUMMARY", h.pretty({"checks": len(RESULTS), "failed": failed}))
    print("RESULT", "PASS" if not failed else "FAIL")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
