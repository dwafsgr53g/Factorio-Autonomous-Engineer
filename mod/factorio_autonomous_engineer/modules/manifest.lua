-- Canonical module manifest for schema v1.
-- Every entry is an explicit path to a declarative data file. There is no runtime
-- filesystem scan; adding a module requires adding exactly one entry here.
return {
  schema_version = 1,
  modules = {
    "modules.nauvis_assembling_machine_1_gear",
    "modules.nauvis_electric_mining_iron",
    "modules.nauvis_stone_furnace_smelting",
  },
}
