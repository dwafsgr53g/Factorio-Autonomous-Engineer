-- Canonical declarative module format, validation and deterministic transforms.
--
-- Module definitions are pure Lua data tables stored under modules/. They contain no
-- functions and are never evaluated as code beyond `require`. This module never creates
-- entities; it only validates definitions and computes local geometry.
local M = {}

M.SCHEMA_VERSION = 1
M.SUPPORTED_ORIENTATIONS = {0, 90, 180, 270}
M.CATEGORIES = {
  mining = true, smelting = true, power = true, production = true,
  logistics = true, other = true,
}
M.STAGES = {
  early_game = 1, automation_bootstrap = 2, automation = 3,
  oil_processing = 4, advanced_industry = 5, space_age = 6,
}
M.ENTITY_TYPES = {
  ["mining-drill"] = true,
  ["furnace"] = true,
  ["assembling-machine"] = true,
  ["transport-belt"] = true,
  ["container"] = true,
  ["electric-pole"] = true,
  ["inserter"] = true,
}
M.PORT_TYPES = {item = true, fluid = true, electric = true}
M.PORT_ROLES = {input = true, output = true, bidirectional = true}

local EPSILON = 1e-9

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
  return finite(value) and value % 1 == 0
end

local function half_grid(value)
  if not finite(value) then return false end
  local doubled = value * 2
  return math.abs(doubled - math.floor(doubled + 0.5)) <= EPSILON
end

local function cardinal_direction(value)
  return integer(value) and value >= 0 and value <= 12 and value % 4 == 0
end

local function is_array(value)
  if type(value) ~= "table" then return false, 0 end
  local count = 0
  for key in pairs(value) do
    if not integer(key) or key < 1 then return false, 0 end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then return false, 0 end
  end
  return true, count
end

local function add_error(errors, code, path, message)
  errors[#errors + 1] = {code = code, path = path, message = message}
end

local function check_keys(value, allowed, path, errors)
  if type(value) ~= "table" then return end
  for key in pairs(value) do
    if not allowed[key] then
      add_error(errors, "unknown_field", path .. "." .. tostring(key),
        "unknown field '" .. tostring(key) .. "'")
    end
  end
end

local function read_vector(value, path, errors, allow_zero)
  if type(value) ~= "table" then
    add_error(errors, "invalid_vector", path, "expected a {x,y} table")
    return nil
  end
  check_keys(value, {x = true, y = true}, path, errors)
  if not finite(value.x) or not finite(value.y) then
    add_error(errors, "invalid_vector", path, "x and y must be finite numbers")
    return nil
  end
  if not half_grid(value.x) or not half_grid(value.y) then
    add_error(errors, "invalid_position", path, "coordinates must be multiples of 0.5")
    return nil
  end
  if not allow_zero and value.x == 0 and value.y == 0 then
    add_error(errors, "invalid_vector", path, "offset must not be zero")
    return nil
  end
  return {x = value.x, y = value.y}
end

local function read_positive_integer(value, path, errors)
  if not integer(value) or value <= 0 then
    add_error(errors, "invalid_dimension", path, "expected a positive integer")
    return nil
  end
  return value
end

local function prototype(env, group, name)
  return env and env.prototypes and env.prototypes[group] and env.prototypes[group][name] or nil
end

local function entity_half_extents(proto, direction)
  local box = proto and proto.collision_box or nil
  if not box then return 0.5, 0.5 end
  local width = box.right_bottom.x - box.left_top.x
  local height = box.right_bottom.y - box.left_top.y
  if direction == 4 or direction == 12 then width, height = height, width end
  return width / 2, height / 2
end

local function validate_parameter_definitions(def, errors)
  local parameters = def.parameters or {}
  if type(parameters) ~= "table" then
    add_error(errors, "invalid_parameters", "parameters", "parameters must be a table")
    return
  end
  for name, spec in pairs(parameters) do
    local path = "parameters." .. tostring(name)
    if type(name) ~= "string" or name == "" then
      add_error(errors, "invalid_parameter_name", path, "parameter names must be non-empty strings")
    elseif type(spec) ~= "table" then
      add_error(errors, "invalid_parameter", path, "parameter definition must be a table")
    else
      check_keys(spec, {type = true, default = true, minimum = true, maximum = true,
        allowed = true, affects_geometry = true, description = true}, path, errors)
      if spec.type == "integer" then
        if not integer(spec.default) then
          add_error(errors, "invalid_parameter_default", path .. ".default",
            "integer parameter requires an integer default")
        end
        if spec.minimum ~= nil and not integer(spec.minimum) then
          add_error(errors, "invalid_parameter_bounds", path .. ".minimum",
            "minimum must be an integer")
        end
        if spec.maximum ~= nil and not integer(spec.maximum) then
          add_error(errors, "invalid_parameter_bounds", path .. ".maximum",
            "maximum must be an integer")
        end
        local minimum = spec.minimum or spec.default
        local maximum = spec.maximum or spec.default
        if integer(minimum) and integer(maximum) and minimum > maximum then
          add_error(errors, "invalid_parameter_bounds", path,
            "minimum must not exceed maximum")
        end
        if integer(spec.default) and integer(minimum) and integer(maximum)
          and (spec.default < minimum or spec.default > maximum) then
          add_error(errors, "invalid_parameter_default", path .. ".default",
            "default is outside the declared bounds")
        end
      elseif spec.type == "string" then
        local allowed, count = is_array(spec.allowed)
        if not allowed or count == 0 then
          add_error(errors, "invalid_parameter_values", path .. ".allowed",
            "string parameter requires a non-empty allowed list")
        else
          local seen = {}
          for index, value in ipairs(spec.allowed) do
            if type(value) ~= "string" then
              add_error(errors, "invalid_parameter_values", path .. ".allowed[" .. index .. "]",
                "allowed values must be strings")
            elseif seen[value] then
              add_error(errors, "invalid_parameter_values", path .. ".allowed[" .. index .. "]",
                "duplicate allowed value")
            end
            seen[value] = true
          end
          if type(spec.default) ~= "string" or not seen[spec.default] then
            add_error(errors, "invalid_parameter_default", path .. ".default",
              "default must be one of the allowed values")
          end
        end
      elseif spec.type == "boolean" then
        if type(spec.default) ~= "boolean" then
          add_error(errors, "invalid_parameter_default", path .. ".default",
            "boolean parameter requires a boolean default")
        end
      else
        add_error(errors, "unsupported_parameter_type", path .. ".type",
          "supported parameter types are integer, string and boolean")
      end
      if spec.affects_geometry ~= nil and type(spec.affects_geometry) ~= "boolean" then
        add_error(errors, "invalid_parameter", path .. ".affects_geometry",
          "affects_geometry must be boolean")
      end
    end
  end
end

local function validate_repeat(def, repeat_spec, path, errors)
  if type(repeat_spec) ~= "table" then
    add_error(errors, "invalid_repeat", path, "repeat must be a table")
    return
  end
  check_keys(repeat_spec, {parameter = true, step = true}, path, errors)
  if type(repeat_spec.parameter) ~= "string" then
    add_error(errors, "invalid_repeat", path .. ".parameter", "parameter must be a string")
  else
    local spec = (def.parameters or {})[repeat_spec.parameter]
    if not spec then
      add_error(errors, "unknown_parameter", path .. ".parameter",
        "unknown repeat parameter '" .. repeat_spec.parameter .. "'")
    elseif spec.type ~= "integer" then
      add_error(errors, "invalid_repeat", path .. ".parameter",
        "repeat parameters must be integer parameters")
    elseif spec.affects_geometry ~= true then
      add_error(errors, "invalid_repeat", path .. ".parameter",
        "repeat parameters must declare affects_geometry=true")
    end
  end
  read_vector(repeat_spec.step, path .. ".step", errors, false)
end

local function validate_entity(def, entity, index, env, errors)
  local path = "geometry.entities[" .. index .. "]"
  if type(entity) ~= "table" then
    add_error(errors, "invalid_entity", path, "entity must be a table")
    return
  end
  check_keys(entity, {id = true, name = true, position = true, direction = true,
    quality = true, recipe = true, recipe_parameter = true, repeat_by = true}, path, errors)
  if type(entity.id) ~= "string" or entity.id == "" then
    add_error(errors, "invalid_entity_id", path .. ".id", "entity id must be a non-empty string")
  elseif string.find(entity.id, "[^%w_%-]") then
    add_error(errors, "invalid_entity_id", path .. ".id",
      "entity id may contain only letters, digits, '_' and '-'")
  end
  local proto = nil
  if type(entity.name) ~= "string" or entity.name == "" then
    add_error(errors, "invalid_entity_name", path .. ".name", "entity name must be a string")
  else
    proto = prototype(env, "entity", entity.name)
    if not proto then
      add_error(errors, "unknown_entity_prototype", path .. ".name",
        "unknown entity prototype '" .. entity.name .. "'")
    else
      if not M.ENTITY_TYPES[proto.type] then
        add_error(errors, "unsupported_entity_type", path .. ".name",
          "entity type '" .. tostring(proto.type) .. "' is not supported by module schema v1")
      end
      local items = proto.items_to_place_this
      if not items or #items == 0 then
        add_error(errors, "no_placeable_item", path .. ".name",
          "entity prototype has no placeable item")
      end
    end
  end
  read_vector(entity.position, path .. ".position", errors, true)
  if not cardinal_direction(entity.direction) then
    add_error(errors, "invalid_direction", path .. ".direction",
      "direction must be one of 0, 4, 8 or 12 (north/east/south/west)")
  end
  if entity.quality ~= nil then
    if type(entity.quality) ~= "string" or not prototype(env, "quality", entity.quality) then
      add_error(errors, "unknown_quality", path .. ".quality",
        "unknown quality '" .. tostring(entity.quality) .. "'")
    end
  end
  if entity.recipe ~= nil and entity.recipe_parameter ~= nil then
    add_error(errors, "unsupported_entity_configuration", path,
      "recipe and recipe_parameter are mutually exclusive")
  end
  if entity.recipe ~= nil then
    if type(entity.recipe) ~= "string" then
      add_error(errors, "invalid_recipe", path .. ".recipe", "recipe must be a string")
    else
      local recipe = prototype(env, "recipe", entity.recipe)
      if not recipe then
        add_error(errors, "unknown_recipe", path .. ".recipe",
          "unknown recipe '" .. entity.recipe .. "'")
      elseif not proto or proto.type ~= "assembling-machine" then
        add_error(errors, "unsupported_entity_configuration", path .. ".recipe",
          "recipe assignment is supported only for assembling-machine entities in schema v1")
      elseif proto.crafting_categories and recipe.categories then
        local compatible = false
        for _, category in pairs(recipe.categories) do
          if proto.crafting_categories[category] then compatible = true break end
        end
        if not compatible then
          add_error(errors, "incompatible_recipe", path .. ".recipe",
            "recipe category is not accepted by the assembling machine")
        end
      end
    end
  end
  if entity.recipe_parameter ~= nil then
    add_error(errors, "unsupported_entity_configuration", path .. ".recipe_parameter",
      "recipe_parameter is not implemented in schema v1; use a fixed recipe")
  end
  if entity.repeat_by ~= nil then
    validate_repeat(def, entity.repeat_by, path .. ".repeat_by", errors)
  end
end

local function validate_port(def, port, index, env, errors)
  local path = "geometry.ports[" .. index .. "]"
  if type(port) ~= "table" then
    add_error(errors, "invalid_port", path, "port must be a table")
    return
  end
  check_keys(port, {id = true, type = true, role = true, position = true,
    direction = true, item = true, fluid = true, repeat_by = true,
    connector = true, capacity = true}, path, errors)
  if type(port.id) ~= "string" or port.id == "" then
    add_error(errors, "invalid_port_id", path .. ".id", "port id must be a non-empty string")
  elseif string.find(port.id, "[^%w_%-]") then
    add_error(errors, "invalid_port_id", path .. ".id",
      "port id may contain only letters, digits, '_' and '-'")
  end
  if not M.PORT_TYPES[port.type] then
    add_error(errors, "invalid_port_type", path .. ".type",
      "port type must be item, fluid or electric")
  end
  if not M.PORT_ROLES[port.role] then
    add_error(errors, "invalid_port_role", path .. ".role",
      "port role must be input, output or bidirectional")
  end
  read_vector(port.position, path .. ".position", errors, true)
  if not cardinal_direction(port.direction) then
    add_error(errors, "invalid_direction", path .. ".direction",
      "direction must be one of 0, 4, 8 or 12")
  end
  if port.type == "item" then
    if type(port.item) ~= "string" or not prototype(env, "item", port.item) then
      add_error(errors, "unknown_item", path .. ".item",
        "item port requires a known item prototype")
    end
    if port.fluid ~= nil then
      add_error(errors, "invalid_port", path .. ".fluid", "item port must not declare a fluid")
    end
  elseif port.type == "fluid" then
    if type(port.fluid) ~= "string" or not prototype(env, "fluid", port.fluid) then
      add_error(errors, "unknown_fluid", path .. ".fluid",
        "fluid port requires a known fluid prototype")
    end
    if port.item ~= nil then
      add_error(errors, "invalid_port", path .. ".item", "fluid port must not declare an item")
    end
  elseif port.type == "electric" then
    if port.item ~= nil or port.fluid ~= nil then
      add_error(errors, "invalid_port", path,
        "electric port must not declare an item or fluid")
    end
    if port.connector ~= nil and port.connector ~= "input" and port.connector ~= "output" then
      add_error(errors, "invalid_port", path .. ".connector",
        "connector must be 'input' or 'output'")
    end
  end
  if port.repeat_by ~= nil then
    validate_repeat(def, port.repeat_by, path .. ".repeat_by", errors)
  end
end

local function validate_reserved(reserved, index, errors)
  local path = "geometry.reserved[" .. index .. "]"
  if type(reserved) ~= "table" then
    add_error(errors, "invalid_reserved_area", path, "reserved area must be a table")
    return
  end
  check_keys(reserved, {id = true, area = true, reason = true}, path, errors)
  if type(reserved.id) ~= "string" or reserved.id == "" then
    add_error(errors, "invalid_reserved_area", path .. ".id", "reserved id must be a string")
  end
  if type(reserved.area) ~= "table" then
    add_error(errors, "invalid_reserved_area", path .. ".area", "area must be a table")
    return
  end
  check_keys(reserved.area, {x = true, y = true, width = true, height = true},
    path .. ".area", errors)
  if not finite(reserved.area.x) or not half_grid(reserved.area.x)
    or not finite(reserved.area.y) or not half_grid(reserved.area.y) then
    add_error(errors, "invalid_reserved_area", path .. ".area",
      "x and y must be multiples of 0.5")
  elseif reserved.area.x < 0 or reserved.area.y < 0 then
    add_error(errors, "invalid_reserved_area", path .. ".area",
      "reserved areas must start at or after the module origin")
  end
  read_positive_integer(reserved.area.width, path .. ".area.width", errors)
  read_positive_integer(reserved.area.height, path .. ".area.height", errors)
end

local function validate_constraint(constraint, index, env, errors)
  local path = "placement.constraints[" .. index .. "]"
  if type(constraint) ~= "table" then
    add_error(errors, "invalid_constraint", path, "constraint must be a table")
    return
  end
  local kind = constraint.type
  if kind == "resource_patch" then
    check_keys(constraint, {type = true, resource = true, minimum_amount = true,
      minimum_entities = true}, path, errors)
    local proto = type(constraint.resource) == "string"
      and prototype(env, "entity", constraint.resource) or nil
    if not proto or proto.type ~= "resource" then
      add_error(errors, "unknown_resource", path .. ".resource",
        "resource_patch requires a known resource entity prototype")
    end
    if constraint.minimum_amount ~= nil and not integer(constraint.minimum_amount) then
      add_error(errors, "invalid_constraint", path .. ".minimum_amount",
        "minimum_amount must be an integer")
    end
    if constraint.minimum_entities ~= nil and not integer(constraint.minimum_entities) then
      add_error(errors, "invalid_constraint", path .. ".minimum_entities",
        "minimum_entities must be an integer")
    end
  elseif kind == "near_water" then
    check_keys(constraint, {type = true, max_distance = true}, path, errors)
    if constraint.max_distance ~= nil and (not finite(constraint.max_distance)
      or constraint.max_distance < 0) then
      add_error(errors, "invalid_constraint", path .. ".max_distance",
        "max_distance must be a non-negative number")
    end
  elseif kind == "clear_footprint" then
    check_keys(constraint, {type = true}, path, errors)
  elseif kind == "avoid_entities" then
    check_keys(constraint, {type = true, types = true, names = true}, path, errors)
    if constraint.types ~= nil then
      local array, count = is_array(constraint.types)
      if not array or count == 0 then
        add_error(errors, "invalid_constraint", path .. ".types",
          "types must be a non-empty list")
      end
    end
    if constraint.names ~= nil then
      local array, count = is_array(constraint.names)
      if not array or count == 0 then
        add_error(errors, "invalid_constraint", path .. ".names",
          "names must be a non-empty list")
      end
    end
  elseif kind == "avoid_tiles" then
    check_keys(constraint, {type = true, names = true}, path, errors)
    if constraint.names ~= nil then
      local array, count = is_array(constraint.names)
      if not array or count == 0 then
        add_error(errors, "invalid_constraint", path .. ".names",
          "names must be a non-empty list")
      end
    end
  elseif kind == "electric_network" then
    check_keys(constraint, {type = true, max_distance = true}, path, errors)
    if constraint.max_distance ~= nil and (not finite(constraint.max_distance)
      or constraint.max_distance < 0) then
      add_error(errors, "invalid_constraint", path .. ".max_distance",
        "max_distance must be a non-negative number")
    end
  else
    add_error(errors, "unsupported_constraint", path .. ".type",
      "unsupported placement constraint '" .. tostring(kind) .. "'")
  end
end

local function validate_requirements(def, env, errors)
  local requirements = def.requirements or {}
  if type(requirements) ~= "table" then
    add_error(errors, "invalid_requirements", "requirements", "requirements must be a table")
    return
  end
  check_keys(requirements, {technologies = true, recipes = true, stage = true}, "requirements",
    errors)
  for _, key in pairs({"technologies", "recipes"}) do
    if requirements[key] ~= nil then
      local array, count = is_array(requirements[key])
      if not array then
        add_error(errors, "invalid_requirements", "requirements." .. key,
          key .. " must be a list")
      else
        local seen = {}
        for index, name in ipairs(requirements[key]) do
          local path = "requirements." .. key .. "[" .. index .. "]"
          if type(name) ~= "string" then
            add_error(errors, "invalid_requirements", path, "expected a prototype name")
          elseif seen[name] then
            add_error(errors, "invalid_requirements", path, "duplicate name '" .. name .. "'")
          elseif not prototype(env, key == "technologies" and "technology" or "recipe", name) then
            add_error(errors, key == "technologies" and "unknown_technology" or "unknown_recipe",
              path, "unknown " .. (key == "technologies" and "technology" or "recipe")
              .. " '" .. name .. "'")
          end
          seen[name] = true
        end
      end
    end
  end
  if requirements.stage ~= nil then
    if type(requirements.stage) ~= "string" or not M.STAGES[requirements.stage] then
      add_error(errors, "unknown_stage", "requirements.stage",
        "unknown stage '" .. tostring(requirements.stage) .. "'")
    end
  end
end

-- Collect geometry-affecting integer parameter combinations. The parameter space is
-- deliberately small and finite; arbitrary formulas are not part of the format.
local function geometry_combinations(def, errors)
  local combos = {{}}
  for name, spec in pairs(def.parameters or {}) do
    if spec.type == "integer" and spec.affects_geometry == true then
      local minimum = spec.minimum or spec.default
      local maximum = spec.maximum or spec.default
      local next_combos = {}
      for _, combo in ipairs(combos) do
        for value = minimum, maximum do
          local copy = {}
          for key, existing in pairs(combo) do copy[key] = existing end
          copy[name] = value
          next_combos[#next_combos + 1] = copy
        end
      end
      combos = next_combos
      if #combos > 64 then
        add_error(errors, "too_many_parameter_combinations", "parameters",
          "geometry parameter combinations exceed the supported limit of 64")
        return {{}}
      end
    end
  end
  return combos
end

local function with_defaults(def, combo)
  local values = combo
  for name, spec in pairs(def.parameters or {}) do
    if values[name] == nil then values[name] = spec.default end
  end
  return values
end

local function resolved_entities(def, values, errors)
  local result = {}
  for index, entity in ipairs((def.geometry or {}).entities or {}) do
    local count = 1
    if entity.repeat_by then
      count = values[entity.repeat_by.parameter] or 1
    end
    for copy = 1, count do
      local offset_x = entity.repeat_by and entity.repeat_by.step.x * (copy - 1) or 0
      local offset_y = entity.repeat_by and entity.repeat_by.step.y * (copy - 1) or 0
      result[#result + 1] = {
        id = copy == 1 and entity.id or (entity.id .. "_" .. copy),
        base_id = entity.id,
        name = entity.name,
        position = {x = entity.position.x + offset_x, y = entity.position.y + offset_y},
        direction = entity.direction,
        quality = entity.quality or "normal",
        recipe = entity.recipe,
        copy = copy,
      }
    end
  end
  return result
end

local function resolved_ports(def, values, errors)
  local result = {}
  for index, port in ipairs((def.geometry or {}).ports or {}) do
    local count = 1
    if port.repeat_by then count = values[port.repeat_by.parameter] or 1 end
    for copy = 1, count do
      local offset_x = port.repeat_by and port.repeat_by.step.x * (copy - 1) or 0
      local offset_y = port.repeat_by and port.repeat_by.step.y * (copy - 1) or 0
      result[#result + 1] = {
        id = copy == 1 and port.id or (port.id .. "_" .. copy),
        base_id = port.id,
        type = port.type,
        role = port.role,
        position = {x = port.position.x + offset_x, y = port.position.y + offset_y},
        direction = port.direction,
        item = port.item,
        fluid = port.fluid,
        connector = port.connector,
        capacity = port.capacity,
        copy = copy,
      }
    end
  end
  return result
end

local function base_bounds(def, entities, ports, include_content)
  local geometry = def.geometry or {}
  local footprint = geometry.footprint or {}
  local width, height = footprint.width or 0, footprint.height or 0
  for _, reserved in pairs(geometry.reserved or {}) do
    local area = reserved.area
    if area then
      width = math.max(width, area.x + area.width)
      height = math.max(height, area.y + area.height)
    end
  end
  if include_content then
    for _, entity in pairs(entities) do
      local proto = prototypes.entity[entity.name]
      local half_x, half_y = entity_half_extents(proto, entity.direction)
      width = math.max(width, entity.position.x + half_x)
      height = math.max(height, entity.position.y + half_y)
    end
    for _, port in pairs(ports) do
      width = math.max(width, port.position.x)
      height = math.max(height, port.position.y)
    end
  end
  return width, height
end

local function rotate_point(point, width, height, orientation)
  local steps = orientation / 90
  if steps == 0 then return {x = point.x, y = point.y} end
  if steps == 1 then return {x = height - point.y, y = point.x} end
  if steps == 2 then return {x = width - point.x, y = height - point.y} end
  return {x = point.y, y = width - point.x}
end

local function rotate_area(area, width, height, orientation)
  local steps = orientation / 90
  if steps == 0 then
    return {x = area.x, y = area.y, width = area.width, height = area.height}
  elseif steps == 1 then
    return {x = height - area.y - area.height, y = area.x,
      width = area.height, height = area.width}
  elseif steps == 2 then
    return {x = width - area.x - area.width, y = height - area.y - area.height,
      width = area.width, height = area.height}
  end
  return {x = area.y, y = width - area.x - area.width,
    width = area.height, height = area.width}
end

local function rotate_direction(direction, orientation)
  return (direction + (orientation / 90) * 4) % 16
end

local function expand_raw(def, values, orientation)
  local entities = resolved_entities(def, values, {})
  local ports = resolved_ports(def, values, {})
  local width, height = base_bounds(def, entities, ports, true)
  local result_entities, result_ports, result_reserved = {}, {}, {}
  for _, entity in ipairs(entities) do
    local position = rotate_point(entity.position, width, height, orientation)
    result_entities[#result_entities + 1] = {
      id = entity.id, base_id = entity.base_id, name = entity.name,
      position = position, direction = rotate_direction(entity.direction, orientation),
      quality = entity.quality, recipe = entity.recipe, copy = entity.copy,
    }
  end
  for _, port in ipairs(ports) do
    local position = rotate_point(port.position, width, height, orientation)
    result_ports[#result_ports + 1] = {
      id = port.id, base_id = port.base_id, type = port.type, role = port.role,
      position = position, direction = rotate_direction(port.direction, orientation),
      item = port.item, fluid = port.fluid, connector = port.connector,
      capacity = port.capacity, copy = port.copy,
    }
  end
  for index, reserved in ipairs((def.geometry or {}).reserved or {}) do
    local area = rotate_area(reserved.area, width, height, orientation)
    result_reserved[#result_reserved + 1] = {
      id = reserved.id, area = area, reason = reserved.reason,
    }
  end
  local rotated_width, rotated_height = width, height
  if orientation == 90 or orientation == 270 then
    rotated_width, rotated_height = height, width
  end
  return {
    footprint = {width = rotated_width, height = rotated_height},
    base_footprint = {width = width, height = height},
    entities = result_entities, ports = result_ports, reserved = result_reserved,
    orientation = orientation, parameters = values,
  }
end

local function bounds_contain(width, height, box)
  return box.left_top.x >= -EPSILON and box.left_top.y >= -EPSILON
    and box.right_bottom.x <= width + EPSILON and box.right_bottom.y <= height + EPSILON
end

local function entity_box(entity, env)
  local proto = prototype(env, "entity", entity.name)
  local half_x, half_y = entity_half_extents(proto, entity.direction)
  return {
    left_top = {x = entity.position.x - half_x, y = entity.position.y - half_y},
    right_bottom = {x = entity.position.x + half_x, y = entity.position.y + half_y},
  }
end

local function boxes_overlap(a, b)
  return a.left_top.x < b.right_bottom.x - EPSILON
    and b.left_top.x < a.right_bottom.x - EPSILON
    and a.left_top.y < b.right_bottom.y - EPSILON
    and b.left_top.y < a.right_bottom.y - EPSILON
end

local function validate_geometry_for(def, values, orientation, env, errors)
  local expanded = expand_raw(def, values, orientation)
  local width, height = expanded.footprint.width, expanded.footprint.height
  local base_width = def.geometry.footprint.width
  local base_height = def.geometry.footprint.height
  local entity_ids, port_ids = {}, {}
  local boxes = {}
  for _, entity in ipairs(expanded.entities) do
    if entity_ids[entity.id] then
      add_error(errors, "duplicate_entity_id", "geometry.entities",
        "duplicate expanded entity id '" .. entity.id .. "'")
    end
    entity_ids[entity.id] = true
    local box = entity_box(entity, env)
    if not bounds_contain(width, height, box) then
      add_error(errors, "entity_outside_footprint", "geometry.entities." .. entity.id,
        "entity '" .. entity.name .. "' extends outside the module footprint")
    end
    if orientation == 0 and entity.copy == 1 and not bounds_contain(base_width, base_height, box) then
      add_error(errors, "entity_outside_footprint", "geometry.entities." .. entity.id,
        "the first repeated entity must fit the declared base footprint")
    end
    for other_id, other_box in pairs(boxes) do
      if boxes_overlap(box, other_box) then
        add_error(errors, "entity_overlap", "geometry.entities." .. entity.id,
          "entity overlaps '" .. other_id .. "'")
      end
    end
    boxes[entity.id] = box
  end
  for _, port in ipairs(expanded.ports) do
    if port_ids[port.id] then
      add_error(errors, "duplicate_port_id", "geometry.ports",
        "duplicate expanded port id '" .. port.id .. "'")
    end
    port_ids[port.id] = true
    if port.position.x < -EPSILON or port.position.y < -EPSILON
      or port.position.x > width + EPSILON or port.position.y > height + EPSILON then
      add_error(errors, "port_outside_footprint", "geometry.ports." .. port.id,
        "port position lies outside the module footprint")
    end
    if orientation == 0 and port.copy == 1 and (port.position.x < -EPSILON
      or port.position.y < -EPSILON or port.position.x > base_width + EPSILON
      or port.position.y > base_height + EPSILON) then
      add_error(errors, "port_outside_footprint", "geometry.ports." .. port.id,
        "the first repeated port must fit the declared base footprint")
    end
  end
  for _, reserved in ipairs(expanded.reserved) do
    local area = reserved.area
    if area.x < -EPSILON or area.y < -EPSILON
      or area.x + area.width > width + EPSILON
      or area.y + area.height > height + EPSILON then
      add_error(errors, "reserved_outside_footprint", "geometry.reserved." .. reserved.id,
        "reserved area lies outside the effective module bounds")
    end
  end
end

function M.validate_definition(def, env)
  env = env or {prototypes = prototypes}
  local errors = {}
  if type(def) ~= "table" then
    add_error(errors, "invalid_definition", "", "module definition must be a table")
    return errors
  end
  check_keys(def, {schema_version = true, id = true, module_version = true,
    name = true, description = true, category = true, surfaces = true,
    stages = true, tags = true, geometry = true, requirements = true,
    placement = true, parameters = true}, "", errors)
  if def.schema_version ~= M.SCHEMA_VERSION then
    add_error(errors, "unsupported_schema_version", "schema_version",
      "expected schema_version " .. M.SCHEMA_VERSION .. ", got "
      .. tostring(def.schema_version))
  end
  if type(def.id) ~= "string" or not string.match(def.id, "^[a-z0-9][a-z0-9_.%-]*$") then
    add_error(errors, "invalid_module_id", "id",
      "module id must match ^[a-z0-9][a-z0-9_.-]*$")
  end
  if not integer(def.module_version) or def.module_version < 1 then
    add_error(errors, "invalid_module_version", "module_version",
      "module_version must be a positive integer")
  end
  if type(def.name) ~= "string" or def.name == "" then
    add_error(errors, "invalid_name", "name", "name must be a non-empty string")
  end
  if type(def.description) ~= "string" or def.description == "" then
    add_error(errors, "invalid_description", "description",
      "description must be a non-empty string")
  end
  if not M.CATEGORIES[def.category] then
    add_error(errors, "invalid_category", "category",
      "category must be one of mining, smelting, power, production, logistics or other")
  end
  local surfaces, surface_count = is_array(def.surfaces)
  if not surfaces or surface_count == 0 then
    add_error(errors, "invalid_surfaces", "surfaces", "surfaces must be a non-empty list")
  else
    for index, name in ipairs(def.surfaces) do
      if type(name) ~= "string" or name == "" then
        add_error(errors, "invalid_surfaces", "surfaces[" .. index .. "]",
          "surface names must be non-empty strings")
      end
    end
  end
  local stages, stage_count = is_array(def.stages)
  if not stages or stage_count == 0 then
    add_error(errors, "invalid_stages", "stages", "stages must be a non-empty list")
  else
    for index, stage in ipairs(def.stages) do
      if not M.STAGES[stage] then
        add_error(errors, "unknown_stage", "stages[" .. index .. "]",
          "unknown stage '" .. tostring(stage) .. "'")
      end
    end
  end
  if def.tags ~= nil then
    local tags, count = is_array(def.tags)
    if not tags then
      add_error(errors, "invalid_tags", "tags", "tags must be a list of strings")
    else
      for index, tag in ipairs(def.tags) do
        if type(tag) ~= "string" then
          add_error(errors, "invalid_tags", "tags[" .. index .. "]", "tag must be a string")
        end
      end
    end
  end
  validate_parameter_definitions(def, errors)
  local geometry = def.geometry
  if type(geometry) ~= "table" then
    add_error(errors, "invalid_geometry", "geometry", "geometry must be a table")
    return errors
  end
  check_keys(geometry, {footprint = true, origin = true, entities = true, ports = true,
    reserved = true, supported_orientations = true}, "geometry", errors)
  if type(geometry.footprint) ~= "table" then
    add_error(errors, "invalid_footprint", "geometry.footprint",
      "footprint must be a table")
  else
    check_keys(geometry.footprint, {width = true, height = true}, "geometry.footprint", errors)
    read_positive_integer(geometry.footprint.width, "geometry.footprint.width", errors)
    read_positive_integer(geometry.footprint.height, "geometry.footprint.height", errors)
  end
  if type(geometry.origin) ~= "table" then
    add_error(errors, "invalid_origin", "geometry.origin", "origin must be a table")
  else
    check_keys(geometry.origin, {x = true, y = true}, "geometry.origin", errors)
    if geometry.origin.x ~= 0 or geometry.origin.y ~= 0 then
      add_error(errors, "unsupported_origin", "geometry.origin",
        "schema v1 requires the origin at the top-left corner {x=0,y=0}")
    end
  end
  local entities, entity_count = is_array(geometry.entities)
  if not entities or entity_count == 0 then
    add_error(errors, "invalid_entities", "geometry.entities",
      "entities must be a non-empty list")
  else
    for index, entity in ipairs(geometry.entities) do
      validate_entity(def, entity, index, env, errors)
    end
  end
  local ports, port_count = is_array(geometry.ports)
  if not ports or port_count == 0 then
    add_error(errors, "invalid_ports", "geometry.ports", "ports must be a non-empty list")
  else
    for index, port in ipairs(geometry.ports) do
      validate_port(def, port, index, env, errors)
    end
  end
  if geometry.reserved ~= nil then
    local reserved, reserved_count = is_array(geometry.reserved)
    if not reserved then
      add_error(errors, "invalid_reserved_area", "geometry.reserved",
        "reserved must be a list")
    else
      for index, area in ipairs(geometry.reserved) do
        validate_reserved(area, index, errors)
      end
    end
  end
  local orientations, orientation_count = is_array(geometry.supported_orientations)
  if not orientations or orientation_count == 0 then
    add_error(errors, "invalid_orientations", "geometry.supported_orientations",
      "supported_orientations must be a non-empty list")
  else
    local seen = {}
    for index, orientation in ipairs(geometry.supported_orientations) do
      if orientation ~= 0 and orientation ~= 90 and orientation ~= 180
        and orientation ~= 270 then
        add_error(errors, "invalid_orientation", "geometry.supported_orientations["
          .. index .. "]", "orientation must be 0, 90, 180 or 270")
      elseif seen[orientation] then
        add_error(errors, "invalid_orientation", "geometry.supported_orientations["
          .. index .. "]", "duplicate orientation")
      end
      seen[orientation] = true
    end
  end
  validate_requirements(def, env, errors)
  local placement = def.placement
  if type(placement) ~= "table" then
    add_error(errors, "invalid_placement", "placement", "placement must be a table")
  else
    check_keys(placement, {constraints = true}, "placement", errors)
    local constraints, constraint_count = is_array(placement.constraints)
    if not constraints or constraint_count == 0 then
      add_error(errors, "invalid_constraints", "placement.constraints",
        "constraints must be a non-empty list")
    else
      for index, constraint in ipairs(placement.constraints) do
        validate_constraint(constraint, index, env, errors)
      end
    end
  end
  if #errors > 0 then return errors end

  local combinations = geometry_combinations(def, errors)
  for _, combo in ipairs(combinations) do
    local values = with_defaults(def, combo)
    for _, orientation in ipairs(geometry.supported_orientations) do
      validate_geometry_for(def, values, orientation, env, errors)
    end
  end
  return errors
end

function M.resolve_parameters(def, requested)
  requested = requested or {}
  local errors = {}
  for name in pairs(requested) do
    if not (def.parameters or {})[name] then
      errors[#errors + 1] = {
        code = "unknown_parameter", path = "parameters." .. tostring(name),
        message = "unknown parameter '" .. tostring(name) .. "'",
      }
    end
  end
  local values = {}
  for name, spec in pairs(def.parameters or {}) do
    local value = requested[name]
    if value == nil then value = spec.default end
    if spec.type == "integer" then
      if not integer(value) then
        errors[#errors + 1] = {code = "invalid_parameter_value", path = "parameters." .. name,
          message = "parameter '" .. name .. "' must be an integer"}
      else
        local minimum = spec.minimum or spec.default
        local maximum = spec.maximum or spec.default
        if value < minimum or value > maximum then
          errors[#errors + 1] = {code = "invalid_parameter_value",
            path = "parameters." .. name,
            message = "parameter '" .. name .. "' must be between " .. minimum
              .. " and " .. maximum}
        end
      end
    elseif spec.type == "string" then
      local allowed = false
      for _, entry in ipairs(spec.allowed or {}) do
        if entry == value then allowed = true break end
      end
      if type(value) ~= "string" or not allowed then
        errors[#errors + 1] = {code = "invalid_parameter_value", path = "parameters." .. name,
          message = "parameter '" .. name .. "' is not an allowed value"}
      end
    elseif spec.type == "boolean" then
      if type(value) ~= "boolean" then
        errors[#errors + 1] = {code = "invalid_parameter_value", path = "parameters." .. name,
          message = "parameter '" .. name .. "' must be a boolean"}
      end
    end
    values[name] = value
  end
  if #errors > 0 then return nil, errors end
  return values
end

function M.expand(def, values, orientation)
  values = values or {}
  local resolved, errors = M.resolve_parameters(def, values)
  if not resolved then return nil, errors end
  local supported = false
  for _, candidate in ipairs((def.geometry or {}).supported_orientations or {}) do
    if candidate == orientation then supported = true break end
  end
  if not supported then
    return nil, {{code = "unsupported_orientation", path = "orientation",
      message = "orientation " .. tostring(orientation) .. " is not supported by this module"}}
  end
  local expanded = expand_raw(def, resolved, orientation)
  return expanded
end

function M.availability(def, env)
  local reasons = {}
  env = env or {}
  if env.surface then
    local allowed = false
    local surface_name = env.surface.name
    local planet_name = env.surface.planet and env.surface.planet.name or nil
    for _, name in ipairs(def.surfaces or {}) do
      if name == surface_name or (planet_name and name == planet_name) then
        allowed = true
        break
      end
    end
    if not allowed then reasons[#reasons + 1] = "unsupported_surface" end
  end
  if env.stage and def.requirements and def.requirements.stage then
    local required = M.STAGES[def.requirements.stage] or 0
    local current = M.STAGES[env.stage] or 0
    if current < required then reasons[#reasons + 1] = "stage_not_reached" end
  end
  local force = env.force
  if force then
    for _, name in ipairs(((def.requirements or {}).technologies) or {}) do
      local technology = force.technologies[name]
      if not technology or not technology.researched then
        reasons[#reasons + 1] = "technology_not_researched:" .. name
      end
    end
    for _, name in ipairs(((def.requirements or {}).recipes) or {}) do
      local recipe = force.recipes[name]
      if not recipe or not recipe.enabled then
        reasons[#reasons + 1] = "recipe_not_available:" .. name
      end
    end
    for _, entity in ipairs((def.geometry or {}).entities or {}) do
      local proto = prototype(env, "entity", entity.name)
      for _, item in pairs(proto and proto.items_to_place_this or {}) do
        local recipe = force.recipes[item.name]
        if recipe and not recipe.enabled then
          reasons[#reasons + 1] = "item_recipe_not_available:" .. item.name
        elseif not recipe then
          reasons[#reasons + 1] = "item_recipe_not_available:" .. item.name
        end
      end
    end
  end
  return {available = #reasons == 0, reasons = reasons}
end

function M.cost_estimate(def, values, orientation)
  local expanded = M.expand(def, values or {}, orientation or 0)
  if not expanded then return nil end
  local map, list = {}, {}
  for _, entity in ipairs(expanded.entities) do
    local proto = prototypes.entity[entity.name]
    for _, item in pairs(proto and proto.items_to_place_this or {}) do
      local quality = entity.quality or "normal"
      local key = item.name .. ":" .. quality
      local entry = map[key]
      if entry then
        entry.count = entry.count + item.count
      else
        entry = {name = item.name, count = item.count, quality = quality}
        map[key] = entry
        list[#list + 1] = entry
      end
    end
  end
  table.sort(list, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.quality < b.quality
  end)
  return list
end

function M.summary(def)
  local parameter_names = {}
  for name in pairs(def.parameters or {}) do parameter_names[#parameter_names + 1] = name end
  table.sort(parameter_names)
  local entity_ids, port_ids = {}, {}
  for _, entity in ipairs((def.geometry or {}).entities or {}) do
    entity_ids[#entity_ids + 1] = entity.id
  end
  for _, port in ipairs((def.geometry or {}).ports or {}) do
    port_ids[#port_ids + 1] = port.id
  end
  return {
    id = def.id, schema_version = def.schema_version, module_version = def.module_version,
    name = def.name, category = def.category, surfaces = def.surfaces, stages = def.stages,
    tags = def.tags, parameters = parameter_names, entity_ids = entity_ids,
    port_ids = port_ids, orientations = def.geometry.supported_orientations,
  }
end

return M
