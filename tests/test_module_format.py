"""Unit tests for the declarative module format, catalog and reference geometry."""
from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from factorio_autonomous_engineer.module_format import (
    Diagnostic,
    LuaParseError,
    expand_geometry,
    load_lua_module,
    load_module_files,
    module_paths,
    parse_lua_data,
    reference_environment,
    resolve_parameters,
    validate_definition,
)

ROOT = Path(__file__).resolve().parents[1]
MOD_ROOT = ROOT / "mod" / "factorio_autonomous_engineer"
ENV = reference_environment()


def library() -> list[dict]:
    modules, errors = load_module_files(module_paths(MOD_ROOT))
    assert not errors, errors
    return modules


def by_id(module_id: str) -> dict:
    for module in library():
        if module["id"] == module_id:
            return copy.deepcopy(module)
    raise AssertionError(f"missing module {module_id}")


def codes(diagnostics: list[Diagnostic]) -> set[str]:
    return {diagnostic.code for diagnostic in diagnostics}


class DeclarativeParserTests(unittest.TestCase):
    def test_parser_reads_nested_declarative_data(self):
        value = parse_lua_data(
            'return {schema_version = 1, name = "x", list = {1, 2, [4] = false}, '
            '-- comment\n flag = true}\n'
        )
        self.assertEqual(value["schema_version"], 1)
        self.assertEqual(value["name"], "x")
        self.assertEqual(value["list"][1], 1)
        self.assertEqual(value["list"][2], 2)
        self.assertFalse(value["list"][4])
        self.assertTrue(value["flag"])

    def test_parser_rejects_executable_lua(self):
        with self.assertRaises(LuaParseError):
            parse_lua_data("return {x = os.execute('echo bad')}")
        with self.assertRaises(LuaParseError):
            parse_lua_data("return {x = function() return 1 end}")

    def test_manifest_and_every_module_parse(self):
        paths = module_paths(MOD_ROOT)
        self.assertEqual(len(paths), 3)
        for path in paths:
            module = load_lua_module(path)
            self.assertEqual(module["schema_version"], 1)
            self.assertIn("geometry", module)


class ValidModuleTests(unittest.TestCase):
    def test_initial_library_is_valid_and_ids_are_stable(self):
        modules = library()
        self.assertEqual([module["id"] for module in modules], [
            "nauvis.assembling_machine_1.gear",
            "nauvis.electric_mining.iron",
            "nauvis.stone_furnace.iron_smelting",
        ])
        for module in modules:
            self.assertEqual(validate_definition(module, ENV), [], module["id"])

    def test_duplicate_ids_are_rejected(self):
        source = (MOD_ROOT / "modules" / "nauvis_electric_mining_iron.lua").read_text(
            encoding="utf-8")
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "a.lua"
            second = Path(directory) / "b.lua"
            first.write_text(source, encoding="utf-8")
            second.write_text(source, encoding="utf-8")
            modules, errors = load_module_files([first, second])
        self.assertEqual(modules, [])
        self.assertIn("duplicate_module_id", codes(errors))


class InvalidDefinitionTests(unittest.TestCase):
    def test_unsupported_schema_version(self):
        module = by_id("nauvis.electric_mining.iron")
        module["schema_version"] = 2
        self.assertIn("unsupported_schema_version", codes(validate_definition(module, ENV)))

    def test_unknown_entity_prototype(self):
        module = by_id("nauvis.electric_mining.iron")
        module["geometry"]["entities"][1]["name"] = "not-a-real-entity"
        self.assertIn("unknown_entity_prototype", codes(validate_definition(module, ENV)))

    def test_invalid_direction(self):
        module = by_id("nauvis.electric_mining.iron")
        module["geometry"]["entities"][1]["direction"] = 2
        self.assertIn("invalid_direction", codes(validate_definition(module, ENV)))

    def test_invalid_position(self):
        module = by_id("nauvis.electric_mining.iron")
        module["geometry"]["entities"][1]["position"]["x"] = 1.25
        self.assertIn("invalid_position", codes(validate_definition(module, ENV)))

    def test_malformed_footprint(self):
        module = by_id("nauvis.electric_mining.iron")
        module["geometry"]["footprint"]["width"] = 0
        self.assertIn("invalid_dimension", codes(validate_definition(module, ENV)))

    def test_duplicate_port_ids(self):
        module = by_id("nauvis.electric_mining.iron")
        module["geometry"]["ports"][2]["id"] = module["geometry"]["ports"][1]["id"]
        self.assertIn("duplicate_port_id", codes(validate_definition(module, ENV)))

    def test_port_outside_footprint(self):
        module = by_id("nauvis.electric_mining.iron")
        module["geometry"]["ports"][1]["position"] = {"x": 9, "y": 1.5}
        self.assertIn("port_outside_footprint", codes(validate_definition(module, ENV)))

    def test_unknown_recipes_and_technologies(self):
        module = by_id("nauvis.electric_mining.iron")
        module["requirements"]["technologies"] = ["missing-technology"]
        module["requirements"]["recipes"] = ["missing-recipe"]
        found = codes(validate_definition(module, ENV))
        self.assertIn("unknown_technology", found)
        self.assertIn("unknown_recipe", found)

    def test_unsupported_entity_configuration_is_not_silently_dropped(self):
        module = by_id("nauvis.electric_mining.iron")
        module["geometry"]["entities"][1]["insert_plan"] = {}
        self.assertIn("unknown_field", codes(validate_definition(module, ENV)))

    def test_furnace_recipe_assignment_is_rejected(self):
        module = by_id("nauvis.stone_furnace.iron_smelting")
        module["geometry"]["entities"][1]["recipe"] = "iron-plate"
        self.assertIn("unsupported_entity_configuration",
                      codes(validate_definition(module, ENV)))

    def test_invalid_orientation(self):
        module = by_id("nauvis.electric_mining.iron")
        module["geometry"]["supported_orientations"] = [45]
        self.assertIn("invalid_orientation", codes(validate_definition(module, ENV)))

    def test_malformed_manifest_entry(self):
        manifest = (MOD_ROOT / "modules" / "manifest.lua").read_text(encoding="utf-8")
        self.assertIn('"modules.nauvis_electric_mining_iron"', manifest)


class ParameterTests(unittest.TestCase):
    def test_defaults_and_repeat_expansion_are_deterministic(self):
        module = by_id("nauvis.stone_furnace.iron_smelting")
        values, errors = resolve_parameters(module, {})
        self.assertEqual(errors, [])
        self.assertEqual(values, {"unit_count": 1})
        first = expand_geometry(module, {"unit_count": 3}, 0, ENV)
        second = expand_geometry(module, {"unit_count": 3}, 0, ENV)
        self.assertEqual(first, second)
        self.assertEqual([entity["id"] for entity in first["entities"]],
                         ["furnace", "furnace_2", "furnace_3"])
        self.assertEqual([entity["position"]["x"] for entity in first["entities"]],
                         [1, 3, 5])
        self.assertEqual(first["footprint"], {"width": 6, "height": 2})
        self.assertEqual([port["id"] for port in first["ports"]], [
            "ore_input", "ore_input_2", "ore_input_3",
            "fuel_input", "fuel_input_2", "fuel_input_3",
            "plate_output", "plate_output_2", "plate_output_3",
        ])

    def test_unknown_parameter_is_rejected(self):
        module = by_id("nauvis.stone_furnace.iron_smelting")
        values, errors = resolve_parameters(module, {"missing": 1})
        self.assertIsNone(values)
        self.assertIn("unknown_parameter", codes(errors))

    def test_invalid_parameter_value_is_rejected(self):
        module = by_id("nauvis.stone_furnace.iron_smelting")
        for value in (0, 4, 1.5, "2"):
            values, errors = resolve_parameters(module, {"unit_count": value})
            self.assertIsNone(values, value)
            self.assertIn("invalid_parameter_value", codes(errors))


class OrientationTests(unittest.TestCase):
    def test_rotation_transforms_entity_positions_directions_ports_and_reserved(self):
        module = by_id("nauvis.assembling_machine_1.gear")
        # The transform is generic; the shipped module advertises only the orientation
        # Factorio actually preserves for its non-rotatable assembler entity.
        module["geometry"]["supported_orientations"] = [0, 90, 180, 270]
        east = expand_geometry(module, {}, 90, ENV)
        self.assertEqual(east["footprint"], {"width": 4, "height": 3})
        self.assertEqual(east["entities"][0]["position"], {"x": 2.5, "y": 1.5})
        self.assertEqual(east["entities"][0]["direction"], 4)
        ports = {port["id"]: port for port in east["ports"]}
        self.assertEqual(ports["plate_input"]["position"], {"x": 2.5, "y": 0})
        self.assertEqual(ports["plate_input"]["direction"], 8)
        self.assertEqual(ports["gear_output"]["position"], {"x": 2.5, "y": 3})
        self.assertEqual(ports["gear_output"]["direction"], 8)
        self.assertEqual(east["reserved"][0]["area"],
                         {"x": 0, "y": 0, "width": 1, "height": 3})

    def test_every_advertised_orientation_is_accepted_and_unknown_is_not(self):
        module = by_id("nauvis.electric_mining.iron")
        for orientation in (0, 90, 180, 270):
            expanded = expand_geometry(module, {}, orientation, ENV)
            self.assertEqual(expanded["orientation"], orientation)
        with self.assertRaises(ValueError):
            expand_geometry(module, {}, 45, ENV)


if __name__ == "__main__":
    unittest.main()
