"""Reference implementation of the Stage-5 layout planner for the unit suite.

The Factorio runtime in ``mod/factorio_autonomous_engineer/lib/layout_planner.lua`` is
authoritative. This module mirrors its deterministic, pure-data decisions over the same
canonical module definitions so the Python suite can test dependency graphs, port matching,
candidate generation, scoring, fingerprints, stale detection, persistence and idempotent
application without launching the game.

No module definitions are duplicated here. Only the small recipe/resource facts needed by
the unit suite live in this file; the engine test verifies the live Factorio recipe data.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
from collections.abc import Iterable
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from .module_format import (
    Environment,
    expand_geometry,
    load_module_files,
    module_paths,
    reference_environment,
    sequence,
)

CATEGORY_PRIORITY = {
    "mining": 0, "smelting": 1, "production": 2, "power": 3, "logistics": 4, "other": 5,
}
SCORING = {
    "connection_distance": 4,
    "center_distance": 1,
    "clearing_obstacle": 12,
    "crowding_obstacle": 2,
    "infrastructure_pole_bonus": 3,
    "nearby_player": 6,
}
TIE_BREAK_ORDER = (
    "score", "connection_distance", "center_distance", "clearing_count",
    "infrastructure_high", "orientation_ascending", "anchor_x", "anchor_y", "node_id",
)
PLAN_RADIUS = 64
PLAYER_SAFETY_RADIUS = 8
MAX_CANDIDATES = 96
MAX_RING = 24
RING_STEP = 2
EXPANSION_MARGIN = 6
INFRASTRUCTURE_RADIUS = 16
ELECTRIC_RADIUS = 16
PLANNING_GAP = 1
SCHEMA_VERSION = 1

REFERENCE_RECIPES: dict[str, dict[str, Any]] = {
    "iron-plate": {
        "categories": {"smelting"},
        "ingredients": [("item", "iron-ore", 1)],
        "products": [("item", "iron-plate", 1)],
    },
    "iron-gear-wheel": {
        "categories": {"crafting"},
        "ingredients": [("item", "iron-plate", 2)],
        "products": [("item", "iron-gear-wheel", 1)],
    },
}
REFERENCE_RESOURCES = {"iron-ore", "copper-ore", "coal", "stone", "uranium-ore"}
CLEARABLE_TYPES = {"tree", "rock"}
IGNORED_SIGNATURE_TYPES = {"item-entity", "corpse", "smoke", "fish", "character"}


class LayoutPlannerError(ValueError):
    """The reference planner cannot resolve the requested goal."""


# ---------------------------------------------------------------------------
# Geometry and world model
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Rect:
    left: float
    top: float
    right: float
    bottom: float

    @classmethod
    def from_anchor(cls, anchor: dict[str, float], footprint: dict[str, int]) -> Rect:
        return cls(anchor["x"], anchor["y"],
                   anchor["x"] + footprint["width"], anchor["y"] + footprint["height"])

    @classmethod
    def from_area(cls, area: list[dict[str, float]]) -> Rect:
        return cls(area[0]["x"], area[0]["y"], area[1]["x"], area[1]["y"])

    def overlaps(self, other: Rect) -> bool:
        return (self.left < other.right - 1e-9 and other.left < self.right - 1e-9
                and self.top < other.bottom - 1e-9 and other.top < self.bottom - 1e-9)

    def expanded(self, amount: float) -> Rect:
        return Rect(self.left - amount, self.top - amount,
                    self.right + amount, self.bottom + amount)

    def contains_point(self, point: tuple[float, float]) -> bool:
        return self.left <= point[0] <= self.right and self.top <= point[1] <= self.bottom

    def point_distance(self, point: tuple[float, float]) -> float:
        x = min(max(point[0], self.left), self.right)
        y = min(max(point[1], self.top), self.bottom)
        return math.hypot(point[0] - x, point[1] - y)

    def center(self) -> tuple[float, float]:
        return ((self.left + self.right) / 2, (self.top + self.bottom) / 2)

    def manhattan(self, point: tuple[float, float]) -> float:
        centre = self.center()
        return abs(centre[0] - point[0]) + abs(centre[1] - point[1])


@dataclass
class WorldEntity:
    name: str
    type: str
    x: float
    y: float
    width: float = 1.0
    height: float = 1.0
    unit: int = 0
    amount: int = 0
    tags: dict[str, str] = field(default_factory=dict)

    @property
    def rect(self) -> Rect:
        return Rect(self.x - self.width / 2, self.y - self.height / 2,
                    self.x + self.width / 2, self.y + self.height / 2)

    @property
    def position(self) -> tuple[float, float]:
        return (self.x, self.y)


@dataclass
class World:
    entities: list[WorldEntity] = field(default_factory=list)
    players: list[tuple[float, float]] = field(default_factory=list)
    terrain_blocked: set[tuple[float, float]] = field(default_factory=set)
    water: list[tuple[float, float]] = field(default_factory=list)

    def in_rect(self, box: Rect) -> Iterable[WorldEntity]:
        return [entity for entity in self.entities
                if box.overlaps(entity.rect) or box.contains_point(entity.position)]

    def blockers(self, box: Rect) -> list[WorldEntity]:
        return [entity for entity in self.in_rect(box)
                if entity.type not in {"resource", "entity-ghost", "item-entity",
                                       "corpse", "smoke", "fish", "character"}
                and entity.type not in CLEARABLE_TYPES]

    def clearable(self, box: Rect) -> list[WorldEntity]:
        return [entity for entity in self.in_rect(box) if entity.type in CLEARABLE_TYPES]

    def ghosts(self, box: Rect, ignore_plan_id: str | None = None) -> list[WorldEntity]:
        result = []
        for entity in self.in_rect(box):
            if entity.type != "entity-ghost":
                continue
            if ignore_plan_id and entity.tags.get("ae_plan_id") == ignore_plan_id:
                continue
            result.append(entity)
        return result

    def players_near(self, box: Rect, radius: float = PLAYER_SAFETY_RADIUS
                     ) -> list[tuple[float, float]]:
        expanded = box.expanded(radius)
        return [player for player in self.players if expanded.contains_point(player)]

    def poles_near(self, box: Rect, radius: float = ELECTRIC_RADIUS) -> int:
        expanded = box.expanded(radius)
        return sum(1 for entity in self.entities
                   if entity.type == "electric-pole" and expanded.overlaps(entity.rect))

    def resource_amount(self, resource: str, box: Rect) -> tuple[int, int]:
        amount, count = 0, 0
        for entity in self.in_rect(box):
            if entity.type == "resource" and entity.name == resource and entity.amount > 0:
                amount += entity.amount
                count += 1
        return amount, count

    def copy(self) -> World:
        return World(entities=copy.deepcopy(self.entities), players=list(self.players),
                     terrain_blocked=set(self.terrain_blocked), water=list(self.water))


# ---------------------------------------------------------------------------
# Module analysis and dependency resolution
# ---------------------------------------------------------------------------

@dataclass
class ModuleAnalysis:
    module_id: str
    module_version: int
    name: str
    category: str
    inputs: list[dict[str, Any]]
    outputs: list[dict[str, Any]]
    electric_inputs: list[dict[str, Any]]
    kind: str | None
    recipe: dict[str, str] | None
    auxiliary_inputs: list[dict[str, Any]] = field(default_factory=list)
    unsupported: str | None = None


def _port_record(port: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": port["id"], "type": port["type"], "role": port["role"],
        "item": port.get("item"), "fluid": port.get("fluid"),
        "connector": port.get("connector"),
    }


def _key(kind: str, name: str | None) -> str:
    return f"{kind}:{name}" if name is not None else kind


def ports_compatible(output: dict[str, Any], input_port: dict[str, Any]) -> bool:
    """A pure port-interface check. It never implies a physical connection."""
    if output.get("type") != input_port.get("type"):
        return False
    if output.get("type") == "electric":
        return True
    return (output.get("item") == input_port.get("item")
            and output.get("fluid") == input_port.get("fluid"))


def analyze_module(definition: dict[str, Any], env: Environment | None = None
                   ) -> ModuleAnalysis:
    env = env or reference_environment()
    expanded = expand_geometry(definition, {}, 0, env)
    inputs, outputs, electric_inputs = [], [], []
    for port in expanded["ports"]:
        record = _port_record(port)
        if port["type"] == "electric":
            if port["role"] in {"input", "bidirectional"}:
                electric_inputs.append(record)
            continue
        if port["role"] in {"input", "bidirectional"}:
            inputs.append(record)
        if port["role"] in {"output", "bidirectional"}:
            outputs.append(record)
    fixed = None
    for entity in sequence(definition["geometry"]["entities"]) or []:
        if entity.get("recipe"):
            if fixed and fixed != entity["recipe"]:
                return ModuleAnalysis(definition["id"], definition["module_version"],
                                      definition["name"], definition["category"],
                                      inputs, outputs, electric_inputs, None, None,
                                      unsupported="conflicting_entity_recipes")
            fixed = entity["recipe"]
    recipe_name, source = fixed, "entity_recipe" if fixed else None
    if fixed is None:
        output_keys = {_key(port["type"], port.get("item") or port.get("fluid"))
                       for port in outputs}
        candidates = []
        for name, recipe in sorted(REFERENCE_RECIPES.items()):
            products = {_key(kind, item) for kind, item, _ in recipe["products"]}
            if not output_keys & products:
                continue
            accepted = False
            for entity in sequence(definition["geometry"]["entities"]) or []:
                proto = env.entities.get(entity["name"])
                if proto and recipe["categories"] & proto.crafting_categories:
                    accepted = True
                    break
            if accepted:
                candidates.append(name)
        if len(candidates) == 1:
            recipe_name, source = candidates[0], "inferred_output_recipe"
        elif len(candidates) > 1:
            return ModuleAnalysis(definition["id"], definition["module_version"],
                                  definition["name"], definition["category"],
                                  inputs, outputs, electric_inputs, None, None,
                                  unsupported="ambiguous_recipe")
        else:
            if definition["category"] == "mining" and outputs and all(
                    port.get("item") in REFERENCE_RESOURCES for port in outputs):
                return ModuleAnalysis(definition["id"], definition["module_version"],
                                      definition["name"], definition["category"],
                                      inputs, outputs, electric_inputs, "extraction", None)
            return ModuleAnalysis(definition["id"], definition["module_version"],
                                  definition["name"], definition["category"],
                                  inputs, outputs, electric_inputs, None, None,
                                  unsupported="unsupported_production_step")
    recipe = REFERENCE_RECIPES[recipe_name]
    product_keys = {_key(kind, item) for kind, item, _ in recipe["products"]}
    for port in outputs:
        if _key(port["type"], port.get("item") or port.get("fluid")) not in product_keys:
            return ModuleAnalysis(definition["id"], definition["module_version"],
                                  definition["name"], definition["category"],
                                  inputs, outputs, electric_inputs, "recipe", None,
                                  unsupported="declared_output_not_in_recipe")
    ingredient_keys = {_key(kind, item) for kind, item, _ in recipe["ingredients"]}
    auxiliary = [port for port in inputs
                 if _key(port["type"], port.get("item") or port.get("fluid"))
                 not in ingredient_keys]
    return ModuleAnalysis(definition["id"], definition["module_version"], definition["name"],
                          definition["category"], inputs, outputs, electric_inputs,
                          "recipe", {"name": recipe_name, "source": source},
                          auxiliary_inputs=auxiliary)


@dataclass
class GraphNode:
    id: str
    module_id: str
    module_version: int
    name: str
    category: str
    inputs: list[dict[str, Any]]
    outputs: list[dict[str, Any]]
    electric_inputs: list[dict[str, Any]]
    recipe: dict[str, str] | None
    kind: str
    unsupported: str | None = None


@dataclass
class ProductionGraph:
    goal_item: str
    status: str
    nodes: list[GraphNode]
    order: list[str]
    edges: list[dict[str, Any]]
    missing: list[dict[str, Any]]
    external_dependencies: list[dict[str, Any]]
    producers: dict[str, list[str]]
    consumers: dict[str, list[str]]
    available_modules: list[dict[str, Any]]

    def node_by_id(self, node_id: str) -> GraphNode | None:
        return next((node for node in self.nodes if node.id == node_id), None)


def load_library(root: Path) -> tuple[list[dict[str, Any]], Environment]:
    modules, errors = load_module_files(module_paths(root))
    if errors:
        raise LayoutPlannerError(str(errors))
    return modules, reference_environment()


def _producer_index(analyses: dict[str, ModuleAnalysis]
                    ) -> tuple[dict[str, list[dict[str, Any]]],
                               dict[str, list[dict[str, Any]]]]:
    producers: dict[str, list[dict[str, Any]]] = {}
    consumers: dict[str, list[dict[str, Any]]] = {}
    for module_id in sorted(analyses):
        analysis = analyses[module_id]
        for port in analysis.outputs:
            producers.setdefault(_key(port["type"], port.get("item") or port.get("fluid")),
                                 []).append({"module_id": module_id, "port_id": port["id"]})
        for port in analysis.inputs:
            consumers.setdefault(_key(port["type"], port.get("item") or port.get("fluid")),
                                 []).append({"module_id": module_id, "port_id": port["id"]})
    return producers, consumers


def _choose_producer(producers: dict[str, list[dict[str, Any]]],
                     analyses: dict[str, ModuleAnalysis], key: str
                     ) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
    candidates = [candidate for candidate in producers.get(key, [])
                  if not analyses[candidate["module_id"]].unsupported]
    candidates.sort(key=lambda candidate: (
        CATEGORY_PRIORITY.get(analyses[candidate["module_id"]].category, 9),
        candidate["module_id"]))
    return (candidates[0] if candidates else None), candidates


def build_dependency_graph(goal_item: str, modules: list[dict[str, Any]],
                           env: Environment | None = None) -> ProductionGraph:
    env = env or reference_environment()
    if not any(item == goal_item for item in env.items):
        raise LayoutPlannerError(f"unknown goal item {goal_item!r}")
    analyses = {module["id"]: analyze_module(module, env) for module in modules}
    producers, consumers = _producer_index(analyses)
    goal_key = _key("item", goal_item)
    goal_producer, goal_candidates = _choose_producer(producers, analyses, goal_key)
    if not goal_producer:
        return ProductionGraph(
            goal_item=goal_item, status="unsupported", nodes=[], order=[], edges=[],
            missing=[{
                "code": "missing_supplier", "kind": "item", "item": goal_item,
                "external": True, "mandatory": True,
                "candidates": [candidate["module_id"] for candidate in goal_candidates],
            }],
            external_dependencies=[],
            producers={key: sorted({c["module_id"] for c in value})
                       for key, value in producers.items()},
            consumers={key: sorted({c["module_id"] for c in value})
                       for key, value in consumers.items()},
            available_modules=[])
    nodes: dict[str, GraphNode] = {}
    nodes_by_module: dict[str, str] = {}
    order: list[str] = []
    edges: list[dict[str, Any]] = []
    missing: dict[tuple, dict[str, Any]] = {}
    category_count: dict[str, int] = {}
    resolving: set[str] = set()

    def add_missing(record: dict[str, Any]) -> None:
        key = (record.get("code"), record.get("kind"), record.get("item"),
               record.get("node_id"), record.get("port_id"))
        missing.setdefault(key, record)

    def ensure(module_id: str) -> GraphNode | None:
        if module_id in nodes_by_module:
            return nodes[nodes_by_module[module_id]]
        if module_id in resolving:
            return None
        analysis = analyses[module_id]
        count = category_count.get(analysis.category, 0) + 1
        category_count[analysis.category] = count
        node = GraphNode(
            id=f"{analysis.category}_{count}", module_id=module_id,
            module_version=analysis.module_version, name=analysis.name,
            category=analysis.category, inputs=analysis.inputs, outputs=analysis.outputs,
            electric_inputs=analysis.electric_inputs, recipe=analysis.recipe,
            kind=analysis.kind or "unsupported", unsupported=analysis.unsupported,
        )
        nodes[node.id] = node
        nodes_by_module[module_id] = node.id
        if analysis.unsupported:
            add_missing({"code": "unsupported_production_step", "kind": "production",
                         "item": goal_item, "node_id": node.id, "external": False,
                         "mandatory": True, "reason": analysis.unsupported})
            order.append(node.id)
            return node
        resolving.add(module_id)
        for port in analysis.electric_inputs:
            edges.append({"from": "external:electric-network", "to": node.id,
                          "to_port": port["id"], "kind": "electric",
                          "status": "unresolved", "routing_required": False,
                          "physical_connection": False})
            add_missing({"code": "external_infrastructure", "kind": "infrastructure",
                         "item": "electric-network", "node_id": node.id,
                         "external": True, "mandatory": True})
        for port in analysis.inputs:
            key = _key(port["type"], port.get("item") or port.get("fluid"))
            producer, candidates = _choose_producer(producers, analyses, key)
            supplier = ensure(producer["module_id"]) if producer else None
            if supplier is not None:
                edges.append({"from": supplier.id, "from_port": producer["port_id"],
                              "to": node.id, "to_port": port["id"], "kind": port["type"],
                              "item": port.get("item") or port.get("fluid"),
                              "status": "route_required", "routing_required": True,
                              "physical_connection": False})
            else:
                auxiliary = port in analysis.auxiliary_inputs
                edges.append({"from": f"missing:{key}", "to": node.id,
                              "to_port": port["id"], "kind": port["type"],
                              "item": port.get("item") or port.get("fluid"),
                              "status": "missing_supplier", "routing_required": True,
                              "physical_connection": False})
                add_missing({"code": "missing_supplier",
                             "kind": "fuel" if auxiliary else port["type"],
                             "item": port.get("item") or port.get("fluid"),
                             "node_id": node.id, "external": True, "mandatory": True,
                             "candidates": [candidate["module_id"]
                                            for candidate in candidates]})
        resolving.discard(module_id)
        order.append(node.id)
        return node

    goal_node = ensure(goal_producer["module_id"])
    if goal_node:
        goal_port = next(port for port in goal_node.outputs
                         if port["type"] == "item" and port.get("item") == goal_item)
        edges.append({"from": goal_node.id, "from_port": goal_port["id"],
                      "to": "requested_output", "kind": "item", "item": goal_item,
                      "status": "requested_output", "routing_required": False,
                      "physical_connection": False})
    missing_list = sorted(missing.values(), key=lambda record: (
        record.get("code", ""), str(record.get("kind")), str(record.get("item")),
        str(record.get("node_id"))))
    external = [record for record in missing_list if record.get("external")]
    return ProductionGraph(
        goal_item=goal_item,
        status="partial" if missing_list else "complete",
        nodes=[nodes[node_id] for node_id in sorted(nodes)],
        order=order, edges=edges, missing=missing_list,
        external_dependencies=external,
        producers={key: sorted({c["module_id"] for c in value})
                   for key, value in producers.items()},
        consumers={key: sorted({c["module_id"] for c in value})
                   for key, value in consumers.items()},
        available_modules=[{"module_id": module["id"], "name": module["name"],
                            "category": module["category"]} for module in modules],
    )


# ---------------------------------------------------------------------------
# Candidate generation, scoring and plan creation
# ---------------------------------------------------------------------------

@dataclass
class PlacedModule:
    node_id: str
    module_id: str
    module_version: int
    name: str
    category: str
    recipe: dict[str, str] | None
    parameters: dict[str, Any]
    orientation: int
    anchor: dict[str, float]
    footprint: dict[str, int]
    bounds: list[dict[str, float]]
    reserved: list[dict[str, Any]]
    ports: list[dict[str, Any]]
    entities: list[dict[str, Any]]
    needs_clearing: bool
    clearable: dict[str, int]
    score: float
    score_terms: dict[str, float]


@dataclass
class LayoutPlan:
    schema_version: int
    plan_id: str
    goal_item: str
    fingerprint: str
    environment_signature: str
    status: str
    placement_status: str
    materializable: bool
    center: dict[str, float]
    modules: list[PlacedModule]
    order: list[str]
    edges: list[dict[str, Any]]
    external_dependencies: list[dict[str, Any]]
    connection_counts: dict[str, int]
    available_modules: list[dict[str, Any]]
    application: dict[str, Any] = field(default_factory=lambda: {
        "status": "not_applied", "instances": {}, "attempts": 0})
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> LayoutPlan:
        modules = [PlacedModule(**module) for module in value["modules"]]
        return cls(**{**value, "modules": modules})


def _digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def _port(ports: list[dict[str, Any]], port_id: str | None) -> dict[str, Any] | None:
    return next((port for port in ports if port["id"] == port_id), None)


def _orientation_variants(definition: dict[str, Any], env: Environment,
                          hints: dict[str, int] | None, node: GraphNode
                          ) -> list[tuple[int, dict[str, Any]]]:
    supported = sorted(sequence(definition["geometry"]["supported_orientations"]) or [])
    wanted = (hints or {}).get(node.module_id, (hints or {}).get(node.id))
    if wanted is not None:
        supported = [wanted] if wanted in supported else []
    return [(orientation, expand_geometry(definition, {}, orientation, env))
            for orientation in supported]


def _resource_constraints(definition: dict[str, Any]) -> list[dict[str, Any]]:
    return [constraint for constraint in
            (sequence(definition["placement"]["constraints"]) or [])
            if constraint["type"] == "resource_patch"]


def _constraint_failure(definition: dict[str, Any], box: Rect, world: World) -> bool:
    for constraint in sequence(definition["placement"]["constraints"]) or []:
        kind = constraint["type"]
        if kind == "resource_patch":
            amount, count = world.resource_amount(constraint["resource"], box)
            if (amount < constraint.get("minimum_amount", 1)
                    or count < constraint.get("minimum_entities", 1)):
                return True
        elif kind == "near_water":
            distance = constraint.get("max_distance", 32)
            if not any(box.expanded(distance).contains_point(tile) for tile in world.water):
                return True
        elif kind == "avoid_entities":
            names = set(constraint.get("names") or [])
            types = set(constraint.get("types") or [])
            for entity in world.in_rect(box):
                if entity.type == "entity-ghost":
                    continue
                if (names and entity.name in names) or (types and entity.type in types):
                    return True
        elif kind == "electric_network":
            if world.poles_near(box, constraint.get("max_distance", 16)) == 0:
                return True
    return False


def _ring_offsets() -> list[tuple[int, int]]:
    offsets = [(0, 0)]
    for radius in range(RING_STEP, MAX_RING + 1, RING_STEP):
        ring = []
        for x in range(-radius, radius + 1, RING_STEP):
            ring.extend([(x, -radius), (x, radius)])
        for y in range(-radius + RING_STEP, radius, RING_STEP):
            ring.extend([(-radius, y), (radius, y)])
        ring.sort(key=lambda offset: (abs(offset[0]) + abs(offset[1]), offset[0], offset[1]))
        offsets.extend(ring)
    return offsets


OFFSETS = _ring_offsets()


def _resource_candidates(world: World, center: tuple[float, float],
                         definition: dict[str, Any],
                         variants: list[tuple[int, dict[str, Any]]]
                         ) -> list[dict[str, Any]]:
    candidates, seen = [], set()
    constraints = _resource_constraints(definition)
    if not constraints:
        return candidates
    for constraint in constraints:
        resources = [entity for entity in world.entities
                     if entity.type == "resource" and entity.name == constraint["resource"]
                     and math.dist(entity.position, center) <= PLAN_RADIUS]
        resources.sort(key=lambda entity: (math.dist(entity.position, center),
                                           entity.x, entity.y, entity.unit))
        offsets = [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1),
                   (-1, 1), (1, 1), (-2, 0), (2, 0), (0, -2), (0, 2)]
        for resource in resources[:24]:
            for orientation, expanded in variants:
                width = expanded["footprint"]["width"]
                height = expanded["footprint"]["height"]
                base = (math.floor(resource.x - width / 2), math.floor(resource.y - height / 2))
                for dx, dy in offsets:
                    anchor = (base[0] + dx, base[1] + dy)
                    key = (anchor[0], anchor[1], orientation)
                    if key in seen:
                        continue
                    seen.add(key)
                    candidates.append({"anchor": anchor, "orientation": orientation,
                                       "expanded": expanded})
    return candidates


def _local_candidates(center: tuple[float, float],
                      focus_points: list[tuple[float, float]],
                      variants: list[tuple[int, dict[str, Any]]]
                      ) -> list[dict[str, Any]]:
    candidates, seen = [], set()
    for focus in focus_points:
        for orientation, expanded in variants:
            width = expanded["footprint"]["width"]
            height = expanded["footprint"]["height"]
            base = (math.floor(focus[0] - width / 2), math.floor(focus[1] - height / 2))
            for dx, dy in OFFSETS:
                anchor = (base[0] + dx, base[1] + dy)
                key = (anchor[0], anchor[1], orientation)
                if key in seen:
                    continue
                seen.add(key)
                centre = (anchor[0] + width / 2, anchor[1] + height / 2)
                candidates.append({
                    "anchor": anchor, "orientation": orientation,
                    "expanded": expanded,
                    "focus_distance": abs(centre[0] - focus[0]) + abs(centre[1] - focus[1]),
                    "center_distance": abs(centre[0] - center[0]) + abs(centre[1] - center[1]),
                })
    return candidates


def _limit_candidates(candidates: list[dict[str, Any]], center: tuple[float, float]
                      ) -> list[dict[str, Any]]:
    for candidate in candidates:
        if "center_distance" not in candidate:
            width = candidate["expanded"]["footprint"]["width"]
            height = candidate["expanded"]["footprint"]["height"]
            centre = (candidate["anchor"][0] + width / 2,
                      candidate["anchor"][1] + height / 2)
            candidate["center_distance"] = (abs(centre[0] - center[0])
                                            + abs(centre[1] - center[1]))
            candidate["focus_distance"] = candidate["center_distance"]
    candidates.sort(key=lambda candidate: (
        (candidate["focus_distance"] + candidate["center_distance"]) * 2,
        candidate["orientation"], candidate["anchor"][0], candidate["anchor"][1]))
    return candidates[:MAX_CANDIDATES]


def _connection_terms(node: GraphNode, expanded: dict[str, Any],
                      graph: ProductionGraph, placed: dict[str, PlacedModule]
                      ) -> tuple[float, float]:
    minimum, total = None, 0.0
    for edge in graph.edges:
        if edge["to"] != node.id or edge["from"] not in placed:
            continue
        supplier = placed[edge["from"]]
        source = _port(supplier.ports, edge.get("from_port"))
        target = _port(expanded["ports"], edge.get("to_port"))
        if source and target:
            value = (abs(source["position"]["x"] - target["position"]["x"])
                     + abs(source["position"]["y"] - target["position"]["y"]))
            total += value
            minimum = value if minimum is None else min(minimum, value)
    return minimum or 0.0, total


def _absolute(anchor: tuple[int, int], expanded: dict[str, Any], world: World
              ) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]],
                         list[dict[str, float]], dict[str, int]]:
    entities = [{**entity, "position": {"x": anchor[0] + entity["position"]["x"],
                                        "y": anchor[1] + entity["position"]["y"]}}
                for entity in expanded["entities"]]
    ports = [{**port, "position": {"x": anchor[0] + port["position"]["x"],
                                   "y": anchor[1] + port["position"]["y"]}}
             for port in expanded["ports"]]
    reserved = [{"id": area["id"],
                 "area": [{"x": anchor[0] + area["area"]["x"],
                           "y": anchor[1] + area["area"]["y"]},
                          {"x": anchor[0] + area["area"]["x"] + area["area"]["width"],
                           "y": anchor[1] + area["area"]["y"] + area["area"]["height"]}]}
                for area in expanded["reserved"]]
    bounds = [{"x": anchor[0], "y": anchor[1]},
              {"x": anchor[0] + expanded["footprint"]["width"],
               "y": anchor[1] + expanded["footprint"]["height"]}]
    clearable: dict[str, int] = {}
    box = Rect.from_area(bounds)
    for entity in world.clearable(box):
        clearable[entity.name] = clearable.get(entity.name, 0) + 1
    return entities, ports, reserved, bounds, clearable


def _evaluate_candidate(candidate: dict[str, Any], node: GraphNode,
                        definition: dict[str, Any], world: World,
                        center: tuple[float, float],
                        placed: dict[str, PlacedModule],
                        occupied: list[tuple[str, Rect, list[Rect]]],
                        graph: ProductionGraph) -> dict[str, Any] | None:
    anchor = candidate["anchor"]
    expanded = candidate["expanded"]
    bounds = [{"x": anchor[0], "y": anchor[1]},
              {"x": anchor[0] + expanded["footprint"]["width"],
               "y": anchor[1] + expanded["footprint"]["height"]}]
    box = Rect.from_area(bounds)
    if not (box.left >= center[0] - PLAN_RADIUS and box.top >= center[1] - PLAN_RADIUS
            and box.right <= center[0] + PLAN_RADIUS
            and box.bottom <= center[1] + PLAN_RADIUS):
        return None
    for reserved in expanded["reserved"]:
        area = [{"x": anchor[0] + reserved["area"]["x"],
                 "y": anchor[1] + reserved["area"]["y"]},
                {"x": anchor[0] + reserved["area"]["x"] + reserved["area"]["width"],
                 "y": anchor[1] + reserved["area"]["y"] + reserved["area"]["height"]}]
        rbox = Rect.from_area(area)
        if not (rbox.left >= center[0] - PLAN_RADIUS and rbox.top >= center[1] - PLAN_RADIUS
                and rbox.right <= center[0] + PLAN_RADIUS
                and rbox.bottom <= center[1] + PLAN_RADIUS):
            return None
    if world.blockers(box) or world.ghosts(box) or world.players_near(box):
        return None
    if _constraint_failure(definition, box, world):
        return None
    clearable = world.clearable(box)
    for reserved in expanded["reserved"]:
        reserved_box = Rect(anchor[0] + reserved["area"]["x"],
                            anchor[1] + reserved["area"]["y"],
                            anchor[0] + reserved["area"]["x"] + reserved["area"]["width"],
                            anchor[1] + reserved["area"]["y"] + reserved["area"]["height"])
        if (world.blockers(reserved_box) or world.ghosts(reserved_box)
                or world.players_near(reserved_box)):
            return None
    blocked_tiles = {tile for tile in world.terrain_blocked
                     if box.left <= tile[0] < box.right and box.top <= tile[1] < box.bottom}
    if blocked_tiles and not clearable:
        return None
    for _other_node, other_box, other_reserved in occupied:
        padded = other_box.expanded(PLANNING_GAP)
        if padded.overlaps(box):
            return None
        for reserved in expanded["reserved"]:
            area = Rect(anchor[0] + reserved["area"]["x"],
                        anchor[1] + reserved["area"]["y"],
                        anchor[0] + reserved["area"]["x"] + reserved["area"]["width"],
                        anchor[1] + reserved["area"]["y"] + reserved["area"]["height"])
            if padded.overlaps(area):
                return None
            if any(area.expanded(PLANNING_GAP).overlaps(other) for other in other_reserved):
                return None
        if any(box.overlaps(other.expanded(PLANNING_GAP)) for other in other_reserved):
            return None
    connection, total = _connection_terms(node, expanded, graph, placed)
    clearing = len(clearable)
    crowding = 0
    for entity in world.in_rect(box.expanded(EXPANSION_MARGIN)):
        if entity.type not in {"resource", "entity-ghost", "item-entity", "corpse",
                               "smoke", "fish", "character"}:
            crowding += 1
    infrastructure = world.poles_near(box, INFRASTRUCTURE_RADIUS)
    anchor_centre = box.center()
    center_distance = abs(anchor_centre[0] - center[0]) + abs(anchor_centre[1] - center[1])
    nearby_players = world.players_near(box)
    player_penalty = 0.0
    if nearby_players:
        nearest = min(box.point_distance(player) for player in nearby_players)
        if nearest <= PLAYER_SAFETY_RADIUS:
            return None
        player_penalty = max(0.0, 32.0 - nearest) * SCORING["nearby_player"]
    score = (connection * SCORING["connection_distance"]
             + center_distance * SCORING["center_distance"]
             + clearing * SCORING["clearing_obstacle"]
             + crowding * SCORING["crowding_obstacle"]
             + player_penalty
             - infrastructure * SCORING["infrastructure_pole_bonus"])
    return {
        "anchor": {"x": anchor[0], "y": anchor[1]}, "orientation": candidate["orientation"],
        "expanded": expanded, "score": score,
        "terms": {"connection_distance": connection, "connection_total": total,
                  "center_distance": center_distance, "clearing_count": clearing,
                  "crowding": crowding, "infrastructure": infrastructure,
                  "nearby_player": player_penalty},
        "needs_clearing": bool(clearable),
        "clearable": {entity.name: sum(1 for item in clearable if item.name == entity.name)
                      for entity in clearable},
    }


def _candidate_better(left: dict[str, Any], right: dict[str, Any]) -> bool:
    terms_left, terms_right = left["terms"], right["terms"]
    key_left = (left["score"], terms_left["connection_distance"],
                terms_left["center_distance"], terms_left["clearing_count"],
                -terms_left["infrastructure"], left["orientation"],
                left["anchor"]["x"], left["anchor"]["y"])
    key_right = (right["score"], terms_right["connection_distance"],
                 terms_right["center_distance"], terms_right["clearing_count"],
                 -terms_right["infrastructure"], right["orientation"],
                 right["anchor"]["x"], right["anchor"]["y"])
    return key_left < key_right


def _canonical_plan_text(plan: LayoutPlan) -> str:
    parts = [f"schema={plan.schema_version}", f"goal={plan.goal_item}"]
    for module in sorted(plan.modules, key=lambda item: item.node_id):
        params = ";".join(f"{key}={module.parameters[key]}"
                          for key in sorted(module.parameters))
        parts.append("module|" + "|".join([
            module.node_id, module.module_id, str(module.module_version),
            str(module.orientation), str(module.anchor["x"]), str(module.anchor["y"]),
            params,
        ]))
    for edge in sorted(plan.edges, key=lambda item: (
            str(item.get("to")), str(item.get("to_port")), str(item.get("from")),
            str(item.get("from_port")), str(item.get("kind")), str(item.get("item")))):
        parts.append("edge|" + "|".join(str(edge.get(key, "")) for key in (
            "from", "from_port", "to", "to_port", "kind", "item", "status")))
    return "\n".join(parts)


def _module_areas(module: PlacedModule) -> list[Rect]:
    return [Rect.from_area(module.bounds)] + [
        Rect.from_area(reserved["area"]) for reserved in module.reserved]


def _expected_plan_entity(module: PlacedModule, entity: WorldEntity) -> bool:
    for expected in module.entities:
        if expected["name"] == entity.name and math.dist(
                (expected["position"]["x"], expected["position"]["y"]), entity.position) <= 1.5:
            return True
    return False


def environment_signature(plan: LayoutPlan, world: World) -> str:
    keys: set[str] = set()
    for module in plan.modules:
        for box in _module_areas(module):
            for entity in world.in_rect(box):
                if entity.type in IGNORED_SIGNATURE_TYPES or entity.type in CLEARABLE_TYPES:
                    continue
                if entity.type == "entity-ghost" and entity.tags.get("ae_plan_id") == plan.plan_id:
                    continue
                if entity.type != "entity-ghost" and _expected_plan_entity(module, entity):
                    continue
                amount = entity.amount if entity.type == "resource" else 0
                keys.add(f"{entity.type}|{entity.name}|{entity.x}|{entity.y}|"
                         f"{entity.unit}|{amount}")
            for player in world.players_near(box):
                keys.add(f"player|{player[0]}|{player[1]}")
        for pole in world.entities:
            if pole.type == "electric-pole" and box.expanded(ELECTRIC_RADIUS).overlaps(pole.rect):
                keys.add(f"pole|{pole.unit}|{pole.name}")
    return _digest("\n".join(sorted(keys)))


def create_plan(goal_item: str, world: World, center: tuple[float, float],
                modules: list[dict[str, Any]], env: Environment | None = None,
                orientation_hints: dict[str, int] | None = None) -> LayoutPlan:
    env = env or reference_environment()
    graph = build_dependency_graph(goal_item, modules, env)
    by_id = {module["id"]: module for module in modules}
    order = list(dict.fromkeys(graph.order + [node.id for node in graph.nodes]))
    placed: dict[str, PlacedModule] = {}
    occupied: list[tuple[str, Rect, list[Rect]]] = []
    unplaced: list[str] = []
    for node_id in order:
        node = graph.node_by_id(node_id)
        if node is None or node.unsupported:
            unplaced.append(node_id)
            continue
        definition = by_id[node.module_id]
        variants = _orientation_variants(definition, env, orientation_hints, node)
        focus_points = [center]
        for edge in graph.edges:
            if edge["to"] == node.id and edge["from"] in placed:
                source = _port(placed[edge["from"]].ports, edge.get("from_port"))
                if source:
                    focus_points.append((source["position"]["x"], source["position"]["y"]))
        if _resource_constraints(definition):
            candidates = _resource_candidates(world, center, definition, variants)
        else:
            candidates = _local_candidates(center, focus_points, variants)
        best = None
        for candidate in _limit_candidates(candidates, center):
            choice = _evaluate_candidate(candidate, node, definition, world, center,
                                         placed, occupied, graph)
            if choice and (best is None or _candidate_better(choice, best)):
                best = choice
        if best is None:
            unplaced.append(node.id)
            continue
        entities, ports, reserved, bounds, clearable = _absolute(
            (best["anchor"]["x"], best["anchor"]["y"]), best["expanded"], world)
        module = PlacedModule(
            node_id=node.id, module_id=node.module_id,
            module_version=node.module_version, name=node.name, category=node.category,
            recipe=node.recipe, parameters=dict(best["expanded"]["parameters"]),
            orientation=best["orientation"], anchor=best["anchor"],
            footprint=best["expanded"]["footprint"], bounds=bounds, reserved=reserved,
            ports=ports, entities=entities, needs_clearing=best["needs_clearing"],
            clearable=best["clearable"], score=best["score"], score_terms=best["terms"],
        )
        placed[node.id] = module
        occupied.append((node.id, Rect.from_area(bounds),
                         [Rect.from_area(item["area"]) for item in reserved]))
    edges = []
    for edge in graph.edges:
        record = dict(edge)
        if edge["kind"] == "electric":
            target = placed.get(edge["to"])
            port = _port(target.ports, edge.get("to_port")) if target else None
            poles = world.poles_near(Rect.from_area(target.bounds)) if target else 0
            record["status"] = "externally_supplied" if poles else "missing_supplier"
            record["network_poles_in_radius"] = poles
            record["physical_connection"] = False
            record["to_position"] = port["position"] if port else None
            if target is None:
                record["status"] = "blocked"
                record["reason"] = "module_instance_unplaced"
        elif edge["to"] == "requested_output":
            source = placed.get(edge["from"])
            record["status"] = "requested_output" if source else "blocked"
            if source is None:
                record["reason"] = "module_instance_unplaced"
        elif (not edge["from"].startswith("missing:")
              and (edge["from"] not in placed or edge["to"] not in placed)):
            record["status"] = "blocked"
            record["reason"] = "module_instance_unplaced"
            record["physical_connection"] = False
        elif edge["from"] in placed and edge["to"] in placed:
            source = _port(placed[edge["from"]].ports, edge.get("from_port"))
            target = _port(placed[edge["to"]].ports, edge.get("to_port"))
            if source and target:
                record["from_position"] = source["position"]
                record["to_position"] = target["position"]
                record["distance"] = (abs(source["position"]["x"] - target["position"]["x"])
                                      + abs(source["position"]["y"] - target["position"]["y"]))
            else:
                record["status"] = "unsupported"
        record["physical_connection"] = False
        edges.append(record)
    external = []
    missing_power_nodes = {edge["to"] for edge in edges
                           if edge["kind"] == "electric"
                           and edge["status"] == "missing_supplier"}
    for record in graph.missing:
        if (record.get("kind") == "infrastructure"
                and record.get("item") == "electric-network"
                and record.get("node_id") not in missing_power_nodes):
            continue
        external.append({key: value for key, value in record.items()})
    counts = {status: 0 for status in (
        "compatible", "route_required", "externally_supplied", "missing_supplier",
        "unsupported", "blocked", "requested_output")}
    for edge in edges:
        counts[edge.get("status", "unsupported")] = (
            counts.get(edge.get("status", "unsupported"), 0) + 1)
    placement_valid = not unplaced
    needs_clearing = any(module.needs_clearing for module in placed.values())
    status = "invalid" if not placement_valid else (
        "partial" if external or needs_clearing or any(
            not record.get("external") for record in graph.missing) else "complete")
    placement_status = ("invalid" if not placement_valid
                        else "requires_clearing" if needs_clearing else "valid")
    plan = LayoutPlan(
        schema_version=SCHEMA_VERSION, plan_id="", goal_item=goal_item, fingerprint="",
        environment_signature="", status=status, placement_status=placement_status,
        materializable=placement_valid, center={"x": center[0], "y": center[1]},
        modules=[placed[node_id] for node_id in order if node_id in placed],
        order=order, edges=edges, external_dependencies=external,
        connection_counts=counts, available_modules=graph.available_modules,
        notes=["A layout plan is not an operational factory.",
               "Item and fluid connections still require physical belt/pipe routing.",
               "Electric network presence does not prove physical wire coverage.",
               "Furnace fuel supply is not provided by the current module catalog."],
    )
    plan.fingerprint = _digest(_canonical_plan_text(plan))
    plan.environment_signature = environment_signature(plan, world)
    plan.plan_id = "plan_" + _digest(plan.fingerprint + "|" + plan.environment_signature)[:16]
    return plan


# ---------------------------------------------------------------------------
# Lifecycle: revalidation, apply, persistence and public summary
# ---------------------------------------------------------------------------

def revalidate_plan(plan: LayoutPlan, world: World, modules: list[dict[str, Any]],
                    env: Environment | None = None) -> tuple[bool, list[str]]:
    env = env or reference_environment()
    reasons: list[str] = []
    if not plan.materializable:
        reasons.append("plan_invalid")
    if environment_signature(plan, world) != plan.environment_signature:
        reasons.append("world_changed")
    by_id = {module["id"]: module for module in modules}
    for module in plan.modules:
        if module.node_id in plan.application.get("instances", {}):
            continue
        definition = by_id.get(module.module_id)
        if definition is None:
            reasons.append(f"module_no_longer_available:{module.module_id}")
            continue
        variants = [(module.orientation, expand_geometry(definition, module.parameters,
                                                         module.orientation, env))]
        node = GraphNode(module.node_id, module.module_id, module.module_version,
                         module.name, module.category, [], [], [], module.recipe,
                         "recipe")
        graph = ProductionGraph(plan.goal_item, plan.status, [], [], plan.edges, [], [],
                                {}, {}, [])
        occupied = [(other.node_id, Rect.from_area(other.bounds),
                     [Rect.from_area(item["area"]) for item in other.reserved])
                    for other in plan.modules if other.node_id != module.node_id]
        choice = _evaluate_candidate(
            {"anchor": (module.anchor["x"], module.anchor["y"]),
             "orientation": module.orientation, "expanded": variants[0][1]},
            node, definition, world, (plan.center["x"], plan.center["y"]),
            {other.node_id: other for other in plan.modules
             if other.node_id != module.node_id},
            occupied, graph)
        if choice is None:
            reasons.append(f"placement_invalid:{module.node_id}")
    return not reasons, sorted(set(reasons))


def apply_plan_state(plan: LayoutPlan, world: World,
                     modules: list[dict[str, Any]] | None = None,
                     env: Environment | None = None) -> dict[str, Any]:
    if modules is not None:
        valid, reasons = revalidate_plan(plan, world, modules, env)
        if not valid:
            plan.application["status"] = "stale"
            plan.application["last_reasons"] = reasons
            return {"ok": False, "status": "stale_plan", "reasons": reasons,
                    "plan_id": plan.plan_id, "created": 0, "already": 0, "failed": 0}
    created = already = failed = cancelled = 0
    for module in plan.modules:
        instance = plan.application["instances"].get(module.node_id)
        if instance:
            already += 1
            continue
        plan.application["instances"][module.node_id] = {
            "instance_key": f"plan:{plan.plan_id}:{module.node_id}",
            "ghost_units": [1000 + len(plan.application["instances"]) + index
                            for index in range(len(module.entities))],
            "status": "pending",
        }
        for entity in module.entities:
            world.entities.append(WorldEntity(
                name=entity["name"], type="entity-ghost", x=entity["position"]["x"],
                y=entity["position"]["y"], unit=1000 + len(world.entities),
                tags={"ae_plan_id": plan.plan_id,
                      "ae_instance_key": f"plan:{plan.plan_id}:{module.node_id}"}))
        created += 1
    status = "applied" if created else "already_applied"
    plan.application["status"] = status
    plan.application["attempts"] = plan.application.get("attempts", 0) + 1
    return {"ok": True, "status": status, "plan_id": plan.plan_id,
            "created": created, "already": already, "failed": failed,
            "cancelled": cancelled}


def public_summary(plan: LayoutPlan) -> dict[str, Any]:
    unresolved = [{key: value for key, value in record.items()
                   if key in {"kind", "item", "node_id", "message"}}
                  for record in plan.external_dependencies]
    return {
        "ok": True,
        "plan_id": plan.plan_id,
        "goal_item": plan.goal_item,
        "fingerprint": plan.fingerprint,
        "plan_status": plan.status,
        "placement_status": plan.placement_status,
        "materializable": plan.materializable,
        "application_status": plan.application["status"],
        "modules": [{
            "instance_id": module.node_id, "module_id": module.module_id,
            "name": module.name, "category": module.category,
            "parameters": module.parameters, "recipe": module.recipe,
            "placement_status": "valid", "needs_clearing": module.needs_clearing,
        } for module in plan.modules],
        "available_modules": plan.available_modules,
        "connections": plan.connection_counts,
        "unresolved_dependencies": unresolved,
        "world_changed": False,
        "notes": plan.notes,
    }


def plan_to_json(plan: LayoutPlan) -> str:
    return json.dumps(plan.to_dict(), sort_keys=True, separators=(",", ":"))


def plan_from_json(value: str) -> LayoutPlan:
    return LayoutPlan.from_dict(json.loads(value))
