"""Strict reader and reference validator for the declarative Lua module format.

The Factorio runtime is authoritative for prototype data and engine availability. This
module parses the same canonical Lua data files without executing them, so the Python unit
suite can validate schema, catalog identity, parameters and coordinate transforms. It
deliberately implements only pure data tables: functions, calls and expressions are rejected.
"""
from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
MANIFEST_SCHEMA_VERSION = 1
SUPPORTED_ORIENTATIONS = (0, 90, 180, 270)
CATEGORIES = {"mining", "smelting", "power", "production", "logistics", "other"}
STAGE_ORDER = {
    "early_game": 1,
    "automation_bootstrap": 2,
    "automation": 3,
    "oil_processing": 4,
    "advanced_industry": 5,
    "space_age": 6,
}
ENTITY_TYPES = {
    "mining-drill",
    "furnace",
    "assembling-machine",
    "transport-belt",
    "container",
    "electric-pole",
    "inserter",
}
PORT_TYPES = {"item", "fluid", "electric"}
PORT_ROLES = {"input", "output", "bidirectional"}
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.-]*$")
ENTITY_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")


class LuaParseError(ValueError):
    """The file is not a pure declarative Lua data table."""


@dataclass(frozen=True)
class EntityPrototype:
    type: str
    items_to_place_this: tuple[str, ...] = ()
    crafting_categories: frozenset[str] = frozenset()
    half_width: float = 0.5
    half_height: float = 0.5


@dataclass(frozen=True)
class RecipePrototype:
    categories: frozenset[str] = frozenset()


@dataclass
class Environment:
    entities: dict[str, EntityPrototype] = field(default_factory=dict)
    items: set[str] = field(default_factory=set)
    fluids: set[str] = field(default_factory=set)
    recipes: dict[str, RecipePrototype] = field(default_factory=dict)
    technologies: set[str] = field(default_factory=set)
    qualities: set[str] = field(default_factory=lambda: {"normal"})


@dataclass(frozen=True)
class Diagnostic:
    code: str
    path: str
    message: str

    def as_dict(self) -> dict[str, str]:
        return {"code": self.code, "path": self.path, "message": self.message}


# ---------------------------------------------------------------------------
# Declarative Lua data parser
# ---------------------------------------------------------------------------

_TOKEN_RE = re.compile(
    r"""
    (?P<space>\s+)
  | (?P<line_comment>--[^\n]*)
  | (?P<long_comment>--\[\[.*?\]\])
  | (?P<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')
  | (?P<number>-?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<symbol>[{}\[\]=,;])
    """,
    re.VERBOSE | re.DOTALL,
)


def _decode_string(token: str) -> str:
    body = token[1:-1]
    result: list[str] = []
    index = 0
    escapes = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"', "'": "'"}
    while index < len(body):
        char = body[index]
        if char != "\\":
            result.append(char)
            index += 1
            continue
        index += 1
        if index >= len(body):
            raise LuaParseError("unterminated string escape")
        escaped = body[index]
        if escaped in escapes:
            result.append(escapes[escaped])
            index += 1
        elif escaped.isdigit():
            end = index
            while end < len(body) and end - index < 3 and body[end].isdigit():
                end += 1
            result.append(chr(int(body[index:end])))
            index = end
        else:
            raise LuaParseError(f"unsupported string escape \\{escaped}")
    return "".join(result)


class _Parser:
    def __init__(self, source: str) -> None:
        self.tokens: list[tuple[str, str, int]] = []
        position = 0
        while position < len(source):
            match = _TOKEN_RE.match(source, position)
            if not match:
                raise LuaParseError(f"invalid Lua data near: {source[position:position + 40]!r}")
            position = match.end()
            kind = match.lastgroup or ""
            if kind in {"space", "line_comment", "long_comment"}:
                continue
            self.tokens.append((kind, match.group(), match.start()))
        self.index = 0

    def peek(self) -> tuple[str, str, int] | None:
        return self.tokens[self.index] if self.index < len(self.tokens) else None

    def take(self, value: str | None = None) -> tuple[str, str, int]:
        token = self.peek()
        if token is None:
            raise LuaParseError("unexpected end of file")
        if value is not None and token[1] != value:
            raise LuaParseError(f"expected {value!r}, got {token[1]!r}")
        self.index += 1
        return token

    def parse_file(self) -> Any:
        self.take("return")
        value = self.parse_value()
        while self.peek() is not None and self.peek()[1] == ";":
            self.take(";")
        if self.peek() is not None:
            raise LuaParseError(f"unexpected token {self.peek()[1]!r}")
        return value

    def parse_value(self) -> Any:
        token = self.peek()
        if token is None:
            raise LuaParseError("unexpected end of file")
        kind, text, _ = token
        if text == "{":
            return self.parse_table()
        if kind == "string":
            self.take()
            return _decode_string(text)
        if kind == "number":
            self.take()
            return float(text) if any(c in text for c in ".eE") else int(text)
        if text == "true":
            self.take()
            return True
        if text == "false":
            self.take()
            return False
        if text == "nil":
            self.take()
            return None
        raise LuaParseError(f"only declarative literals are allowed, got {text!r}")

    def parse_table(self) -> dict[Any, Any]:
        self.take("{")
        result: dict[Any, Any] = {}
        next_index = 1
        while True:
            token = self.peek()
            if token is None:
                raise LuaParseError("unterminated table")
            if token[1] == "}":
                self.take("}")
                return result
            if token[1] == "[":
                self.take("[")
                key = self.parse_value()
                self.take("]")
                self.take("=")
                value = self.parse_value()
                if key in result:
                    raise LuaParseError(f"duplicate table key {key!r}")
                result[key] = value
            elif token[0] == "name" and self.index + 1 < len(self.tokens) \
                    and self.tokens[self.index + 1][1] == "=":
                key = self.take()[1]
                self.take("=")
                value = self.parse_value()
                if key in result:
                    raise LuaParseError(f"duplicate table key {key!r}")
                result[key] = value
            else:
                value = self.parse_value()
                result[next_index] = value
                next_index += 1
            if self.peek() is not None and self.peek()[1] in {",", ";"}:
                self.take()


def parse_lua_data(source: str) -> Any:
    """Parse a Lua file consisting only of ``return <declarative table literal>``."""
    return _Parser(source).parse_file()


def load_lua_module(path: Path) -> dict[str, Any]:
    value = parse_lua_data(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise LuaParseError(f"{path} must return a table")
    return value


def sequence(value: Any) -> list[Any] | None:
    """Return a Lua array (or Python list) as a list, or None for a map."""
    if isinstance(value, list):
        return list(value)
    if not isinstance(value, dict):
        return None
    if not value:
        return []
    keys = sorted(value)
    if keys != list(range(1, len(keys) + 1)):
        return None
    return [value[index] for index in keys]


def as_map(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}
    return {str(key): item for key, item in value.items()}


# ---------------------------------------------------------------------------
# Schema validation
# ---------------------------------------------------------------------------

def _error(errors: list[Diagnostic], code: str, path: str, message: str) -> None:
    errors.append(Diagnostic(code, path, message))


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) \
        and math.isfinite(float(value))


def _is_half_grid(value: Any) -> bool:
    return _is_number(value) and abs(float(value) * 2 - round(float(value) * 2)) < 1e-9


def _is_cardinal(value: Any) -> bool:
    return _is_int(value) and value in (0, 4, 8, 12)


def _check_keys(value: Any, allowed: set[str], path: str,
                errors: list[Diagnostic]) -> None:
    if not isinstance(value, dict):
        return
    for key in value:
        if isinstance(key, str) and key not in allowed:
            _error(errors, "unknown_field", f"{path}.{key}", f"unknown field '{key}'")


def _read_vector(value: Any, path: str, errors: list[Diagnostic],
                 *, allow_zero: bool = True) -> None:
    if not isinstance(value, dict) or set(value) - {"x", "y"}:
        _error(errors, "invalid_vector", path, "expected a {x,y} table")
        return
    x, y = value.get("x"), value.get("y")
    if not _is_number(x) or not _is_number(y):
        _error(errors, "invalid_vector", path, "x and y must be finite numbers")
    elif not _is_half_grid(x) or not _is_half_grid(y):
        _error(errors, "invalid_position", path, "coordinates must be multiples of 0.5")
    elif not allow_zero and x == 0 and y == 0:
        _error(errors, "invalid_vector", path, "offset must not be zero")


def _validate_parameter_definitions(defn: dict[str, Any],
                                    errors: list[Diagnostic]) -> None:
    parameters = defn.get("parameters", {})
    if not isinstance(parameters, dict):
        _error(errors, "invalid_parameters", "parameters", "parameters must be a table")
        return
    if sequence(parameters) == []:
        return
    for name, spec in parameters.items():
        if isinstance(name, int):
            _error(errors, "invalid_parameter_name", "parameters",
                   "parameter names must be strings")
            continue
        path = f"parameters.{name}"
        if not isinstance(spec, dict):
            _error(errors, "invalid_parameter", path, "parameter definition must be a table")
            continue
        _check_keys(spec, {"type", "default", "minimum", "maximum", "allowed",
                           "affects_geometry", "description"}, path, errors)
        kind = spec.get("type")
        if kind == "integer":
            if not _is_int(spec.get("default")):
                _error(errors, "invalid_parameter_default", f"{path}.default",
                       "integer parameter requires an integer default")
            if "minimum" in spec and not _is_int(spec["minimum"]):
                _error(errors, "invalid_parameter_bounds", f"{path}.minimum",
                       "minimum must be an integer")
            if "maximum" in spec and not _is_int(spec["maximum"]):
                _error(errors, "invalid_parameter_bounds", f"{path}.maximum",
                       "maximum must be an integer")
            minimum = spec.get("minimum", spec.get("default"))
            maximum = spec.get("maximum", spec.get("default"))
            if _is_int(minimum) and _is_int(maximum) and minimum > maximum:
                _error(errors, "invalid_parameter_bounds", path,
                       "minimum must not exceed maximum")
            if _is_int(spec.get("default")) and _is_int(minimum) and _is_int(maximum) \
                    and not minimum <= spec["default"] <= maximum:
                _error(errors, "invalid_parameter_default", f"{path}.default",
                       "default is outside the declared bounds")
        elif kind == "string":
            allowed = sequence(spec.get("allowed"))
            if not allowed:
                _error(errors, "invalid_parameter_values", f"{path}.allowed",
                       "string parameter requires a non-empty allowed list")
            elif not all(isinstance(item, str) for item in allowed):
                _error(errors, "invalid_parameter_values", f"{path}.allowed",
                       "allowed values must be strings")
            elif len(set(allowed)) != len(allowed):
                _error(errors, "invalid_parameter_values", f"{path}.allowed",
                       "allowed values must be unique")
            elif spec.get("default") not in allowed:
                _error(errors, "invalid_parameter_default", f"{path}.default",
                       "default must be one of the allowed values")
        elif kind == "boolean":
            if not isinstance(spec.get("default"), bool):
                _error(errors, "invalid_parameter_default", f"{path}.default",
                       "boolean parameter requires a boolean default")
        else:
            _error(errors, "unsupported_parameter_type", f"{path}.type",
                   "supported parameter types are integer, string and boolean")
        if "affects_geometry" in spec and not isinstance(spec["affects_geometry"], bool):
            _error(errors, "invalid_parameter", f"{path}.affects_geometry",
                   "affects_geometry must be boolean")


def _validate_repeat(defn: dict[str, Any], repeat_by: Any, path: str,
                     errors: list[Diagnostic]) -> None:
    if not isinstance(repeat_by, dict):
        _error(errors, "invalid_repeat", path, "repeat_by must be a table")
        return
    _check_keys(repeat_by, {"parameter", "step"}, path, errors)
    name = repeat_by.get("parameter")
    spec = as_map(defn.get("parameters", {})).get(name) if isinstance(name, str) else None
    if not isinstance(name, str):
        _error(errors, "invalid_repeat", f"{path}.parameter", "parameter must be a string")
    elif not isinstance(spec, dict):
        _error(errors, "unknown_parameter", f"{path}.parameter",
               f"unknown repeat parameter '{name}'")
    elif spec.get("type") != "integer":
        _error(errors, "invalid_repeat", f"{path}.parameter",
               "repeat parameters must be integer parameters")
    elif spec.get("affects_geometry") is not True:
        _error(errors, "invalid_repeat", f"{path}.parameter",
               "repeat parameters must declare affects_geometry=true")
    _read_vector(repeat_by.get("step"), f"{path}.step", errors, allow_zero=False)


def _validate_entity(defn: dict[str, Any], entity: Any, index: int, env: Environment,
                     errors: list[Diagnostic]) -> None:
    path = f"geometry.entities[{index}]"
    if not isinstance(entity, dict):
        _error(errors, "invalid_entity", path, "entity must be a table")
        return
    _check_keys(entity, {"id", "name", "position", "direction", "quality", "recipe",
                         "recipe_parameter", "repeat_by"}, path, errors)
    entity_id = entity.get("id")
    if not isinstance(entity_id, str) or not entity_id:
        _error(errors, "invalid_entity_id", f"{path}.id", "entity id must be a string")
    elif not ENTITY_ID_PATTERN.match(entity_id):
        _error(errors, "invalid_entity_id", f"{path}.id", "invalid entity id")
    proto = None
    name = entity.get("name")
    if not isinstance(name, str) or not name:
        _error(errors, "invalid_entity_name", f"{path}.name", "entity name must be a string")
    else:
        proto = env.entities.get(name)
        if proto is None:
            _error(errors, "unknown_entity_prototype", f"{path}.name",
                   f"unknown entity prototype '{name}'")
        else:
            if proto.type not in ENTITY_TYPES:
                _error(errors, "unsupported_entity_type", f"{path}.name",
                       f"entity type '{proto.type}' is not supported by schema v1")
            if not proto.items_to_place_this:
                _error(errors, "no_placeable_item", f"{path}.name",
                       "entity prototype has no placeable item")
    _read_vector(entity.get("position"), f"{path}.position", errors)
    if not _is_cardinal(entity.get("direction")):
        _error(errors, "invalid_direction", f"{path}.direction",
               "direction must be one of 0, 4, 8 or 12")
    quality = entity.get("quality")
    if quality is not None and (not isinstance(quality, str) or quality not in env.qualities):
        _error(errors, "unknown_quality", f"{path}.quality", f"unknown quality '{quality}'")
    if "recipe" in entity and "recipe_parameter" in entity:
        _error(errors, "unsupported_entity_configuration", path,
               "recipe and recipe_parameter are mutually exclusive")
    if "recipe" in entity:
        recipe_name = entity["recipe"]
        recipe = env.recipes.get(recipe_name) if isinstance(recipe_name, str) else None
        if not isinstance(recipe_name, str):
            _error(errors, "invalid_recipe", f"{path}.recipe", "recipe must be a string")
        elif recipe is None:
            _error(errors, "unknown_recipe", f"{path}.recipe",
                   f"unknown recipe '{recipe_name}'")
        elif proto is None or proto.type != "assembling-machine":
            _error(errors, "unsupported_entity_configuration", f"{path}.recipe",
                   "recipe assignment is supported only for assembling-machine entities")
        elif not (recipe.categories & proto.crafting_categories):
            _error(errors, "incompatible_recipe", f"{path}.recipe",
                   "recipe category is not accepted by the assembling machine")
    if "recipe_parameter" in entity:
        _error(errors, "unsupported_entity_configuration", f"{path}.recipe_parameter",
               "recipe_parameter is not implemented in schema v1; use a fixed recipe")
    if "repeat_by" in entity:
        _validate_repeat(defn, entity["repeat_by"], f"{path}.repeat_by", errors)


def _validate_port(defn: dict[str, Any], port: Any, index: int, env: Environment,
                   errors: list[Diagnostic]) -> None:
    path = f"geometry.ports[{index}]"
    if not isinstance(port, dict):
        _error(errors, "invalid_port", path, "port must be a table")
        return
    _check_keys(port, {"id", "type", "role", "position", "direction", "item", "fluid",
                       "repeat_by", "connector", "capacity"}, path, errors)
    port_id = port.get("id")
    if not isinstance(port_id, str) or not port_id:
        _error(errors, "invalid_port_id", f"{path}.id", "port id must be a string")
    elif not ENTITY_ID_PATTERN.match(port_id):
        _error(errors, "invalid_port_id", f"{path}.id", "invalid port id")
    if port.get("type") not in PORT_TYPES:
        _error(errors, "invalid_port_type", f"{path}.type",
               "port type must be item, fluid or electric")
    if port.get("role") not in PORT_ROLES:
        _error(errors, "invalid_port_role", f"{path}.role",
               "port role must be input, output or bidirectional")
    _read_vector(port.get("position"), f"{path}.position", errors)
    if not _is_cardinal(port.get("direction")):
        _error(errors, "invalid_direction", f"{path}.direction",
               "direction must be one of 0, 4, 8 or 12")
    if port.get("type") == "item":
        if not isinstance(port.get("item"), str) or port["item"] not in env.items:
            _error(errors, "unknown_item", f"{path}.item",
                   "item port requires a known item prototype")
        if "fluid" in port:
            _error(errors, "invalid_port", f"{path}.fluid",
                   "item port must not declare a fluid")
    elif port.get("type") == "fluid":
        if not isinstance(port.get("fluid"), str) or port["fluid"] not in env.fluids:
            _error(errors, "unknown_fluid", f"{path}.fluid",
                   "fluid port requires a known fluid prototype")
        if "item" in port:
            _error(errors, "invalid_port", f"{path}.item",
                   "fluid port must not declare an item")
    elif port.get("type") == "electric":
        if "item" in port or "fluid" in port:
            _error(errors, "invalid_port", path,
                   "electric port must not declare an item or fluid")
        if port.get("connector") not in (None, "input", "output"):
            _error(errors, "invalid_port", f"{path}.connector",
                   "connector must be 'input' or 'output'")
    if "repeat_by" in port:
        _validate_repeat(defn, port["repeat_by"], f"{path}.repeat_by", errors)


def _validate_reserved(reserved: Any, index: int, errors: list[Diagnostic]) -> None:
    path = f"geometry.reserved[{index}]"
    if not isinstance(reserved, dict):
        _error(errors, "invalid_reserved_area", path, "reserved area must be a table")
        return
    _check_keys(reserved, {"id", "area", "reason"}, path, errors)
    if not isinstance(reserved.get("id"), str) or not reserved["id"]:
        _error(errors, "invalid_reserved_area", f"{path}.id", "reserved id must be a string")
    area = reserved.get("area")
    if not isinstance(area, dict):
        _error(errors, "invalid_reserved_area", f"{path}.area", "area must be a table")
        return
    _check_keys(area, {"x", "y", "width", "height"}, f"{path}.area", errors)
    if not _is_half_grid(area.get("x")) or not _is_half_grid(area.get("y")):
        _error(errors, "invalid_reserved_area", f"{path}.area",
               "x and y must be multiples of 0.5")
    elif area["x"] < 0 or area["y"] < 0:
        _error(errors, "invalid_reserved_area", f"{path}.area",
               "reserved areas must start at or after the module origin")
    for key in ("width", "height"):
        if not _is_int(area.get(key)) or area[key] <= 0:
            _error(errors, "invalid_dimension", f"{path}.area.{key}",
                   "expected a positive integer")


def _validate_constraint(constraint: Any, index: int, env: Environment,
                         errors: list[Diagnostic]) -> None:
    path = f"placement.constraints[{index}]"
    if not isinstance(constraint, dict):
        _error(errors, "invalid_constraint", path, "constraint must be a table")
        return
    kind = constraint.get("type")
    if kind == "resource_patch":
        _check_keys(constraint, {"type", "resource", "minimum_amount", "minimum_entities"},
                    path, errors)
        proto = env.entities.get(constraint.get("resource")) \
            if isinstance(constraint.get("resource"), str) else None
        if proto is None or proto.type != "resource":
            _error(errors, "unknown_resource", f"{path}.resource",
                   "resource_patch requires a known resource entity prototype")
        for key in ("minimum_amount", "minimum_entities"):
            if key in constraint and not _is_int(constraint[key]):
                _error(errors, "invalid_constraint", f"{path}.{key}",
                       f"{key} must be an integer")
    elif kind == "near_water":
        _check_keys(constraint, {"type", "max_distance"}, path, errors)
        if "max_distance" in constraint and (not _is_number(constraint["max_distance"])
                                             or constraint["max_distance"] < 0):
            _error(errors, "invalid_constraint", f"{path}.max_distance",
                   "max_distance must be a non-negative number")
    elif kind == "clear_footprint":
        _check_keys(constraint, {"type"}, path, errors)
    elif kind == "avoid_entities":
        _check_keys(constraint, {"type", "types", "names"}, path, errors)
    elif kind == "avoid_tiles":
        _check_keys(constraint, {"type", "names"}, path, errors)
    elif kind == "electric_network":
        _check_keys(constraint, {"type", "max_distance"}, path, errors)
    else:
        _error(errors, "unsupported_constraint", f"{path}.type",
               f"unsupported placement constraint '{kind}'")


def _validate_requirements(defn: dict[str, Any], env: Environment,
                           errors: list[Diagnostic]) -> None:
    requirements = defn.get("requirements", {})
    if not isinstance(requirements, dict):
        _error(errors, "invalid_requirements", "requirements",
               "requirements must be a table")
        return
    _check_keys(requirements, {"technologies", "recipes", "stage"}, "requirements", errors)
    for key, known, code in (
        ("technologies", env.technologies, "unknown_technology"),
        ("recipes", set(env.recipes), "unknown_recipe"),
    ):
        if key not in requirements:
            continue
        values = sequence(requirements[key])
        if values is None:
            _error(errors, "invalid_requirements", f"requirements.{key}",
                   f"{key} must be a list")
            continue
        seen = set()
        for index, name in enumerate(values, 1):
            path = f"requirements.{key}[{index}]"
            if not isinstance(name, str):
                _error(errors, "invalid_requirements", path, "expected a prototype name")
            elif name in seen:
                _error(errors, "invalid_requirements", path, f"duplicate name '{name}'")
            elif name not in known:
                _error(errors, code, path, f"unknown '{name}'")
            seen.add(name)
    if "stage" in requirements and requirements["stage"] not in STAGE_ORDER:
        _error(errors, "unknown_stage", "requirements.stage",
               f"unknown stage '{requirements['stage']}'")


def validate_definition(defn: Any, env: Environment) -> list[Diagnostic]:
    errors: list[Diagnostic] = []
    if not isinstance(defn, dict):
        return [Diagnostic("invalid_definition", "", "module definition must be a table")]
    _check_keys(defn, {"schema_version", "id", "module_version", "name", "description",
                       "category", "surfaces", "stages", "tags", "geometry",
                       "requirements", "placement", "parameters"}, "", errors)
    if defn.get("schema_version") != SCHEMA_VERSION:
        _error(errors, "unsupported_schema_version", "schema_version",
               f"expected schema_version {SCHEMA_VERSION}")
    if not isinstance(defn.get("id"), str) or not ID_PATTERN.match(defn["id"]):
        _error(errors, "invalid_module_id", "id", "invalid module id")
    if not _is_int(defn.get("module_version")) or defn["module_version"] < 1:
        _error(errors, "invalid_module_version", "module_version",
               "module_version must be a positive integer")
    if not isinstance(defn.get("name"), str) or not defn["name"]:
        _error(errors, "invalid_name", "name", "name must be a non-empty string")
    if not isinstance(defn.get("description"), str) or not defn["description"]:
        _error(errors, "invalid_description", "description",
               "description must be a non-empty string")
    if defn.get("category") not in CATEGORIES:
        _error(errors, "invalid_category", "category", "unknown category")
    surfaces = sequence(defn.get("surfaces"))
    if not surfaces:
        _error(errors, "invalid_surfaces", "surfaces", "surfaces must be a non-empty list")
    stages = sequence(defn.get("stages"))
    if not stages:
        _error(errors, "invalid_stages", "stages", "stages must be a non-empty list")
    else:
        for index, stage in enumerate(stages, 1):
            if stage not in STAGE_ORDER:
                _error(errors, "unknown_stage", f"stages[{index}]",
                       f"unknown stage '{stage}'")
    tags = sequence(defn.get("tags"))
    if "tags" in defn and (tags is None or not all(isinstance(tag, str) for tag in tags)):
        _error(errors, "invalid_tags", "tags", "tags must be a list of strings")
    _validate_parameter_definitions(defn, errors)
    geometry = defn.get("geometry")
    if not isinstance(geometry, dict):
        _error(errors, "invalid_geometry", "geometry", "geometry must be a table")
        return errors
    _check_keys(geometry, {"footprint", "origin", "entities", "ports", "reserved",
                           "supported_orientations"}, "geometry", errors)
    footprint = geometry.get("footprint")
    if not isinstance(footprint, dict):
        _error(errors, "invalid_footprint", "geometry.footprint",
               "footprint must be a table")
    else:
        _check_keys(footprint, {"width", "height"}, "geometry.footprint", errors)
        for key in ("width", "height"):
            if not _is_int(footprint.get(key)) or footprint[key] <= 0:
                _error(errors, "invalid_dimension", f"geometry.footprint.{key}",
                       "expected a positive integer")
    origin = geometry.get("origin")
    if not isinstance(origin, dict):
        _error(errors, "invalid_origin", "geometry.origin", "origin must be a table")
    elif set(origin) - {"x", "y"} or origin.get("x") != 0 or origin.get("y") != 0:
        _error(errors, "unsupported_origin", "geometry.origin",
               "schema v1 requires the origin at {x=0,y=0}")
    entities = sequence(geometry.get("entities"))
    if not entities:
        _error(errors, "invalid_entities", "geometry.entities",
               "entities must be a non-empty list")
    else:
        for index, entity in enumerate(entities, 1):
            _validate_entity(defn, entity, index, env, errors)
    ports = sequence(geometry.get("ports"))
    if not ports:
        _error(errors, "invalid_ports", "geometry.ports", "ports must be a non-empty list")
    else:
        for index, port in enumerate(ports, 1):
            _validate_port(defn, port, index, env, errors)
    if "reserved" in geometry:
        reserved = sequence(geometry["reserved"])
        if reserved is None:
            _error(errors, "invalid_reserved_area", "geometry.reserved",
                   "reserved must be a list")
        else:
            for index, area in enumerate(reserved, 1):
                _validate_reserved(area, index, errors)
    orientations = sequence(geometry.get("supported_orientations"))
    if not orientations:
        _error(errors, "invalid_orientations", "geometry.supported_orientations",
               "supported_orientations must be a non-empty list")
    else:
        seen = set()
        for index, orientation in enumerate(orientations, 1):
            if orientation not in SUPPORTED_ORIENTATIONS:
                _error(errors, "invalid_orientation",
                       f"geometry.supported_orientations[{index}]",
                       "orientation must be 0, 90, 180 or 270")
            elif orientation in seen:
                _error(errors, "invalid_orientation",
                       f"geometry.supported_orientations[{index}]",
                       "duplicate orientation")
            seen.add(orientation)
    _validate_requirements(defn, env, errors)
    placement = defn.get("placement")
    if not isinstance(placement, dict):
        _error(errors, "invalid_placement", "placement", "placement must be a table")
    else:
        _check_keys(placement, {"constraints"}, "placement", errors)
        constraints = sequence(placement.get("constraints"))
        if not constraints:
            _error(errors, "invalid_constraints", "placement.constraints",
                   "constraints must be a non-empty list")
        else:
            for index, constraint in enumerate(constraints, 1):
                _validate_constraint(constraint, index, env, errors)
    if errors:
        return errors
    supported_orientations = sequence(geometry.get("supported_orientations")) or []
    for combo in geometry_combinations(defn, errors):
        values = with_defaults(defn, dict(combo))
        for orientation in supported_orientations:
            _validate_expanded_geometry(defn, values, orientation, env, errors)
    return errors


def _validate_expanded_geometry(defn: dict[str, Any], values: dict[str, Any],
                                orientation: int, env: Environment,
                                errors: list[Diagnostic]) -> None:
    expanded = expand_geometry(defn, values, orientation, env)
    width = expanded["footprint"]["width"]
    height = expanded["footprint"]["height"]
    base_width = defn["geometry"]["footprint"]["width"]
    base_height = defn["geometry"]["footprint"]["height"]
    if orientation in (90, 270):
        base_width, base_height = base_height, base_width
    entity_ids: set[str] = set()
    boxes: dict[str, tuple[float, float, float, float]] = {}
    for entity in expanded["entities"]:
        if entity["id"] in entity_ids:
            _error(errors, "duplicate_entity_id", "geometry.entities",
                   f"duplicate expanded entity id '{entity['id']}'")
        entity_ids.add(entity["id"])
        proto = env.entities.get(entity["name"])
        half_w = proto.half_width if proto else 0.5
        half_h = proto.half_height if proto else 0.5
        if entity["direction"] in (4, 12) and half_w != half_h:
            half_w, half_h = half_h, half_w
        x, y = entity["position"]["x"], entity["position"]["y"]
        box = (x - half_w, y - half_h, x + half_w, y + half_h)
        if box[0] < -1e-9 or box[1] < -1e-9 or box[2] > width + 1e-9 \
                or box[3] > height + 1e-9:
            _error(errors, "entity_outside_footprint", f"geometry.entities.{entity['id']}",
                   f"entity '{entity['name']}' extends outside the module footprint")
        for other_id, other in boxes.items():
            if box[0] < other[2] - 1e-9 and other[0] < box[2] - 1e-9 \
                    and box[1] < other[3] - 1e-9 and other[1] < box[3] - 1e-9:
                _error(errors, "entity_overlap", f"geometry.entities.{entity['id']}",
                       f"entity overlaps '{other_id}'")
        boxes[entity["id"]] = box
    port_ids: set[str] = set()
    for port in expanded["ports"]:
        if port["id"] in port_ids:
            _error(errors, "duplicate_port_id", "geometry.ports",
                   f"duplicate expanded port id '{port['id']}'")
        port_ids.add(port["id"])
        position = port["position"]
        if not (0 <= position["x"] <= width and 0 <= position["y"] <= height):
            _error(errors, "port_outside_footprint", f"geometry.ports.{port['id']}",
                   "port position lies outside the module footprint")
        if orientation == 0 and port["copy"] == 1 and (
                position["x"] < -1e-9 or position["y"] < -1e-9
                or position["x"] > base_width + 1e-9
                or position["y"] > base_height + 1e-9):
            _error(errors, "port_outside_footprint", f"geometry.ports.{port['id']}",
                   "the first repeated port must fit the declared base footprint")
    for reserved in expanded["reserved"]:
        area = reserved["area"]
        if area["x"] < 0 or area["y"] < 0 or area["x"] + area["width"] > width \
                or area["y"] + area["height"] > height:
            _error(errors, "reserved_outside_footprint", f"geometry.reserved.{reserved['id']}",
                   "reserved area lies outside the effective module bounds")


# ---------------------------------------------------------------------------
# Parameters and deterministic geometry reference
# ---------------------------------------------------------------------------

def geometry_combinations(defn: dict[str, Any],
                          errors: list[Diagnostic]) -> list[dict[str, int]]:
    combos: list[dict[str, int]] = [{}]
    for name, spec in as_map(defn.get("parameters", {})).items():
        if spec.get("type") == "integer" and spec.get("affects_geometry") is True:
            minimum = spec.get("minimum", spec.get("default"))
            maximum = spec.get("maximum", spec.get("default"))
            next_combos: list[dict[str, int]] = []
            for combo in combos:
                for value in range(minimum, maximum + 1):
                    next_combos.append({**combo, name: value})
            combos = next_combos
            if len(combos) > 64:
                _error(errors, "too_many_parameter_combinations", "parameters",
                       "geometry parameter combinations exceed 64")
                return [{}]
    return combos


def with_defaults(defn: dict[str, Any], values: dict[str, Any]) -> dict[str, Any]:
    result = dict(values)
    for name, spec in as_map(defn.get("parameters", {})).items():
        result.setdefault(name, spec.get("default"))
    return result


def resolve_parameters(defn: dict[str, Any], requested: dict[str, Any] | None
                       ) -> tuple[dict[str, Any] | None, list[Diagnostic]]:
    requested = requested or {}
    errors: list[Diagnostic] = []
    parameters = as_map(defn.get("parameters", {}))
    for name in requested:
        if name not in parameters:
            _error(errors, "unknown_parameter", f"parameters.{name}",
                   f"unknown parameter '{name}'")
    values: dict[str, Any] = {}
    for name, spec in parameters.items():
        value = requested.get(name, spec.get("default"))
        kind = spec.get("type")
        if kind == "integer":
            if not _is_int(value):
                _error(errors, "invalid_parameter_value", f"parameters.{name}",
                       f"parameter '{name}' must be an integer")
            else:
                minimum = spec.get("minimum", spec.get("default"))
                maximum = spec.get("maximum", spec.get("default"))
                if not minimum <= value <= maximum:
                    _error(errors, "invalid_parameter_value", f"parameters.{name}",
                           f"parameter '{name}' must be between {minimum} and {maximum}")
        elif kind == "string":
            if value not in (spec.get("allowed") or []):
                _error(errors, "invalid_parameter_value", f"parameters.{name}",
                       f"parameter '{name}' is not an allowed value")
        elif kind == "boolean" and not isinstance(value, bool):
            _error(errors, "invalid_parameter_value", f"parameters.{name}",
                   f"parameter '{name}' must be a boolean")
        values[name] = value
    return (None, errors) if errors else (values, [])


def expand_geometry(defn: dict[str, Any], values: dict[str, Any], orientation: int,
                    env: Environment | None = None) -> dict[str, Any]:
    resolved, errors = resolve_parameters(defn, values)
    if resolved is None:
        raise ValueError(errors)
    supported = sequence(defn["geometry"].get("supported_orientations")) or []
    if orientation not in supported:
        raise ValueError(f"orientation {orientation} is not supported")
    entities: list[dict[str, Any]] = []
    for entity in sequence(defn["geometry"]["entities"]) or []:
        repeat_by = entity.get("repeat_by")
        count = resolved[repeat_by["parameter"]] if repeat_by else 1
        for copy in range(1, count + 1):
            step_x = repeat_by["step"]["x"] * (copy - 1) if repeat_by else 0
            step_y = repeat_by["step"]["y"] * (copy - 1) if repeat_by else 0
            entities.append({
                "id": entity["id"] if copy == 1 else f"{entity['id']}_{copy}",
                "base_id": entity["id"],
                "name": entity["name"],
                "position": {"x": entity["position"]["x"] + step_x,
                             "y": entity["position"]["y"] + step_y},
                "direction": entity["direction"],
                "quality": entity.get("quality", "normal"),
                "recipe": entity.get("recipe"),
                "copy": copy,
            })
    ports: list[dict[str, Any]] = []
    for port in sequence(defn["geometry"]["ports"]) or []:
        repeat_by = port.get("repeat_by")
        count = resolved[repeat_by["parameter"]] if repeat_by else 1
        for copy in range(1, count + 1):
            step_x = repeat_by["step"]["x"] * (copy - 1) if repeat_by else 0
            step_y = repeat_by["step"]["y"] * (copy - 1) if repeat_by else 0
            ports.append({
                "id": port["id"] if copy == 1 else f"{port['id']}_{copy}",
                "base_id": port["id"],
                "type": port["type"],
                "role": port["role"],
                "position": {"x": port["position"]["x"] + step_x,
                             "y": port["position"]["y"] + step_y},
                "direction": port["direction"],
                "item": port.get("item"),
                "fluid": port.get("fluid"),
                "connector": port.get("connector"),
                "capacity": port.get("capacity"),
                "copy": copy,
            })
    footprint = defn["geometry"]["footprint"]
    width, height = footprint["width"], footprint["height"]
    for reserved in sequence(defn["geometry"].get("reserved")) or []:
        area = reserved["area"]
        width = max(width, area["x"] + area["width"])
        height = max(height, area["y"] + area["height"])
    for entity in entities:
        width = max(width, entity["position"]["x"])
        height = max(height, entity["position"]["y"])
    for port in ports:
        width = max(width, port["position"]["x"])
        height = max(height, port["position"]["y"])

    def rotate_point(point: dict[str, float]) -> dict[str, float]:
        x, y = point["x"], point["y"]
        if orientation == 0:
            return {"x": x, "y": y}
        if orientation == 90:
            return {"x": height - y, "y": x}
        if orientation == 180:
            return {"x": width - x, "y": height - y}
        return {"x": y, "y": width - x}

    def rotate_area(area: dict[str, float]) -> dict[str, float]:
        x, y, w, h = area["x"], area["y"], area["width"], area["height"]
        if orientation == 0:
            return {"x": x, "y": y, "width": w, "height": h}
        if orientation == 90:
            return {"x": height - y - h, "y": x, "width": h, "height": w}
        if orientation == 180:
            return {"x": width - x - w, "y": height - y - h, "width": w, "height": h}
        return {"x": y, "y": width - x - w, "width": h, "height": w}

    rotated_width, rotated_height = width, height
    if orientation in (90, 270):
        rotated_width, rotated_height = height, width
    return {
        "footprint": {"width": rotated_width, "height": rotated_height},
        "base_footprint": {"width": width, "height": height},
        "entities": [
            {**entity, "position": rotate_point(entity["position"]),
             "direction": (entity["direction"] + orientation // 90 * 4) % 16}
            for entity in entities
        ],
        "ports": [
            {**port, "position": rotate_point(port["position"]),
             "direction": (port["direction"] + orientation // 90 * 4) % 16}
            for port in ports
        ],
        "reserved": [
            {**reserved, "area": rotate_area(reserved["area"])}
            for reserved in (sequence(defn["geometry"].get("reserved")) or [])
        ],
        "parameters": resolved,
        "orientation": orientation,
    }


# ---------------------------------------------------------------------------
# Catalog helpers for the unit suite
# ---------------------------------------------------------------------------

def load_module_files(paths: list[Path]) -> tuple[list[dict[str, Any]], list[Diagnostic]]:
    modules: list[dict[str, Any]] = []
    errors: list[Diagnostic] = []
    counts: dict[str, int] = {}
    for path in paths:
        try:
            module = load_lua_module(path)
        except LuaParseError as exc:
            _error(errors, "module_load_failed", str(path), str(exc))
            continue
        module_id = module.get("id")
        if isinstance(module_id, str):
            counts[module_id] = counts.get(module_id, 0) + 1
        modules.append(module)
    result = []
    for module in modules:
        module_id = module.get("id")
        if isinstance(module_id, str) and counts.get(module_id, 0) > 1:
            _error(errors, "duplicate_module_id", str(module_id),
                   f"module id '{module_id}' is defined more than once")
            continue
        result.append(module)
    return result, errors


def reference_environment() -> Environment:
    """Prototype stub matching the base-game names used by the initial library."""
    entities = {
        "electric-mining-drill": EntityPrototype(
            "mining-drill", ("electric-mining-drill",), half_width=1.34765625,
            half_height=1.34765625),
        "stone-furnace": EntityPrototype(
            "furnace", ("stone-furnace",), frozenset({"smelting"}),
            half_width=0.69921875, half_height=0.69921875),
        "assembling-machine-1": EntityPrototype(
            "assembling-machine", ("assembling-machine-1",),
            frozenset({"crafting", "advanced-crafting", "crafting-with-fluid"}),
            half_width=1.19921875, half_height=1.19921875),
        "iron-ore": EntityPrototype("resource"),
        "copper-ore": EntityPrototype("resource"),
        "coal": EntityPrototype("resource"),
        "stone": EntityPrototype("resource"),
    }
    items = {"electric-mining-drill", "stone-furnace", "assembling-machine-1",
             "iron-ore", "coal", "iron-plate", "iron-gear-wheel", "copper-plate"}
    recipes = {
        "iron-plate": RecipePrototype(frozenset({"smelting"})),
        "iron-gear-wheel": RecipePrototype(frozenset({"crafting"})),
        "copper-cable": RecipePrototype(frozenset({"crafting"})),
    }
    technologies = {"automation", "electric-mining-drill", "logistics",
                    "electric-energy-distribution-1"}
    return Environment(entities=entities, items=items, recipes=recipes,
                       technologies=technologies)


def module_paths(root: Path) -> list[Path]:
    manifest = load_lua_module(root / "modules" / "manifest.lua")
    if manifest.get("schema_version") != MANIFEST_SCHEMA_VERSION:
        raise LuaParseError("unsupported manifest schema version")
    paths = []
    for entry in sequence(manifest.get("modules")) or []:
        if not isinstance(entry, str):
            raise LuaParseError("manifest module entries must be strings")
        paths.append(root / (entry.replace(".", "/") + ".lua"))
    return paths
