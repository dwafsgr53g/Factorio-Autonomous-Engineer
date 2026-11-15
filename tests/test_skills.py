import unittest

from factorio_autonomous_engineer.skills import load_skill_pack


class SkillPackTests(unittest.TestCase):
    def test_loads_core_stage_and_planet_skill(self):
        pack = load_skill_pack({"stage": {"id": "early_game"}, "planet": {"name": "nauvis"}})
        self.assertEqual([entry["id"] for entry in pack],
                         ["core_strategy", "stage_early_game", "planet_nauvis"])
        self.assertTrue(all(entry["content"].strip() for entry in pack))

    def test_missing_planet_modifier_does_not_break_core_or_stage(self):
        pack = load_skill_pack({"stage": {"id": "automation"}, "planet": {"name": "modded-world"}})
        self.assertEqual([entry["id"] for entry in pack], ["core_strategy", "stage_automation"])

    def test_unknown_stage_still_loads_core_strategy(self):
        pack = load_skill_pack({"stage": {"id": "unknown-stage"}, "planet": {"name": "unknown"}})
        self.assertEqual(pack[0]["id"], "core_strategy")
        self.assertIn("planner", pack[0]["content"].lower())


if __name__ == "__main__":
    unittest.main()
