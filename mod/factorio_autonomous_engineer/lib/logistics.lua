-- Physical logistics planner for Stage 6.
--
-- This module turns the logical item connections of a Stage-5 layout plan into real
-- Factorio infrastructure: transport belts, inserters, an output chest, a fuel feed from
-- an ordinary coal chest and electric poles connected to an existing powered network.
--
-- Rules enforced here:
--   * planning creates no entity and spends no item;
--   * every physical entity is first an ordinary entity-ghost;
--   * paid revival remains the Stage-3 construction executor;
--   * LuaTransportLine is never mutated (no insert/remove/clear/force_insert);
--   * machine inventories are never modified by production code;
--   * no energy is fabricated and no wire reach check is bypassed.
--
-- The planner is deliberately bounded: it routes one linear eastward chain inside the
-- existing collaboration work area. Anything outside that scope is reported, not guessed.
local construction = require("lib.construction")
local collaboration = require("lib.collaboration")
local clearing = require("lib.clearing")
local production_graph = require("lib.production_graph")

local M = {}

M.SCHEMA_VERSION = 1
local MAX_ROUTE_NODES = 4096
local MAX_ROUTE_LENGTH = 128
local MAX_POLE_NODES = 4096
local POLES = {"medium-electric-pole", "small-electric-pole"}
local OUTPUT_CHEST = "wooden-chest"
local BELT = "transport-belt"
local INSERTER = "inserter"

local DIR = {
  north = 0, east = 4, south = 8, west = 12,
}
local VEC = {
  [0] = {dx = 0, dy = -1},
  [4] = {dx = 1, dy = 0},
  [8] = {dx = 0, dy = 1},
  [12] = {dx = -1, dy = 0},
}
local NEIGHBOURS = {{0, -1}, {1, 0}, {0, 1}, {-1, 0}}  -- N, E, S, W (deterministic)

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function tile_of(position)
  return {x = math.floor(position.x), y = math.floor(position.y)}
end

local function tile_center(tile)
  return {x = tile.x + 0.5, y = tile.y + 0.5}
end

local function tile_key(tile)
  return tostring(tile.x) .. "," .. tostring(tile.y)
end

local function same_tile(a, b)
  return a.x == b.x and a.y == b.y
end

local function copy_tile(tile)
  return {x = tile.x, y = tile.y}
end

local function direction_between(a, b)
  if b.x > a.x then return DIR.east end
  if b.x < a.x then return DIR.west end
  if b.y > a.y then return DIR.south end
  return DIR.north
end

local function add_tile(tile, direction, count)
  local vector = VEC[direction]
  return {x = tile.x + vector.dx * (count or 1), y = tile.y + vector.dy * (count or 1)}
end

local function hash32(text, seed)
  local value = seed % 2147483647
  for index = 1, #text do
    value = (value * 131 + string.byte(text, index)) % 2147483647
  end
  return value
end

local function digest(text)
  return string.format("%08x%08x", hash32(text, 5381), hash32(text, 52711))
end

local function sorted_pairs_keys(value)
  local keys = {}
  for key in pairs(value or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local function ordered_pairs(value)
  local keys = sorted_pairs_keys(value)
  local index = 0
  return function()
    index = index + 1
    local key = keys[index]
    if key == nil then return nil end
    return key, value[key]
  end
end

-- ---------------------------------------------------------------------------
-- Deterministic bounded route search
-- ---------------------------------------------------------------------------

-- A* over cardinal tiles. Costs are one per tile; the heuristic is Manhattan distance.
-- Neighbour order and tie-breaking are fixed so the same world state produces the same
-- route. `blocked[key]` is true for tiles that may not be crossed. The optional
-- `allow[key]` set permits the start/goal tiles even if they are otherwise blocked.
local function search_route(blocked, start, goal, options)
  options = options or {}
  local max_nodes = options.max_nodes or MAX_ROUTE_NODES
  local max_length = options.max_length or MAX_ROUTE_LENGTH
  local allow = options.allow or {}
  local function passable(tile)
    local key = tile_key(tile)
    if allow[key] then return true end
    return not blocked[key]
  end
  if not passable(start) then return nil, "route_start_blocked" end
  if not passable(goal) then return nil, "route_goal_blocked" end
  if start.x == goal.x and start.y == goal.y then
    return {copy_tile(start)}, nil
  end
  local start_key, goal_key = tile_key(start), tile_key(goal)
  local open = {start}
  local in_open = {[start_key] = true}
  local g = {[start_key] = 0}
  local f = {[start_key] = math.abs(start.x - goal.x) + math.abs(start.y - goal.y)}
  local parent = {}
  local closed = {}
  local visited = 0
  while #open > 0 do
    local best_index, best_tile, best_value = 1, open[1], nil
    for index, tile in ipairs(open) do
      local key = tile_key(tile)
      local value = f[key] or math.huge
      local current = best_value
      if current == nil or value < current
        or (value == current and (tile.x < best_tile.x
          or (tile.x == best_tile.x and tile.y < best_tile.y))) then
        best_index, best_tile, best_value = index, tile, value
      end
    end
    local current = table.remove(open, best_index)
    local current_key = tile_key(current)
    in_open[current_key] = nil
    if current_key == goal_key then
      local path = {}
      local cursor = current
      while cursor do
        table.insert(path, 1, copy_tile(cursor))
        cursor = parent[tile_key(cursor)]
      end
      return path, nil
    end
    closed[current_key] = true
    visited = visited + 1
    if visited > max_nodes then return nil, "route_search_budget_exceeded" end
    local current_g = g[current_key]
    for _, offset in ipairs(NEIGHBOURS) do
      local next_tile = {x = current.x + offset[1], y = current.y + offset[2]}
      local next_key = tile_key(next_tile)
      if not closed[next_key] and passable(next_tile) then
        local tentative = current_g + 1
        if tentative <= max_length and (g[next_key] == nil or tentative < g[next_key]) then
          parent[next_key] = current
          g[next_key] = tentative
          f[next_key] = tentative + math.abs(next_tile.x - goal.x)
            + math.abs(next_tile.y - goal.y)
          if not in_open[next_key] then
            open[#open + 1] = next_tile
            in_open[next_key] = true
          end
        end
      end
    end
  end
  return nil, "no_route"
end

local function route_directions(path)
  local directions = {}
  for index, tile in ipairs(path) do
    local next_tile = path[index + 1]
    if next_tile then
      directions[#directions + 1] = direction_between(tile, next_tile)
    elseif index > 1 then
      directions[#directions + 1] = direction_between(path[index - 1], tile)
    else
      directions[#directions + 1] = DIR.east
    end
  end
  return directions
end

local function route_fingerprint(item, path, directions)
  local parts = {tostring(item)}
  for index, tile in ipairs(path) do
    parts[#parts + 1] = tile.x .. ":" .. tile.y .. ":" .. tostring(directions[index])
  end
  return digest(table.concat(parts, "|"))
end

-- ---------------------------------------------------------------------------
-- World occupancy
-- ---------------------------------------------------------------------------

local function mark_rect(occupancy, bounds, reason, owner)
  local left = math.floor(bounds[1].x)
  local top = math.floor(bounds[1].y)
  local right = math.ceil(bounds[2].x) - 1
  local bottom = math.ceil(bounds[2].y) - 1
  for x = left, right do
    for y = top, bottom do
      local key = x .. "," .. y
      occupancy[key] = {reason = reason, owner = owner}
    end
  end
end

local function mark_point(occupancy, tile, reason, owner)
  occupancy[tile_key(tile)] = {reason = reason, owner = owner}
end

local function module_entity_tiles(module)
  local tiles = {}
  for _, entity in ipairs(module.entities or {}) do
    local prototype = prototypes.entity[entity.name]
    if prototype and prototype.collision_box then
      local box = prototype.collision_box
      local left = math.floor(entity.position.x + box.left_top.x)
      local top = math.floor(entity.position.y + box.left_top.y)
      local right = math.ceil(entity.position.x + box.right_bottom.x) - 1
      local bottom = math.ceil(entity.position.y + box.right_bottom.y) - 1
      for x = left, right do
        for y = top, bottom do tiles[#tiles + 1] = {x = x, y = y} end
      end
    end
  end
  return tiles
end

local function is_agent(entity, agent)
  return agent and entity.unit_number and entity.unit_number == agent.unit_number
end

local function is_own_ghost(entity, plan_id)
  if entity.type ~= "entity-ghost" then return false end
  local tags = entity.tags
  return tags and (tags.ae_logistics_plan_id == plan_id
    or tags.ae_plan_id == plan_id)
end

local function scan_world(surface, area, agent, plan_id, occupancy)
  local entities = surface.find_entities_filtered{area = area}
  local players = {}
  for _, entity in pairs(entities) do
    if entity.valid and not is_agent(entity, agent) then
      local kind = entity.type
      if kind == "resource" or kind == "item-entity" or kind == "corpse"
        or kind == "smoke" or kind == "fish" then
        -- These do not block ghost placement and are not route obstacles.
      elseif is_own_ghost(entity, plan_id) then
        -- This plan's own ghosts are reconciled separately.
      elseif kind == "character" then
        players[#players + 1] = entity
      else
        local box = entity.bounding_box
        mark_rect(occupancy, {{x = box.left_top.x, y = box.left_top.y},
          {x = box.right_bottom.x, y = box.right_bottom.y}},
          kind == "entity-ghost" and "foreign_ghost" or "entity", entity.name)
      end
    end
  end
  for _, player in ipairs(players) do
    local center = tile_of(player.position)
    local radius = collaboration.player_work_radius()
    for x = center.x - radius, center.x + radius do
      for y = center.y - radius, center.y + radius do
        occupancy[x .. "," .. y] = {reason = "player_work_area", owner = "player"}
      end
    end
  end
  return players
end

local function build_occupancy(s, layout_plan, plan_id)
  local agent = s.agent
  local surface = agent.surface
  local occupancy = {}
  for _, module in ipairs(layout_plan.modules or {}) do
    mark_rect(occupancy, module.bounds, "module", module.node_id)
    for _, reserved in ipairs(module.reserved or {}) do
      mark_rect(occupancy, reserved.area, "module_reserved", module.node_id)
    end
    for _, tile in ipairs(module_entity_tiles(module)) do
      mark_point(occupancy, tile, "module_entity", module.node_id)
    end
  end
  local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
  for _, module in ipairs(layout_plan.modules or {}) do
    left = math.min(left, module.bounds[1].x)
    top = math.min(top, module.bounds[1].y)
    right = math.max(right, module.bounds[2].x)
    bottom = math.max(bottom, module.bounds[2].y)
  end
  local margin = 28
  local area = {{x = left - margin, y = top - margin},
    {x = right + margin, y = bottom + margin}}
  local players = scan_world(surface, area, agent, plan_id, occupancy)
  return occupancy, area, players
end

local function module_by_node(plan, node_id)
  for _, module in ipairs(plan.modules or {}) do
    if module.node_id == node_id then return module end
  end
  return nil
end

local function find_port(module, port_id)
  for _, port in ipairs(module.ports or {}) do
    if port.id == port_id then return port end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Physical plan records
-- ---------------------------------------------------------------------------

local function entity_record(name, tile, direction, role, connection_id)
  return {
    name = name, role = role, connection_id = connection_id,
    tile = copy_tile(tile), position = tile_center(tile), direction = direction or 0,
    status = "planned", ghost_unit = nil, built_unit = nil,
  }
end

local function add_planned(occupancy, record)
  mark_point(occupancy, record.tile, "planned", record.role)
end

local function tile_has_foreign_entity(surface, tile, plan_id)
  local entities = surface.find_entities_filtered{
    area = {{tile.x, tile.y}, {tile.x + 1, tile.y + 1}},
  }
  for _, entity in pairs(entities) do
    if entity.valid and not is_own_ghost(entity, plan_id) then
      local kind = entity.type
      if kind ~= "resource" and kind ~= "item-entity" and kind ~= "corpse"
        and kind ~= "smoke" and kind ~= "fish" and not clearing.is_clearable(entity) then
        return true, entity
      end
    end
  end
  return false, nil
end

local function belt_record_list(path, directions, connection_id)
  local records = {}
  for index, tile in ipairs(path) do
    records[#records + 1] = entity_record(BELT, tile, directions[index], "belt", connection_id)
  end
  return records
end

local function find_furnace_node(layout_plan)
  for _, module in ipairs(layout_plan.modules or {}) do
    for _, entity in ipairs(module.entities or {}) do
      local prototype = prototypes.entity[entity.name]
      if prototype and prototype.type == "furnace" then return module end
    end
  end
  return nil
end

local function find_production_node(layout_plan)
  for _, module in ipairs(layout_plan.modules or {}) do
    for _, entity in ipairs(module.entities or {}) do
      local prototype = prototypes.entity[entity.name]
      if prototype and prototype.type == "assembling-machine" then return module end
    end
  end
  return nil
end

local function find_node_by_category(layout_plan, category)
  for _, module in ipairs(layout_plan.modules or {}) do
    if module.category == category then return module end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Fuel source discovery
-- ---------------------------------------------------------------------------

local function coal_chests(surface, area, reference)
  local search_area = {
    {x = area[1].x, y = area[1].y}, {x = area[2].x, y = area[2].y},
  }
  local chests = surface.find_entities_filtered{
    area = search_area, type = {"container", "logistic-container"},
  }
  local result = {}
  for _, chest in pairs(chests) do
    if chest.valid and chest.name ~= "infinity-chest" then
      local inventory = construction.find_chest_inventory(chest)
      if inventory and inventory.get_item_count{name = "coal", quality = "normal"} > 0 then
        result[#result + 1] = chest
      end
    end
  end
  table.sort(result, function(a, b)
    local da, db = distance(a.position, reference), distance(b.position, reference)
    if math.abs(da - db) > 1e-9 then return da < db end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return (a.unit_number or 0) < (b.unit_number or 0)
  end)
  return result
end

local function plan_fuel(s, layout_plan, occupancy, area)
  local furnace = find_furnace_node(layout_plan)
  if not furnace then return nil, "unsupported_chain" end
  local fuel_port = find_port(furnace, "fuel_input")
  if not fuel_port then return nil, "unsupported_chain" end
  local furnace_entity = furnace.entities[1]
  if not furnace_entity or prototypes.entity[furnace_entity.name].type ~= "furnace" then
    return nil, "unsupported_chain"
  end
  local fuel_x = math.floor(fuel_port.position.x)
  local furnace_top = math.floor(furnace.bounds[1].y)
  local fuel_inserter_tile = {x = fuel_x, y = furnace_top - 1}
  local pickup_tile = {x = fuel_x, y = furnace_top - 2}
  local reference = tile_center(pickup_tile)
  local chests = coal_chests(s.agent.surface, area, reference)
  if #chests == 0 then return nil, "missing_fuel_source" end
  local last_reason = "missing_fuel_source"
  for _, chest in ipairs(chests) do
    local chest_tile = tile_of(chest.position)
    -- The simplest legal fuel feed: the ordinary chest itself is at the inserter
    -- pickup tile, so the inserter moves coal directly.
    if same_tile(chest_tile, pickup_tile) then
      local inserter = entity_record(INSERTER, fuel_inserter_tile, DIR.north,
        "fuel_inserter", "fuel")
      add_planned(occupancy, inserter)
      return {
        status = "route_planned", item = "coal", source_chest_unit = chest.unit_number,
        source_chest_tile = chest_tile, direct = true,
        fuel_inserter = inserter, chest_inserter = nil,
        belts = {}, pickup_tile = pickup_tile,
        verification = false, failure_reason = nil,
      }
    end
    local sides = {{dx = 0, dy = 1}, {dx = 1, dy = 0},
      {dx = 0, dy = -1}, {dx = -1, dy = 0}}
    for _, side in ipairs(sides) do
      local inserter_tile = {x = chest_tile.x + side.dx, y = chest_tile.y + side.dy}
      local belt_start = {x = chest_tile.x + side.dx * 2, y = chest_tile.y + side.dy * 2}
      local start_free = not occupancy[tile_key(belt_start)]
      local inserter_free = not occupancy[tile_key(inserter_tile)]
      if start_free and inserter_free then
        local blocked_copy = {}
        for key, value in pairs(occupancy) do blocked_copy[key] = value end
        mark_point(blocked_copy, chest_tile, "fuel_source", "fuel")
        mark_point(blocked_copy, inserter_tile, "planned", "fuel_chest_inserter")
        mark_point(blocked_copy, fuel_inserter_tile, "planned", "fuel_inserter")
        local allowed = {[tile_key(belt_start)] = true, [tile_key(pickup_tile)] = true}
        local path, reason = search_route(blocked_copy, belt_start, pickup_tile,
          {allow = allowed})
        if path then
          local directions = route_directions(path)
          local pickup_direction = side.dx < 0 and DIR.east
            or (side.dx > 0 and DIR.west)
            or (side.dy < 0 and DIR.south) or DIR.north
          local chest_inserter = entity_record(INSERTER, inserter_tile, pickup_direction,
            "fuel_chest_inserter", "fuel")
          local fuel_inserter = entity_record(INSERTER, fuel_inserter_tile, DIR.north,
            "fuel_inserter", "fuel")
          local belts = belt_record_list(path, directions, "fuel")
          for _, belt in ipairs(belts) do add_planned(occupancy, belt) end
          add_planned(occupancy, chest_inserter)
          add_planned(occupancy, fuel_inserter)
          return {
            status = "route_planned", item = "coal",
            source_chest_unit = chest.unit_number, source_chest_tile = chest_tile,
            direct = false, fuel_inserter = fuel_inserter,
            chest_inserter = chest_inserter, belts = belts,
            route = {start = belt_start, goal = pickup_tile, path = path,
              directions = directions,
              fingerprint = route_fingerprint("coal", path, directions)},
            pickup_tile = pickup_tile, verification = false, failure_reason = nil,
          }
        else
          last_reason = reason or "blocked_fuel_route"
        end
      end
    end
  end
  return nil, last_reason
end

-- ---------------------------------------------------------------------------
-- Output chest
-- ---------------------------------------------------------------------------

local function plan_output(s, layout_plan, occupancy)
  local producer = find_production_node(layout_plan)
  if not producer then return nil, "unsupported_chain" end
  local output_port = find_port(producer, "gear_output")
  if not output_port then return nil, "unsupported_chain" end
  local row = math.floor(layout_plan.logistics.belt_row)
  local right = math.floor(producer.bounds[2].x)
  local inserter_tile = {x = right, y = row}
  local chest_tile = {x = right + 1, y = row}
  if occupancy[tile_key(inserter_tile)] or occupancy[tile_key(chest_tile)] then
    return nil, "blocked_output"
  end
  local inserter = entity_record(INSERTER, inserter_tile, DIR.west,
    "output_inserter", "output")
  local chest = entity_record(OUTPUT_CHEST, chest_tile, 0, "output_chest", "output")
  add_planned(occupancy, inserter)
  add_planned(occupancy, chest)
  return {
    status = "route_planned", item = output_port.item or "iron-gear-wheel",
    inserter = inserter, chest = chest, verification = false,
    initial_gear_count = nil,
  }
end

-- ---------------------------------------------------------------------------
-- Electric distribution
-- ---------------------------------------------------------------------------

local function powered_pole_flow(pole)
  if not pole or not pole.valid then return nil end
  local network = pole.electric_network
  if not network then return nil end
  local parent = network.parent_network
  if not parent or not parent.valid then return nil end
  local ok, flow = pcall(function() return parent.flow_last_tick end)
  return ok and flow or nil
end

local function network_has_producer(pole)
  local flow = powered_pole_flow(pole)
  if not flow then return false end
  return (flow.maximum_production or 0) > 0
    or (flow.accumulator_energy or 0) > 0
    or (flow.total_transfer or 0) > 0
    or (flow.primary_output or 0) > 0
    or (flow.secondary_output or 0) > 0
    or (flow.tertiary_output or 0) > 0
    or (flow.solar_output or 0) > 0
end

local function find_powered_poles(surface, area)
  local result = {}
  local search_area = {
    {x = area[1].x, y = area[1].y}, {x = area[2].x, y = area[2].y},
  }
  -- Flow fields are zero when a solar network has no current demand. A bounded scan for
  -- real producer prototypes on the same network keeps the detection honest without
  -- inventing generation or widening the search beyond the code-owned area.
  local producer_networks = {}
  local producers = surface.find_entities_filtered{
    area = search_area, type = {"solar-panel", "generator",
      "electric-energy-interface", "fusion-generator"},
  }
  for _, producer in pairs(producers) do
    if producer.valid and producer.electric_network_id then
      producer_networks[producer.electric_network_id] = true
    end
  end
  for _, pole in pairs(surface.find_entities_filtered{
    area = search_area, type = "electric-pole"}) do
    if pole.valid and (network_has_producer(pole)
      or producer_networks[pole.electric_network_id]) then
      result[#result + 1] = pole
    end
  end
  return result
end

local function recipe_available(force, name)
  local recipe = force.recipes and force.recipes[name]
  return recipe ~= nil and recipe.enabled == true
end

local function choose_pole_item(force)
  for _, name in ipairs(POLES) do
    if prototypes.entity[name] and recipe_available(force, name) then return name end
  end
  return nil
end

local function collision_rect(entity)
  local prototype = prototypes.entity[entity.name]
  local box = prototype and prototype.collision_box
  if not box then
    return {left = entity.position.x - 0.25, top = entity.position.y - 0.25,
      right = entity.position.x + 0.25, bottom = entity.position.y + 0.25}
  end
  return {
    left = entity.position.x + box.left_top.x, top = entity.position.y + box.left_top.y,
    right = entity.position.x + box.right_bottom.x,
    bottom = entity.position.y + box.right_bottom.y,
  }
end

local function rects_intersect(a, b)
  return a.left <= b.right and b.left <= a.right
    and a.top <= b.bottom and b.top <= a.bottom
end

local function supply_rect(pole, radius)
  return {
    left = pole.position.x - radius, top = pole.position.y - radius,
    right = pole.position.x + radius, bottom = pole.position.y + radius,
  }
end

local function covers(pole, radius, entity)
  return rects_intersect(supply_rect(pole, radius), collision_rect(entity))
end

local function power_requirement_points(layout_plan, physical)
  local requirements = {}
  for _, module in ipairs(layout_plan.modules or {}) do
    for _, entity in ipairs(module.entities or {}) do
      local prototype = prototypes.entity[entity.name]
      if prototype and (prototype.type == "mining-drill"
        or prototype.type == "assembling-machine") then
        requirements[#requirements + 1] = {
          name = entity.name, position = entity.position,
          kind = "machine", module = module.node_id,
        }
      end
    end
  end
  local function add_inserter(record)
    if record then
      requirements[#requirements + 1] = {
        name = record.name, position = record.position, kind = "inserter",
        module = record.role,
      }
    end
  end
  for _, connection in ipairs(physical.connections or {}) do
    add_inserter(connection.output_inserter)
    add_inserter(connection.input_inserter)
  end
  add_inserter(physical.output and physical.output.inserter)
  if physical.fuel then
    add_inserter(physical.fuel.fuel_inserter)
    add_inserter(physical.fuel.chest_inserter)
  end
  return requirements
end

local function pole_position(tile, name)
  local prototype = prototypes.entity[name]
  return {x = tile.x + 0.5, y = tile.y + 0.5, proto = prototype}
end

local function candidate_pole_tiles(area, occupancy, planned)
  local left = math.floor(area[1].x) - 2
  local top = math.floor(area[1].y) - 2
  local right = math.ceil(area[2].x) + 2
  local bottom = math.ceil(area[2].y) + 2
  local candidates = {}
  for x = left, right do
    for y = top, bottom do
      local tile = {x = x, y = y}
      local key = tile_key(tile)
      if not occupancy[key] and not (planned and planned[key]) and not (area.excluded and area.excluded[key]) then
        candidates[#candidates + 1] = tile
      end
    end
  end
  table.sort(candidates, function(a, b)
    local da = math.abs(a.x - area.center.x) + math.abs(a.y - area.center.y)
    local db = math.abs(b.x - area.center.x) + math.abs(b.y - area.center.y)
    if da ~= db then return da < db end
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)
  return candidates
end

local function select_covering_poles(area, occupancy, planned, requirements,
    pole_name, supply_radius)
  local candidates = candidate_pole_tiles(area, occupancy, planned)
  -- A pole's own tile must be free. Coverage sets are computed against the real
  -- collision boxes of the required machines and inserters.
  local selected, covered = {}, {}
  local function update_covered(pole)
    for index, requirement in ipairs(requirements) do
      if not covered[index] and covers(pole, supply_radius, requirement) then
        covered[index] = true
      end
    end
  end
  local remaining = #requirements
  while remaining > 0 do
    local best, best_count = nil, 0
    for _, tile in ipairs(candidates) do
      local key = tile_key(tile)
      if not occupancy[key] and not (planned and planned[key]) then
        local pole = {position = tile_center(tile)}
        local count = 0
        for index, requirement in ipairs(requirements) do
          if not covered[index] and covers(pole, supply_radius, requirement) then
            count = count + 1
          end
        end
        if count > best_count then
          best_count, best = count, tile
        elseif count == best_count and count > 0 and best
          and (tile.x < best.x or (tile.x == best.x and tile.y < best.y)) then
          best = tile
        end
      end
    end
    if not best then return nil, "unsupported_power_geometry" end
    local pole = {position = tile_center(best)}
    selected[#selected + 1] = best
    update_covered(pole)
    planned[tile_key(best)] = true
    local count = 0
    for index = 1, #requirements do if covered[index] then count = count + 1 end end
    if count == remaining + 0 then
      -- Recompute remaining from the covered table.
    end
    remaining = 0
    for index = 1, #requirements do if not covered[index] then remaining = remaining + 1 end end
  end
  return selected, nil
end

local function pole_wire_reach(name)
  local prototype = prototypes.entity[name]
  local ok, value = pcall(function() return prototype.get_max_wire_distance("normal") end)
  return ok and value or 7.5
end

local function pole_supply_radius(name)
  local prototype = prototypes.entity[name]
  local ok, value = pcall(function() return prototype.get_supply_area_distance("normal") end)
  return ok and value or 2.5
end

local function connector_offsets(reach)
  local offsets = {}
  for dx = -8, 8 do
    for dy = -8, 8 do
      local dist = math.sqrt(dx * dx + dy * dy)
      if dist >= 2 and dist <= reach - 0.25 then offsets[#offsets + 1] = {dx, dy, dist} end
    end
  end
  table.sort(offsets, function(a, b)
    if a[3] ~= b[3] then return a[3] < b[3] end
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  return offsets
end

-- Connect an existing network pole to one of the planned cell poles using a bounded
-- set of legal copper-wire-reach steps. Intermediate poles are ordinary construction
-- ghosts; no wire reach check is ever disabled.
local function plan_pole_chain(area, occupancy, planned, start_tile, goal_tile,
    pole_name, reach)
  if distance(tile_center(start_tile), tile_center(goal_tile)) <= reach - 0.25 then
    return {}
  end
  local offsets = connector_offsets(reach)
  local blocked = {}
  for key in pairs(occupancy) do blocked[key] = true end
  for key in pairs(planned) do blocked[key] = true end
  local allow = {[tile_key(start_tile)] = true, [tile_key(goal_tile)] = true}
  local function passable(tile)
    local key = tile_key(tile)
    if allow[key] then return true end
    return not blocked[key]
  end
  local open = {start_tile}
  local g = {[tile_key(start_tile)] = 0}
  local f = {[tile_key(start_tile)] = distance(tile_center(start_tile), tile_center(goal_tile))}
  local parent = {}
  local closed = {}
  local visited = 0
  while #open > 0 do
    local best_index, best_tile, best_value = 1, open[1], nil
    for index, tile in ipairs(open) do
      local key = tile_key(tile)
      local value = f[key] or math.huge
      if best_value == nil or value < best_value
        or (value == best_value and (tile.x < best_tile.x
          or (tile.x == best_tile.x and tile.y < best_tile.y))) then
        best_index, best_tile, best_value = index, tile, value
      end
    end
    local current = table.remove(open, best_index)
    local current_key = tile_key(current)
    if current_key == tile_key(goal_tile) then
      local intermediate = {}
      local cursor = parent[current_key]
      while cursor do
        if not same_tile(cursor, start_tile) then
          table.insert(intermediate, 1, copy_tile(cursor))
        end
        cursor = parent[tile_key(cursor)]
      end
      return intermediate
    end
    closed[current_key] = true
    visited = visited + 1
    if visited > MAX_POLE_NODES then return nil, "pole_route_budget" end
    for _, offset in ipairs(offsets) do
      local next_tile = {x = current.x + offset[1], y = current.y + offset[2]}
      local next_key = tile_key(next_tile)
      if not closed[next_key] and passable(next_tile) then
        local tentative = g[current_key] + offset[3]
        if g[next_key] == nil or tentative < g[next_key] - 1e-9 then
          parent[next_key] = current
          g[next_key] = tentative
          f[next_key] = tentative + distance(tile_center(next_tile), tile_center(goal_tile))
          local found = false
          for _, queued in ipairs(open) do
            if tile_key(queued) == next_key then found = true break end
          end
          if not found then open[#open + 1] = next_tile end
        end
      end
    end
  end
  return nil, "blocked_power_route"
end

local function plan_power(s, layout_plan, physical, occupancy, area)
  local force = s.agent.force
  local pole_name = choose_pole_item(force)
  if not pole_name then return nil, "missing_power_source" end
  local supply_radius = pole_supply_radius(pole_name)
  local reach = pole_wire_reach(pole_name)
  local powered = find_powered_poles(s.agent.surface, area)
  if #powered == 0 then return nil, "missing_power_source" end
  local reference = {x = area.center.x, y = area.center.y}
  table.sort(powered, function(a, b)
    local da, db = distance(a.position, reference), distance(b.position, reference)
    if math.abs(da - db) > 1e-9 then return da < db end
    return (a.unit_number or 0) < (b.unit_number or 0)
  end)
  local existing = powered[1]
  local requirements = power_requirement_points(layout_plan, physical)
  local planned = {}
  -- Planned entity tiles are already in occupancy; poles may not overwrite them.
  local selected, reason = select_covering_poles(area, occupancy, planned, requirements,
    pole_name, supply_radius)
  if not selected then return nil, reason end
  local records = {}
  for _, tile in ipairs(selected) do
    records[#records + 1] = entity_record(pole_name, tile, 0, "pole", "power")
  end
  -- Connect the cell network to the existing powered network.
  local start_tile = tile_of(existing.position)
  local existing_reach = 0
  local ok_reach, value = pcall(function()
    return existing.prototype.get_max_wire_distance("normal")
  end)
  if ok_reach and value then existing_reach = value end
  local existing_reach_effective = math.min(reach,
    existing_reach > 0 and existing_reach or reach)
  -- Build one connected pole component. Every selected coverage pole is linked either
  -- directly (within wire reach) or through legal intermediate pole ghosts. Poles never
  -- connect beyond their live maximum wire distance.
  local linked = {{position = existing.position, tile = start_tile,
    reach = existing_reach_effective}}
  local pending = {}
  for _, record in ipairs(records) do
    pending[#pending + 1] = {record = record,
      distance = distance(record.position, existing.position)}
  end
  table.sort(pending, function(a, b)
    if math.abs(a.distance - b.distance) > 1e-9 then return a.distance < b.distance end
    return a.record.tile.x < b.record.tile.x
      or (a.record.tile.x == b.record.tile.x and a.record.tile.y < b.record.tile.y)
  end)
  for _, item in ipairs(pending) do
    local record = item.record
    local nearest, nearest_distance = nil, nil
    for _, node in ipairs(linked) do
      local d = distance(record.position, node.position)
      if not nearest_distance or d < nearest_distance then
        nearest, nearest_distance = node, d
      end
    end
    local effective = math.min(reach, nearest and nearest.reach or reach)
    if nearest_distance > effective - 0.25 then
      local connectors, chain_reason = plan_pole_chain(area, occupancy, planned,
        nearest.tile, record.tile, pole_name, effective)
      if not connectors then return nil, chain_reason or "blocked_power_route" end
      local previous = nearest
      for _, tile in ipairs(connectors) do
        local connector = entity_record(pole_name, tile, 0, "pole", "power")
        records[#records + 1] = connector
        planned[tile_key(tile)] = true
        linked[#linked + 1] = {position = connector.position, tile = connector.tile,
          reach = reach}
        previous = linked[#linked]
      end
      linked[#linked + 1] = {position = record.position, tile = record.tile, reach = reach}
    else
      linked[#linked + 1] = {position = record.position, tile = record.tile, reach = reach}
    end
  end
  for _, record in ipairs(records) do add_planned(occupancy, record) end
  return {
    status = "route_planned", pole_name = pole_name,
    existing_pole_unit = existing.unit_number,
    existing_pole_tile = start_tile,
    existing_network_id = existing.electric_network_id,
    poles = records,
    requirements = requirements,
    verification = false, failure_reason = nil,
  }
end

-- ---------------------------------------------------------------------------
-- Public physical planning
-- ---------------------------------------------------------------------------

local function layout_plan_by_id(s, plan_id)
  return s.layout_plans and s.layout_plans.by_id and s.layout_plans.by_id[plan_id] or nil
end

local function store_physical(s, physical)
  s.logistics = s.logistics or {by_id = {}, order = {}, next_plan_number = 0}
  s.logistics.by_id[physical.id] = physical
  local found = false
  for _, existing in ipairs(s.logistics.order) do
    if existing == physical.id then found = true break end
  end
  if not found then s.logistics.order[#s.logistics.order + 1] = physical.id end
  while #s.logistics.order > 32 do
    local oldest = table.remove(s.logistics.order, 1)
    s.logistics.by_id[oldest] = nil
  end
  return physical
end

function M.plan(s, p)
  local agent = s.agent
  assert(agent and agent.valid, "Agent is not alive")
  assert(not (s.safety and s.safety.active), "Safety controller is active")
  assert(type(p.layout_plan_id) == "string" and p.layout_plan_id ~= "",
    "layout_plan_id is required")
  local layout_plan = layout_plan_by_id(s, p.layout_plan_id)
  if not layout_plan then return {ok = false, status = "unknown_plan"} end
  if not layout_plan.materializable or not layout_plan.logistics
    or layout_plan.logistics.mode ~= "linear_chain" then
    return {ok = false, status = "unsupported_plan",
      reason = "plan_is_not_a_materializable_logistics_chain"}
  end
  local plan_id = "logi_" .. digest(layout_plan.id .. "|" .. tostring(layout_plan.fingerprint))
    :sub(1, 16)
  local existing = s.logistics and s.logistics.by_id and s.logistics.by_id[plan_id]
  -- Reuse only a physical plan that can still be built or has already been built. A plan
  -- that failed planning (missing power/fuel or a blocked route) must be recomputed after
  -- the player supplies the missing prerequisite or removes the obstruction.
  local reusable = existing and (existing.status == "planned"
    or existing.status == "route_placed" or existing.status == "connected"
    or existing.status == "operational" or existing.status == "built")
  if reusable then
    return {ok = true, status = existing.status, physical = existing, reused = true}
  end
  local occupancy, area, players = build_occupancy(s, layout_plan, plan_id)
  area.center = {x = (area[1].x + area[2].x) / 2, y = (area[1].y + area[2].y) / 2}
  local physical = {
    schema_version = M.SCHEMA_VERSION, id = plan_id,
    layout_plan_id = layout_plan.id, goal_item = layout_plan.goal_item,
    surface_index = agent.surface.index, surface_name = agent.surface.name,
    created_tick = game.tick, status = "planned",
    belt_row = layout_plan.logistics.belt_row,
    connections = {}, entities = {}, required_items = {},
    output = nil, fuel = nil, power = nil,
    observation = {gauge_initial = nil, ore_seen = false, coal_seen = false,
      plate_seen = false, gear_produced = false, gear_recipe_ok = false,
      power_ok = false, belts_connected = false, started_tick = nil},
    blocked = nil, unsupported = nil,
  }
  local player_block = players and #players > 0
  if player_block then
    physical.status = "blocked"
    physical.blocked = "player_in_work_area"
    return {ok = false, status = "blocked", reason = "player_in_work_area",
      physical = store_physical(s, physical)}
  end
  for _, edge in ipairs(layout_plan.edges or {}) do
    if edge.kind == "item" and edge.status == "route_required" then
      local producer = module_by_node(layout_plan, edge.from)
      local consumer = module_by_node(layout_plan, edge.to)
      if not producer or not consumer then
        return {ok = false, status = "unsupported", reason = "module_unplaced"}
      end
      local from_port = find_port(producer, edge.from_port)
      local to_port = find_port(consumer, edge.to_port)
      if not from_port or not to_port then
        return {ok = false, status = "unsupported", reason = "declared_port_not_found"}
      end
      if from_port.direction ~= DIR.east or to_port.direction ~= DIR.east then
        return {ok = false, status = "unsupported", reason = "unsupported_flow_direction"}
      end
      local producer_entity = producer.entities[1]
      local consumer_entity = consumer.entities[1]
      local producer_proto = prototypes.entity[producer_entity.name]
      local consumer_proto = prototypes.entity[consumer_entity.name]
      local direct_output = producer_proto.type == "mining-drill"
      local input_inserter = consumer_proto.type == "furnace"
        or consumer_proto.type == "assembling-machine"
      local row = math.floor(layout_plan.logistics.belt_row)
      local source_tile = {x = math.floor(producer.bounds[2].x) + (direct_output and 0 or 1), y = row}
      local goal_tile = {x = math.floor(consumer.bounds[1].x) - (input_inserter and 2 or 1), y = row}
      local connection = {
        id = tostring(edge.item) .. ":" .. tostring(edge.from) .. "->" .. tostring(edge.to),
        item = edge.item, from_node = edge.from, from_port = edge.from_port,
        to_node = edge.to, to_port = edge.to_port,
        source_tile = source_tile, destination_tile = goal_tile,
        status = "not_routed", route = nil, belts = {},
        output_inserter = nil, input_inserter = nil,
        verification = false, failure_reason = nil,
      }
      local blocked_copy = {}
      for key, value in pairs(occupancy) do blocked_copy[key] = value end
      if not direct_output then
        local inserter_tile = {x = math.floor(producer.bounds[2].x), y = row}
        if occupancy[tile_key(inserter_tile)] then
          connection.status, connection.failure_reason = "blocked", "output_inserter_blocked"
        else
          connection.output_inserter = entity_record(INSERTER, inserter_tile, DIR.west,
            "output_inserter", connection.id)
          mark_point(blocked_copy, inserter_tile, "planned", "output_inserter")
        end
      end
      if input_inserter then
        local inserter_tile = {x = math.floor(consumer.bounds[1].x) - 1, y = row}
        if occupancy[tile_key(inserter_tile)] then
          connection.status, connection.failure_reason = "blocked", "input_inserter_blocked"
        else
          connection.input_inserter = entity_record(INSERTER, inserter_tile, DIR.west,
            "input_inserter", connection.id)
          mark_point(blocked_copy, inserter_tile, "planned", "input_inserter")
        end
      end
      local source_occupied = occupancy[tile_key(source_tile)]
      local goal_occupied = occupancy[tile_key(goal_tile)]
      if source_occupied or goal_occupied then
        connection.status, connection.failure_reason = "blocked", "route_endpoint_occupied"
      elseif not connection.status or connection.status == "not_routed" then
        local allowed = {[tile_key(source_tile)] = true, [tile_key(goal_tile)] = true}
        local path, route_reason = search_route(blocked_copy, source_tile, goal_tile,
          {allow = allowed})
        if path then
          local directions = route_directions(path)
          connection.route = {start = source_tile, goal = goal_tile, path = path,
            directions = directions,
            fingerprint = route_fingerprint(edge.item, path, directions)}
          connection.belts = belt_record_list(path, directions, connection.id)
          connection.status = "route_planned"
          for _, belt in ipairs(connection.belts) do add_planned(occupancy, belt) end
          if connection.output_inserter then add_planned(occupancy, connection.output_inserter) end
          if connection.input_inserter then add_planned(occupancy, connection.input_inserter) end
          physical.entities[#physical.entities + 1] = connection.output_inserter
          physical.entities[#physical.entities + 1] = connection.input_inserter
          for _, belt in ipairs(connection.belts) do physical.entities[#physical.entities + 1] = belt end
        else
          connection.status, connection.failure_reason = "blocked", route_reason or "no_route"
        end
      end
      physical.connections[#physical.connections + 1] = connection
    end
  end
  local output, output_reason = plan_output(s, layout_plan, occupancy)
  if not output then
    physical.status = "blocked"
    physical.blocked = output_reason
    return {ok = false, status = "blocked", reason = output_reason,
      physical = store_physical(s, physical)}
  end
  physical.output = output
  physical.entities[#physical.entities + 1] = output.inserter
  physical.entities[#physical.entities + 1] = output.chest
  local fuel, fuel_reason = plan_fuel(s, layout_plan, occupancy, area)
  if not fuel then
    physical.status = fuel_reason == "missing_fuel_source" and "missing_fuel_source"
      or "blocked"
    return {ok = false, status = physical.status, reason = fuel_reason,
      physical = store_physical(s, physical)}
  end
  physical.fuel = fuel
  physical.entities[#physical.entities + 1] = fuel.fuel_inserter
  if fuel.chest_inserter then physical.entities[#physical.entities + 1] = fuel.chest_inserter end
  for _, belt in ipairs(fuel.belts) do physical.entities[#physical.entities + 1] = belt end
  local power, power_reason = plan_power(s, layout_plan, physical, occupancy, area)
  if not power then
    physical.status = power_reason == "missing_power_source" and "missing_power_source"
      or "blocked"
    physical.blocked = power_reason
    local missing_by_key = {}
    for _, record in ipairs(physical.entities) do
      if record then
        local prototype = prototypes.entity[record.name]
        for _, item in pairs(prototype and prototype.items_to_place_this or {}) do
          local key = item.name .. ":normal"
          missing_by_key[key] = missing_by_key[key]
            or {name = item.name, count = 0, quality = "normal"}
          missing_by_key[key].count = missing_by_key[key].count + item.count
        end
      end
    end
    for _, key in ipairs(sorted_pairs_keys(missing_by_key)) do
      physical.required_items[#physical.required_items + 1] = missing_by_key[key]
    end
    return {ok = false, status = physical.status, reason = power_reason,
      physical = store_physical(s, physical)}
  end
  physical.power = power
  for _, pole in ipairs(power.poles) do physical.entities[#physical.entities + 1] = pole end
  local blocked_connections = 0
  for _, connection in ipairs(physical.connections) do
    if connection.status == "blocked" then blocked_connections = blocked_connections + 1 end
  end
  if blocked_connections > 0 then
    physical.status = "blocked"
    physical.blocked = "blocked_route"
  else
    physical.status = "planned"
  end
  -- Aggregate the live prototype cost of every logistics ghost. Module ghosts are
  -- costed by the layout planner's apply summary; this list is the extra logistics cost.
  local by_key = {}
  for _, record in ipairs(physical.entities) do
    if record then
      local prototype = prototypes.entity[record.name]
      for _, item in pairs(prototype and prototype.items_to_place_this or {}) do
        local key = item.name .. ":" .. "normal"
        by_key[key] = by_key[key] or {name = item.name, count = 0, quality = "normal"}
        by_key[key].count = by_key[key].count + item.count
      end
    end
  end
  for _, key in ipairs(sorted_pairs_keys(by_key)) do
    physical.required_items[#physical.required_items + 1] = by_key[key]
  end
  physical.observation.gauge_initial = M.count_output_gears(s, physical)
  store_physical(s, physical)
  return {ok = physical.status == "planned", status = physical.status,
    physical = physical, reason = physical.blocked}
end

-- ---------------------------------------------------------------------------
-- Ghost placement
-- ---------------------------------------------------------------------------

local function find_live_at(surface, tile, plan_id)
  local entities = surface.find_entities_filtered{
    area = {{tile.x, tile.y}, {tile.x + 1, tile.y + 1}},
  }
  for _, entity in pairs(entities) do
    if entity.valid and is_own_ghost(entity, plan_id) then return entity end
  end
  return nil
end

local function find_real_at(surface, tile, name)
  local entities = surface.find_entities_filtered{
    area = {{tile.x, tile.y}, {tile.x + 1, tile.y + 1}}, name = name,
  }
  for _, entity in pairs(entities) do
    if entity.valid and entity.type ~= "entity-ghost" then return entity end
  end
  return nil
end

local function create_logistics_ghost(s, physical, record)
  local surface = s.agent.surface
  local tags = {
    ae_logistics_plan_id = physical.id,
    ae_logistics_role = record.role,
  }
  if record.connection_id then tags.ae_logistics_connection = record.connection_id end
  if record.name == "assembling-machine-1" then tags.ae_recipe = "iron-gear-wheel" end
  local ok, ghost = pcall(function()
    return surface.create_entity{
      name = "entity-ghost", inner_name = record.name, position = record.position,
      direction = record.direction or 0, force = s.agent.force,
      quality = "normal", tags = tags,
    }
  end)
  if not ok or not ghost or not ghost.valid then
    return nil, tostring(ghost)
  end
  record.ghost_unit = ghost.unit_number
  record.status = "route_placed"
  return ghost, nil
end

function M.place_ghosts(s, p)
  local physical = s.logistics and s.logistics.by_id and s.logistics.by_id[p.logistics_plan_id]
  if not physical then return {ok = false, status = "unknown_plan"} end
  if physical.status ~= "planned" and physical.status ~= "route_placed" then
    return {ok = false, status = physical.status}
  end
  local surface = s.agent.surface
  local created, already, blocked = 0, 0, {}
  for _, record in ipairs(physical.entities) do
    if record then
      local tile = record.tile
      local existing_ghost = find_live_at(surface, tile, physical.id)
      if existing_ghost and existing_ghost.ghost_name == record.name then
        record.ghost_unit = existing_ghost.unit_number
        record.status = "route_placed"
        already = already + 1
      else
        local real = find_real_at(surface, tile, record.name)
        if real then
          record.built_unit = real.unit_number
          record.status = "connected"
        else
          local foreign, entity = tile_has_foreign_entity(surface, tile, physical.id)
          if foreign then
            blocked[#blocked + 1] = {
              role = record.role, reason = "tile_occupied",
              occupant = entity and entity.name or "unknown",
            }
          else
            local ghost, reason = create_logistics_ghost(s, physical, record)
            if ghost then created = created + 1
            else blocked[#blocked + 1] = {role = record.role,
              reason = reason or "ghost_create_failed"} end
          end
        end
      end
    end
  end
  if #blocked > 0 then
    physical.status = "blocked"
    physical.blocked = "blocked_route"
    physical.blocked_entities = blocked
    return {ok = false, status = "blocked", blocked = blocked, physical = physical}
  end
  physical.status = "route_placed"
  physical.ghosts_placed_tick = game.tick
  return {ok = true, status = "route_placed", created = created,
    already = already, physical = physical}
end

-- ---------------------------------------------------------------------------
-- Read-only verification
-- ---------------------------------------------------------------------------

local function find_real(surface, tile, name)
  return find_real_at(surface, tile, name)
end

local function belt_neighbours_connected(belt, expected_next)
  local neighbours = belt.belt_neighbours
  if not neighbours then return false end
  for _, position in pairs(neighbours.outputs or {}) do
    if math.abs(position.x - (expected_next.x + 0.5)) < 0.1
      and math.abs(position.y - (expected_next.y + 0.5)) < 0.1 then return true end
  end
  return false
end

function M.verify_entities(s, physical)
  local surface = game.surfaces[physical.surface_index]
  if not surface then return {ok = false, reason = "surface_missing"} end
  local missing, wrong = {}, {}
  for _, record in ipairs(physical.entities) do
    if record then
      local entity = find_real(surface, record.tile, record.name)
      if not entity then
        missing[#missing + 1] = {role = record.role, name = record.name}
      elseif record.direction and entity.direction ~= record.direction
        and entity.type ~= "container" then
        wrong[#wrong + 1] = {role = record.role, name = record.name,
          expected = record.direction, actual = entity.direction}
      else
        record.built_unit = entity.unit_number
      end
    end
  end
  local connection_details = {}
  for _, connection in ipairs(physical.connections) do
    local ok = #missing == 0
    if ok and connection.route then
      local path = connection.route.path
      for index = 1, #path - 1 do
        local belt = find_real(surface, path[index], BELT)
        if not belt or not belt_neighbours_connected(belt, path[index + 1]) then
          ok = false
          break
        end
      end
    end
    connection.verification = ok
    if ok then
      connection.status = "connected"
    elseif connection.status == "route_planned" or connection.status == "route_placed" then
      connection.status = "blocked"
      connection.failure_reason = "belt_connection_not_confirmed"
    end
    connection_details[#connection_details + 1] = {
      id = connection.id, status = connection.status,
      belt_count = #connection.belts,
    }
  end
  return {
    ok = #missing == 0 and #wrong == 0,
    missing = missing, wrong_direction = wrong,
    connections = connection_details,
  }
end

local function entity_powered(entity)
  if not entity or not entity.valid then return false end
  local ok, connected = pcall(function()
    return entity.is_connected_to_electric_network()
  end)
  return ok and connected == true and entity.electric_network_id ~= nil
end

local function network_id_in_physical(surface, physical)
  local power = physical.power
  if not power then return nil end
  for _, record in ipairs(power.poles) do
    local pole = find_real(surface, record.tile, record.name)
    if pole and pole.electric_network_id then return pole.electric_network_id end
  end
  return nil
end

function M.verify_power(s, physical)
  local surface = game.surfaces[physical.surface_index]
  local power = physical.power
  if not power then return {ok = false, reason = "missing_power_source"} end
  local network_id = network_id_in_physical(surface, physical)
  local poles = {}
  for _, record in ipairs(power.poles) do
    local pole = find_real(surface, record.tile, record.name)
    poles[#poles + 1] = {
      role = "pole", exists = pole ~= nil,
      network_id = pole and pole.electric_network_id or nil,
      powered = entity_powered(pole),
    }
  end
  local required = {}
  local all_powered = true
  for _, requirement in ipairs(power.requirements) do
    local tile = tile_of(requirement.position)
    local entity = find_real(surface, tile, requirement.name)
    if not entity then
      -- Inserter/machine positions may be on tile boundaries for 2x2 machines.
      entity = find_real(surface, {x = math.floor(requirement.position.x),
        y = math.floor(requirement.position.y)}, requirement.name)
    end
    local powered = entity_powered(entity)
    if not powered then all_powered = false end
    required[#required + 1] = {
      name = requirement.name, kind = requirement.kind,
      exists = entity ~= nil, powered = powered,
      network_id = entity and entity.electric_network_id or nil,
    }
  end
  local ok = network_id ~= nil and #poles > 0 and all_powered
  power.verification = ok
  return {ok = ok, network_id = network_id, poles = poles, required = required,
    existing_network_id = power.existing_network_id}
end

local function inventory_contents(entity, inventory_id)
  if not entity or not entity.valid then return {} end
  local inventory = entity.get_inventory(inventory_id)
  return inventory and inventory.get_contents() or {}
end

local function item_count(contents, name)
  for _, item in pairs(contents or {}) do
    if item.name == name then return item.count end
  end
  return 0
end

local function find_machine(surface, module)
  if not module then return nil end
  for _, entity in ipairs(module.entities or {}) do
    local tile = tile_of(entity.position)
    local found = find_real(surface, tile, entity.name)
    if found then return found end
  end
  return nil
end

function M.count_output_gears(s, physical)
  local surface = game.surfaces[physical.surface_index]
  if not physical.output then return 0 end
  local chest = find_real(surface, physical.output.chest.tile, OUTPUT_CHEST)
  if not chest then return 0 end
  return item_count(inventory_contents(chest, defines.inventory.chest), "iron-gear-wheel")
end

function M.observe(s, physical)
  local surface = game.surfaces[physical.surface_index]
  local layout = layout_plan_by_id(s, physical.layout_plan_id)
  if not layout then return nil end
  local mining = find_node_by_category(layout, "mining")
  local furnace_module = find_furnace_node(layout)
  local production = find_production_node(layout)
  local furnace = find_machine(surface, furnace_module)
  local assembler = find_machine(surface, production)
  local drill = find_machine(surface, mining)
  local observation = physical.observation
  observation.started_tick = observation.started_tick or game.tick
  local output_gears = M.count_output_gears(s, physical)
  observation.output_gears = output_gears
  if observation.gauge_initial == nil then observation.gauge_initial = output_gears end
  if output_gears > (observation.gauge_initial or 0) then observation.gear_produced = true end
  local ore = furnace and item_count(
    inventory_contents(furnace, defines.inventory.crafter_input), "iron-ore") or 0
  local plate = assembler and item_count(
    inventory_contents(assembler, defines.inventory.crafter_input), "iron-plate") or 0
  local gear = assembler and item_count(
    inventory_contents(assembler, defines.inventory.crafter_output), "iron-gear-wheel") or 0
  if ore > 0 then observation.ore_seen = true end
  if plate > 0 or (assembler and gear >= 0 and observation.gear_produced) then
    observation.plate_seen = true
  end
  if gear > 0 then observation.plate_seen = true end
  if assembler then
    local ok, recipe = pcall(function() return assembler.get_recipe() end)
    observation.gear_recipe_ok = ok and recipe and recipe.name == "iron-gear-wheel"
  end
  local coal = 0
  if physical.fuel and physical.fuel.source_chest_unit then
    local chests = surface.find_entities_filtered{type = {"container", "logistic-container"}}
    for _, chest in pairs(chests) do
      if chest.unit_number == physical.fuel.source_chest_unit then
        coal = item_count(inventory_contents(chest, defines.inventory.chest), "coal")
        break
      end
    end
  end
  local burning = 0
  if furnace and furnace.burner then
    local ok, value = pcall(function() return furnace.burner.remaining_burning_fuel end)
    burning = ok and value or 0
  end
  observation.coal_remaining = coal
  observation.furnace_fuel_remaining = burning
  observation.furnace_ore = ore
  observation.assembler_plate = plate
  observation.assembler_gear = gear
  if coal > 0 or burning > 0 then observation.coal_seen = true end
  if drill then
    observation.drill_status = drill.status
    observation.drill_energy = drill.energy
  end
  if furnace then observation.furnace_status = furnace.status end
  if assembler then observation.assembler_status = assembler.status end
  return observation
end

function M.verify(s, p)
  local physical = s.logistics and s.logistics.by_id and s.logistics.by_id[p.logistics_plan_id]
  if not physical then return {ok = false, status = "unknown_plan"} end
  local entities = M.verify_entities(s, physical)
  local power = M.verify_power(s, physical)
  local observation = M.observe(s, physical)
  local fuel_ok = observation.coal_seen == true and observation.furnace_fuel_remaining > 0
  local produced = observation.gear_produced == true
  local ok = entities.ok and power.ok and fuel_ok and produced
  local status = "connected"
  if not entities.ok then status = "blocked"
  elseif not power.ok then status = "missing_power_source"
  elseif not fuel_ok then status = "missing_fuel_source"
  elseif not produced then status = "connected"
  else status = "operational" end
  physical.status = status
  physical.verification = {
    entities = entities, power = power, fuel = fuel_ok,
    produced = produced, observation = observation, tick = game.tick,
  }
  return {
    ok = ok, status = status, entities = entities.ok, power = power.ok,
    fuel = fuel_ok, produced = produced,
    observation = observation,
    connection_statuses = entities.connections,
    missing_power = power.ok and nil or power.required,
  }
end

function M.status(s, plan_id)
  local physical = s.logistics and s.logistics.by_id and s.logistics.by_id[plan_id]
  if not physical then return {ok = false, status = "unknown_plan"} end
  return {ok = true, physical = physical}
end

function M.plans(s)
  local result = {}
  for _, plan_id in ipairs(s.logistics and s.logistics.order or {}) do
    local physical = s.logistics.by_id[plan_id]
    if physical then
      result[#result + 1] = {
        id = physical.id, layout_plan_id = physical.layout_plan_id,
        goal_item = physical.goal_item, status = physical.status,
        created_tick = physical.created_tick,
      }
    end
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

function M.public_summary(physical)
  if not physical then return {ok = false, status = "unknown_plan"} end
  local connection_counts = {}
  for _, connection in ipairs(physical.connections or {}) do
    connection_counts[connection.status] = (connection_counts[connection.status] or 0) + 1
  end
  local entities_total = #(physical.entities or {})
  local ghost_count, built_count = 0, 0
  for _, record in ipairs(physical.entities or {}) do
    if record then
      if record.ghost_unit then ghost_count = ghost_count + 1 end
      if record.built_unit then built_count = built_count + 1 end
    end
  end
  return {
    ok = physical.status == "operational",
    logistics_plan_id = physical.id, layout_plan_id = physical.layout_plan_id,
    goal_item = physical.goal_item, status = physical.status,
    connections = connection_counts,
    connection_total = #(physical.connections or {}),
    entities_total = entities_total, ghosts_placed = ghost_count,
    entities_built = built_count,
    fuel_status = physical.fuel and physical.fuel.status or "missing_fuel_source",
    power_status = physical.power and physical.power.status or "missing_power_source",
    produced = physical.observation and physical.observation.gear_produced == true,
    required_items = physical.required_items,
    reason = physical.blocked,
  }
end

return M
