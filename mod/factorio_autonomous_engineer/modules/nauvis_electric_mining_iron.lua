-- Early Nauvis iron mining module: one electric mining drill.
-- The drill footprint is 3x3. Its output side faces east when the module is unrotated.
return {
  schema_version = 1,
  id = "nauvis.electric_mining.iron",
  module_version = 1,
  name = "Electric iron mining drill",
  description = "One electric mining drill covering an iron-ore patch with an east output.",
  category = "mining",
  surfaces = {"nauvis"},
  stages = {"early_game", "automation_bootstrap", "automation"},
  tags = {"nauvis", "mining", "electric", "iron-ore"},
  geometry = {
    footprint = {width = 3, height = 3},
    origin = {x = 0, y = 0},
    supported_orientations = {0, 90, 180, 270},
    entities = {
      {
        id = "drill",
        name = "electric-mining-drill",
        position = {x = 1.5, y = 1.5},
        direction = 0,
      },
    },
    ports = {
      {
        id = "ore_output",
        type = "item",
        role = "output",
        item = "iron-ore",
        position = {x = 3, y = 1.5},
        direction = 4,
      },
      {
        id = "power_input",
        type = "electric",
        role = "input",
        position = {x = 1.5, y = 1.5},
        direction = 0,
        connector = "input",
      },
    },
    reserved = {
      {
        id = "output_clearance",
        area = {x = 0, y = 3, width = 3, height = 1},
        reason = "clear approach for the east output",
      },
    },
  },
  requirements = {
    technologies = {"electric-mining-drill"},
    recipes = {},
  },
  placement = {
    constraints = {
      {type = "resource_patch", resource = "iron-ore", minimum_entities = 1,
        minimum_amount = 9},
      {type = "clear_footprint"},
    },
  },
  parameters = {},
}
