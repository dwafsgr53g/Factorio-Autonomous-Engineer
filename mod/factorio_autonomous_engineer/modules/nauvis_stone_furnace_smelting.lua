-- Early Nauvis stone-furnace smelting bank.
-- unit_count repeats the furnace and its ports deterministically along +x.
return {
  schema_version = 1,
  id = "nauvis.stone_furnace.iron_smelting",
  module_version = 1,
  name = "Stone furnace iron smelting bank",
  description = "One to three stone furnaces with ore, fuel and plate interfaces.",
  category = "smelting",
  surfaces = {"nauvis"},
  stages = {"early_game", "automation_bootstrap", "automation"},
  tags = {"nauvis", "smelting", "furnace", "iron-plate"},
  geometry = {
    footprint = {width = 2, height = 2},
    origin = {x = 0, y = 0},
    supported_orientations = {0},
    entities = {
      {
        id = "furnace",
        name = "stone-furnace",
        position = {x = 1, y = 1},
        direction = 0,
        repeat_by = {parameter = "unit_count", step = {x = 2, y = 0}},
      },
    },
    ports = {
      {
        id = "ore_input",
        type = "item",
        role = "input",
        item = "iron-ore",
        position = {x = 0, y = 1},
        direction = 4,
        repeat_by = {parameter = "unit_count", step = {x = 2, y = 0}},
      },
      {
        id = "fuel_input",
        type = "item",
        role = "input",
        item = "coal",
        position = {x = 1, y = 0},
        direction = 8,
        repeat_by = {parameter = "unit_count", step = {x = 2, y = 0}},
      },
      {
        id = "plate_output",
        type = "item",
        role = "output",
        item = "iron-plate",
        position = {x = 2, y = 1},
        direction = 4,
        repeat_by = {parameter = "unit_count", step = {x = 2, y = 0}},
      },
    },
    reserved = {},
  },
  requirements = {
    technologies = {},
    recipes = {"iron-plate"},
  },
  placement = {
    constraints = {
      {type = "clear_footprint"},
    },
  },
  parameters = {
    unit_count = {
      type = "integer",
      default = 1,
      minimum = 1,
      maximum = 3,
      affects_geometry = true,
      description = "Number of repeated stone furnaces in the bank.",
    },
  },
}
