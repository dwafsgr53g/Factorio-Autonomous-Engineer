-- Early Nauvis assembling-machine module. The recipe is assigned after the paid ghost
-- revival by the existing construction executor, using the module tag on the ghost.
return {
  schema_version = 1,
  id = "nauvis.assembling_machine_1.gear",
  module_version = 1,
  name = "Assembling machine iron gear",
  description = "One assembling machine configured for iron gear wheels.",
  category = "production",
  surfaces = {"nauvis"},
  stages = {"automation_bootstrap", "automation"},
  tags = {"nauvis", "production", "assembling-machine", "iron-gear-wheel"},
  geometry = {
    footprint = {width = 3, height = 3},
    origin = {x = 0, y = 0},
    supported_orientations = {0},
    entities = {
      {
        id = "assembler",
        name = "assembling-machine-1",
        position = {x = 1.5, y = 1.5},
        direction = 0,
        recipe = "iron-gear-wheel",
      },
    },
    ports = {
      {
        id = "plate_input",
        type = "item",
        role = "input",
        item = "iron-plate",
        position = {x = 0, y = 1.5},
        direction = 4,
      },
      {
        id = "gear_output",
        type = "item",
        role = "output",
        item = "iron-gear-wheel",
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
        id = "service_access",
        area = {x = 0, y = 3, width = 3, height = 1},
        reason = "maintenance access strip",
      },
    },
  },
  requirements = {
    technologies = {"automation"},
    recipes = {"iron-gear-wheel"},
  },
  placement = {
    constraints = {
      {type = "clear_footprint"},
    },
  },
  parameters = {},
}
