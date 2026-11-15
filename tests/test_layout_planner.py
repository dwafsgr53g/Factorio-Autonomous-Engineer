"""Unit tests for the Stage-5 dependency resolver and Layout Planner reference."""
from __future__ import annotations

import copy
import unittest
from pathlib import Path

from factorio_autonomous_engineer.layout_planner import (
    GraphNode,
    LayoutPlannerError,
    ProductionGraph,
    Rect,
    World,
    WorldEntity,
    _candidate_better,
    _evaluate_candidate,
    analyze_module,
    apply_plan_state,
    build_dependency_graph,
    create_plan,
    environment_signature,
    load_library,
    plan_from_json,
    plan_to_json,
    ports_compatible,
    public_summary,
    revalidate_plan,
)
from factorio_autonomous_engineer.module_format import expand_geometry

ROOT = Path(__file__).resolve().parents[1]
MOD_ROOT = ROOT / "mod" / "factorio_autonomous_engineer"
MODULES, ENV = load_library(MOD_ROOT)
BY_ID = {module["id"]: module for module in MODULES}
FURNACE = "nauvis.stone_furnace.iron_smelting"
MINING = "nauvis.electric_mining.iron"
ASSEMBLER = "nauvis.assembling_machine_1.gear"
CENTER = (20.0, 0.0)


def iron_world(*, entities: list[WorldEntity] | None = None) -> World:
    world = World(entities=list(entities or []))
    for x in range(28, 33):
        for y in range(-35, -30):
            world.entities.append(WorldEntity(
                name="iron-ore", type="resource", x=x + 0.5, y=y + 0.5, amount=50))
    return world


def plan(world: World, *, hints: dict[str, int] | None = None):
    return create_plan("iron-gear-wheel", world, CENTER, MODULES, ENV,
                       orientation_hints=hints)


def empty_graph(goal: str = "iron-gear-wheel") -> ProductionGraph:
    return ProductionGraph(goal, "complete", [], [], [], [], [], {}, {}, [])


def node_for(module_id: str = ASSEMBLER) -> GraphNode:
    analysis = analyze_module(BY_ID[module_id], ENV)
    return GraphNode("production_1", module_id, 1, analysis.name, analysis.category,
                     analysis.inputs, analysis.outputs, analysis.electric_inputs,
                     analysis.recipe, analysis.kind)


def candidate(module_id: str, anchor: tuple[int, int], orientation: int = 0):
    return {"anchor": anchor, "orientation": orientation,
            "expanded": expand_geometry(BY_ID[module_id], {}, orientation, ENV)}


class DependencyGraphTests(unittest.TestCase):
    def test_iron_gear_chain_resolves_the_three_catalog_modules(self):
        graph = build_dependency_graph("iron-gear-wheel", MODULES, ENV)
        self.assertEqual([node.id for node in graph.nodes],
                         ["mining_1", "production_1", "smelting_1"])
        self.assertEqual({node.module_id for node in graph.nodes},
                         {MINING, FURNACE, ASSEMBLER})
        self.assertEqual(graph.order, ["mining_1", "smelting_1", "production_1"])
        by_module = {node.module_id: node for node in graph.nodes}
        self.assertEqual(by_module[ASSEMBLER].recipe["name"], "iron-gear-wheel")
        self.assertEqual(by_module[FURNACE].recipe["name"], "iron-plate")
        self.assertEqual(by_module[MINING].kind, "extraction")

    def test_item_edges_follow_declared_ports(self):
        graph = build_dependency_graph("iron-gear-wheel", MODULES, ENV)
        ore = [edge for edge in graph.edges
               if edge.get("item") == "iron-ore" and edge["status"] == "route_required"]
        plates = [edge for edge in graph.edges
                  if edge.get("item") == "iron-plate" and edge["status"] == "route_required"]
        self.assertEqual(len(ore), 1)
        self.assertEqual(len(plates), 1)
        self.assertEqual(ore[0]["from"], "mining_1")
        self.assertEqual(ore[0]["to"], "smelting_1")
        self.assertEqual(plates[0]["from"], "smelting_1")
        self.assertEqual(plates[0]["to"], "production_1")

    def test_ports_match_only_on_type_identity_and_direction_compatibility(self):
        furnace = analyze_module(BY_ID[FURNACE], ENV)
        gear = analyze_module(BY_ID[ASSEMBLER], ENV)
        mining = analyze_module(BY_ID[MINING], ENV)
        plate_output = next(port for port in furnace.outputs if port["item"] == "iron-plate")
        plate_input = next(port for port in gear.inputs if port["item"] == "iron-plate")
        coal_input = next(port for port in furnace.inputs if port["item"] == "coal")
        ore_output = next(port for port in mining.outputs if port["item"] == "iron-ore")
        self.assertTrue(ports_compatible(plate_output, plate_input))
        self.assertFalse(ports_compatible(plate_output, coal_input))
        self.assertFalse(ports_compatible(ore_output, plate_input))
        self.assertFalse(ports_compatible(plate_output, gear.electric_inputs[0]))

    def test_missing_suppliers_and_external_dependencies_are_explicit(self):
        graph = build_dependency_graph("iron-gear-wheel", MODULES, ENV)
        coal = [record for record in graph.missing if record.get("item") == "coal"]
        power = [record for record in graph.missing
                 if record.get("item") == "electric-network"]
        self.assertTrue(coal and power)
        self.assertEqual(coal[0]["kind"], "fuel")
        self.assertEqual(power[0]["kind"], "infrastructure")
        self.assertTrue(any(record["kind"] == "fuel"
                            for record in graph.external_dependencies))
        self.assertTrue(any(record["kind"] == "infrastructure"
                            for record in graph.external_dependencies))
        self.assertEqual(graph.status, "partial")

    def test_unknown_goal_is_rejected(self):
        with self.assertRaises(LayoutPlannerError):
            build_dependency_graph("not-a-real-item", MODULES, ENV)

    def test_unsupported_goal_outputs_no_modules(self):
        graph = build_dependency_graph("iron-plate", [BY_ID[ASSEMBLER]], ENV)
        self.assertEqual(graph.nodes, [])
        self.assertEqual(graph.status, "unsupported")
        self.assertEqual(graph.missing[0]["code"], "missing_supplier")


class CandidateTests(unittest.TestCase):
    def test_resource_constraint_accepts_and_rejects(self):
        accepted = plan(iron_world())
        self.assertTrue(accepted.materializable, accepted.status)
        self.assertIn(MINING, {module.module_id for module in accepted.modules})
        empty = World()
        rejected = plan(empty)
        self.assertFalse(rejected.materializable)
        self.assertEqual(rejected.status, "invalid")
        self.assertNotIn(MINING, {module.module_id for module in rejected.modules})
        self.assertFalse(any(edge.get("item") == "iron-ore"
                             and edge.get("status") == "route_required"
                             for edge in rejected.edges))
        sparse = World(entities=[WorldEntity(name="iron-ore", type="resource",
                                             x=30.5, y=-32.5, amount=1)])
        sparse_plan = plan(sparse)
        self.assertFalse(sparse_plan.materializable)

    def test_candidate_generation_is_deterministic(self):
        first, second = plan(iron_world()), plan(iron_world())
        self.assertEqual(first.plan_id, second.plan_id)
        self.assertEqual(first.fingerprint, second.fingerprint)
        self.assertEqual(
            [(module.node_id, module.anchor, module.orientation, module.score)
             for module in first.modules],
            [(module.node_id, module.anchor, module.orientation, module.score)
             for module in second.modules])

    def test_scoring_terms_are_integer_deterministic_factors(self):
        created = plan(iron_world())
        for module in created.modules:
            self.assertIsInstance(module.score, (int, float))
            self.assertGreaterEqual(module.score_terms["clearing_count"], 0)
            self.assertGreaterEqual(module.score_terms["center_distance"], 0)
            self.assertGreaterEqual(module.score_terms["connection_distance"], 0)
            self.assertGreaterEqual(module.score_terms["crowding"], 0)

    def test_tie_breaking_order_is_documented_and_total(self):
        def choice(score=10, connection=0, centre=0, clearing=0, infrastructure=0,
                   orientation=0, x=1, y=1):
            return {"score": score, "orientation": orientation,
                    "anchor": {"x": x, "y": y},
                    "terms": {"connection_distance": connection, "center_distance": centre,
                              "clearing_count": clearing,
                              "infrastructure": infrastructure}}
        base = choice()
        self.assertTrue(_candidate_better(choice(score=9), base))
        self.assertTrue(_candidate_better(choice(connection=0), choice(connection=1)))
        self.assertTrue(_candidate_better(choice(centre=1), choice(centre=2)))
        self.assertTrue(_candidate_better(choice(clearing=1), choice(clearing=2)))
        self.assertTrue(_candidate_better(choice(infrastructure=2),
                                          choice(infrastructure=1)))
        self.assertTrue(_candidate_better(choice(orientation=0), choice(orientation=90)))
        self.assertTrue(_candidate_better(choice(x=1), choice(x=2)))
        self.assertTrue(_candidate_better(choice(y=1), choice(y=2)))
        self.assertFalse(_candidate_better(base, base))

    def test_all_supported_mining_orientations_are_planned(self):
        expected_footprints = {0: (3, 4), 90: (4, 3), 180: (3, 4), 270: (4, 3)}
        for orientation in (0, 90, 180, 270):
            created = plan(iron_world(), hints={MINING: orientation})
            mining = next(module for module in created.modules
                          if module.module_id == MINING)
            self.assertEqual(mining.orientation, orientation)
            self.assertEqual((mining.footprint["width"], mining.footprint["height"]),
                             expected_footprints[orientation])
            output = next(port for port in mining.ports if port["id"] == "ore_output")
            self.assertEqual(output["direction"], (4 + orientation // 90 * 4) % 16)
            rect = Rect.from_area(mining.bounds)
            self.assertTrue(rect.contains_point((output["position"]["x"],
                                                  output["position"]["y"])))

    def test_collisions_with_buildings_ghosts_players_and_reserved_areas(self):
        graph = empty_graph()
        node = node_for(ASSEMBLER)
        assembly = BY_ID[ASSEMBLER]
        anchor = (5, 5)
        occupied: list = []
        world = World()
        self.assertIsNotNone(_evaluate_candidate(
            candidate(ASSEMBLER, anchor), node, assembly, world, (0.0, 0.0),
            {}, occupied, graph))
        for blocker in (
            WorldEntity(name="wooden-chest", type="container", x=6.5, y=6.5, width=0.7),
            WorldEntity(name="stone-furnace", type="container", x=6.5, y=6.5, width=1.4),
        ):
            blocked = World(entities=[blocker])
            self.assertIsNone(_evaluate_candidate(
                candidate(ASSEMBLER, anchor), node, assembly, blocked, (0.0, 0.0),
                {}, occupied, graph))
        ghost = World(entities=[WorldEntity(name="stone-furnace", type="entity-ghost",
                                            x=6.5, y=6.5)])
        self.assertIsNone(_evaluate_candidate(
            candidate(ASSEMBLER, anchor), node, assembly, ghost, (0.0, 0.0),
            {}, occupied, graph))
        player = World(players=[(6.5, 6.5)])
        self.assertIsNone(_evaluate_candidate(
            candidate(ASSEMBLER, anchor), node, assembly, player, (0.0, 0.0),
            {}, occupied, graph))
        reserved_entity = World(entities=[WorldEntity(
            name="wooden-chest", type="container", x=6.5, y=8.5, width=0.7)])
        self.assertIsNone(_evaluate_candidate(
            candidate(ASSEMBLER, anchor), node, assembly, reserved_entity, (0.0, 0.0),
            {}, occupied, graph))

    def test_existing_planned_module_and_reserved_areas_cannot_overlap(self):
        graph = empty_graph()
        node = node_for(ASSEMBLER)
        assembly = BY_ID[ASSEMBLER]
        occupied = [("other", Rect.from_area([
            {"x": 4, "y": 4}, {"x": 9, "y": 9}]), [])]
        world = World()
        self.assertIsNone(_evaluate_candidate(
            candidate(ASSEMBLER, (5, 5)), node, assembly, world, (0.0, 0.0),
            {}, occupied, graph))
        self.assertIsNotNone(_evaluate_candidate(
            candidate(ASSEMBLER, (20, 20)), node, assembly, world, (0.0, 0.0),
            {}, [], graph))

    def test_natural_obstacles_are_clearing_requirements_not_hard_blockers(self):
        graph = empty_graph()
        node = node_for(ASSEMBLER)
        world = World(entities=[WorldEntity(name="tree", type="tree", x=6.5, y=6.5),
                                WorldEntity(name="rock", type="rock", x=7.5, y=7.5)])
        result = _evaluate_candidate(
            candidate(ASSEMBLER, (5, 5)), node, BY_ID[ASSEMBLER], world,
            (0.0, 0.0), {}, [], graph)
        self.assertIsNotNone(result)
        self.assertTrue(result["needs_clearing"])
        self.assertEqual(result["clearable"], {"tree": 1, "rock": 1})

    def test_player_work_radius_rejects_nearby_but_not_distant_players(self):
        graph = empty_graph()
        node = node_for(ASSEMBLER)
        near = World(players=[(9.0, 5.0)])
        self.assertIsNone(_evaluate_candidate(
            candidate(ASSEMBLER, (5, 5)), node, BY_ID[ASSEMBLER], near,
            (0.0, 0.0), {}, [], graph))
        far = World(players=[(40.0, 40.0)])
        self.assertIsNotNone(_evaluate_candidate(
            candidate(ASSEMBLER, (5, 5)), node, BY_ID[ASSEMBLER], far,
            (0.0, 0.0), {}, [], graph))


class PlanLifecycleTests(unittest.TestCase):
    def test_plan_is_partial_but_ghost_materializable(self):
        created = plan(iron_world())
        summary = public_summary(created)
        self.assertEqual(created.status, "partial")
        self.assertEqual(created.placement_status, "valid")
        self.assertTrue(created.materializable)
        self.assertEqual(summary["plan_status"], "partial")
        self.assertEqual(summary["placement_status"], "valid")
        unresolved = {(item["kind"], item["item"])
                      for item in summary["unresolved_dependencies"]}
        self.assertIn(("fuel", "coal"), unresolved)
        self.assertIn(("infrastructure", "electric-network"), unresolved)
        self.assertEqual(summary["connections"]["route_required"], 2)
        self.assertGreaterEqual(summary["connections"]["missing_supplier"], 3)

    def test_available_electric_network_is_reported_as_external_supply(self):
        world = iron_world()
        for x, y in ((26, -26), (34, -26), (42, -26), (34, -38), (42, -38)):
            world.entities.append(WorldEntity(
                name="medium-electric-pole", type="electric-pole", x=x, y=y, width=1))
        created = plan(world)
        power_edges = [edge for edge in created.edges if edge["kind"] == "electric"]
        self.assertTrue(power_edges)
        self.assertTrue(all(edge["status"] == "externally_supplied"
                            for edge in power_edges))
        self.assertFalse(any(record["kind"] == "infrastructure"
                             for record in created.external_dependencies))
        self.assertIn(("fuel", "coal"),
                      {(record["kind"], record["item"])
                       for record in created.external_dependencies})

    def test_public_summary_never_exposes_geometry(self):
        summary = public_summary(plan(iron_world()))

        def collect(value):
            found = set()
            if isinstance(value, dict):
                for key, item in value.items():
                    found.add(key)
                    found |= collect(item)
            elif isinstance(value, list):
                for item in value:
                    found |= collect(item)
            return found

        forbidden = {"anchor", "x", "y", "bounds", "reserved", "ports", "entities",
                     "position", "unit_number", "ghost_units", "instance_key",
                     "orientation", "surface_index", "center"}
        self.assertFalse(forbidden & collect(summary), forbidden & collect(summary))

    def test_fingerprint_and_environment_signature_are_stable(self):
        first, second = plan(iron_world()), plan(iron_world())
        self.assertEqual(first.fingerprint, second.fingerprint)
        self.assertEqual(first.environment_signature, second.environment_signature)
        self.assertEqual(environment_signature(first, iron_world()),
                         environment_signature(second, iron_world()))
        modified = iron_world()
        modified.entities.append(WorldEntity(
            name="wooden-chest", type="container", x=100, y=100))
        self.assertEqual(first.environment_signature,
                         environment_signature(second, modified))

    def test_stale_plan_rejects_world_changes_and_player_activity(self):
        world = iron_world()
        created = plan(world)
        self.assertTrue(revalidate_plan(created, world, MODULES, ENV)[0])
        smelting = next(module for module in created.modules if module.node_id == "smelting_1")
        centre = Rect.from_area(smelting.bounds).center()
        changed = copy.deepcopy(world)
        changed.entities.append(WorldEntity(
            name="wooden-chest", type="container", x=centre[0], y=centre[1], width=0.7))
        valid, reasons = revalidate_plan(created, changed, MODULES, ENV)
        self.assertFalse(valid)
        self.assertIn("world_changed", reasons)
        self.assertTrue(any(reason.startswith("placement_invalid:") for reason in reasons))
        result = apply_plan_state(created, changed, MODULES, ENV)
        self.assertEqual(result["status"], "stale_plan")
        self.assertEqual(len(changed.entities), len(world.entities) + 1)

        player_world = copy.deepcopy(world)
        player_world.players.append(centre)
        valid, reasons = revalidate_plan(created, player_world, MODULES, ENV)
        self.assertFalse(valid)
        self.assertIn("world_changed", reasons)

    def test_application_is_idempotent_and_ghost_only(self):
        world = iron_world()
        created = plan(world)
        before_items = [entity for entity in world.entities
                        if entity.type not in {"resource", "entity-ghost"}]
        first = apply_plan_state(created, world, MODULES, ENV)
        self.assertEqual(first["status"], "applied")
        self.assertEqual(first["created"], 3)
        ghost_count = sum(1 for entity in world.entities if entity.type == "entity-ghost")
        self.assertEqual(ghost_count, 3)
        self.assertEqual([entity for entity in world.entities
                          if entity.type not in {"resource", "entity-ghost"}], before_items)
        self.assertTrue(all(entity.tags.get("ae_plan_id") == created.plan_id
                            for entity in world.entities if entity.type == "entity-ghost"))
        self.assertTrue(revalidate_plan(created, world, MODULES, ENV)[0])
        second = apply_plan_state(created, world, MODULES, ENV)
        self.assertEqual(second["status"], "already_applied")
        self.assertEqual(second["created"], 0)
        self.assertEqual(second["already"], 3)
        self.assertEqual(sum(1 for entity in world.entities
                             if entity.type == "entity-ghost"), ghost_count)

    def test_persistence_round_trip_preserves_identity_and_state(self):
        world = iron_world()
        created = plan(world)
        apply_plan_state(created, world, MODULES, ENV)
        encoded = plan_to_json(created)
        restored = plan_from_json(encoded)
        self.assertEqual(restored.plan_id, created.plan_id)
        self.assertEqual(restored.fingerprint, created.fingerprint)
        self.assertEqual(restored.environment_signature, created.environment_signature)
        self.assertEqual(restored.application["instances"], created.application["instances"])
        self.assertEqual(public_summary(restored)["application_status"], "applied")
        self.assertEqual(plan_to_json(restored), encoded)

    def test_identical_world_and_goal_reproduce_the_same_plan_fingerprint(self):
        world_a, world_b = iron_world(), iron_world()
        first = plan(world_a)
        apply_plan_state(first, world_a, MODULES, ENV)
        second = plan(world_b)
        self.assertEqual(first.plan_id, second.plan_id)
        self.assertEqual(first.fingerprint, second.fingerprint)
        self.assertEqual(first.environment_signature, second.environment_signature)
        self.assertEqual(environment_signature(first, world_b),
                         environment_signature(second, world_b))


if __name__ == "__main__":
    unittest.main()
