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
local transport = require("lib.transport")

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
    add_inserter(connection.fuel_inserter)
    add_inserter(connection.chest_inserter)
  end
  add_inserter(physical.output and physical.output.inserter)
  if physical.fuel then
    add_inserter(physical.fuel.fuel_inserter)
    add_inserter(physical.fuel.chest_inserter)
    for _, inserter in ipairs(physical.fuel.fuel_inserters or {}) do add_inserter(inserter) end
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

-- ---------------------------------------------------------------------------
-- Stage-7 multi-consumer expansion planning
-- ---------------------------------------------------------------------------

local function is_multi_consumer_plan(layout_plan)
  return layout_plan and layout_plan.logistics
    and layout_plan.logistics.mode == "multi_consumer"
    and layout_plan.logistics.cell ~= nil
end

local function tile_equals(a, b)
  return a and b and a.x == b.x and a.y == b.y
end

local function add_expansion_entity(s, physical, occupancy, plan_id, record)
  local key = tile_key(record.tile)
  local existing = nil
  for _, candidate in ipairs(physical.entities) do
    if candidate and candidate.name == record.name and tile_equals(candidate.tile, record.tile) then
      existing = candidate
      break
    end
  end
  if existing then return existing, nil end
  if occupancy[key] then
    return nil, "tile_occupied:" .. tostring(occupancy[key].reason or "unknown")
  end
  local foreign, entity = tile_has_foreign_entity(s.agent.surface, record.tile, plan_id)
  if foreign then
    return nil, "foreign_entity:" .. tostring(entity and entity.name or "unknown")
  end
  physical.entities[#physical.entities + 1] = record
  mark_point(occupancy, record.tile, "planned", record.role)
  return record, nil
end

local function add_expansion_splitter(s, physical, occupancy, plan_id, junction_id,
    meta, kind, used_inputs, used_outputs)
  local record = transport.splitter_record("splitter", meta.anchor, meta.direction,
    kind == "merge" and "merge_splitter" or "split_splitter", junction_id)
  record.kind = kind
  record.used_inputs = used_inputs
  record.used_outputs = used_outputs
  record.route_ids = {}
  for _, tile in ipairs(record.tiles) do
    if occupancy[tile_key(tile)] then
      return nil, "splitter_tile_occupied:" .. junction_id
    end
    local foreign, entity = tile_has_foreign_entity(s.agent.surface, tile, plan_id)
    if foreign then
      return nil, "splitter_foreign_entity:" .. junction_id .. ":" ..
        tostring(entity and entity.name or "unknown")
    end
  end
  for _, tile in ipairs(record.tiles) do
    mark_point(occupancy, tile, "planned", record.role)
  end
  physical.entities[#physical.entities + 1] = record
  physical.junctions[#physical.junctions + 1] = record
  physical.junction_by_id[junction_id] = record
  return record, nil
end

local function route_meta(from_kind, from_id, from_port, to_kind, to_id, to_port)
  return {
    from_kind = from_kind, from_id = from_id, from_port = from_port,
    to_kind = to_kind, to_id = to_id, to_port = to_port,
  }
end

local function expansion_route(s, physical, occupancy, plan_id, spec)
  local route = {
    id = spec.id, item = spec.item, kind = spec.kind or "item",
    from = spec.from or {}, to = spec.to or {},
    from_junction = spec.from_junction, from_junction_port = spec.from_junction_port,
    to_junction = spec.to_junction, to_junction_port = spec.to_junction_port,
    source_module_id = spec.source_module_id, source_port_id = spec.source_port_id,
    destination_module_id = spec.destination_module_id,
    destination_port_id = spec.destination_port_id,
    direction = spec.direction or "east",
    status = "route_planned", failure_reason = nil,
    steps = {}, belts = {}, underground_pairs = {},
    output_inserter = nil, input_inserter = nil, fuel_inserter = nil,
    chest_inserter = nil, chest = nil,
    ghost_units = {}, built_units = {},
    engine_connectivity = false, flow_observed = false,
  }
  local function add_step(step)
    if step.kind == "belt" then
      local record = entity_record(BELT, step.tile, step.direction, "belt", route.id)
      local added, reason = add_expansion_entity(s, physical, occupancy, plan_id, record)
      if not added then return nil, reason end
      route.belts[#route.belts + 1] = added
      route.steps[#route.steps + 1] = {kind = "belt", tile = copy_tile(step.tile),
        direction = step.direction, record = added}
    elseif step.kind == "underground" then
      local pair = transport.underground_pair("underground-belt", step.tile,
        step.direction, step.distance, "underground")
      if not pair then return nil, "underground_pair_invalid" end
      local entrance = pair.entrance
      local exit = pair.exit
      entrance.connection_id = route.id
      exit.connection_id = route.id
      local entrance_record = entity_record(entrance.name, entrance.tile,
        entrance.direction, "underground_entrance", route.id)
      entrance_record.underground_pair_id = pair.id
      entrance_record.underground_side = "entrance"
      entrance_record.underground_direction = pair.direction
      entrance_record.underground_other_tile = copy_tile(exit.tile)
      local exit_record = entity_record(exit.name, exit.tile, exit.direction,
        "underground_exit", route.id)
      exit_record.underground_pair_id = pair.id
      exit_record.underground_side = "exit"
      exit_record.underground_direction = pair.direction
      exit_record.underground_other_tile = copy_tile(entrance.tile)
      exit_record.build_direction = exit.build_direction
      local added_entrance, reason = add_expansion_entity(s, physical, occupancy, plan_id,
        entrance_record)
      if not added_entrance then return nil, reason end
      local added_exit, reason2 = add_expansion_entity(s, physical, occupancy, plan_id,
        exit_record)
      if not added_exit then return nil, reason2 end
      pair.entrance_record = added_entrance
      pair.exit_record = added_exit
      pair.connection_id = route.id
      physical.underground_pairs[#physical.underground_pairs + 1] = pair
      route.underground_pairs[#route.underground_pairs + 1] = pair
      route.steps[#route.steps + 1] = {kind = "underground", pair = pair,
        tile = copy_tile(entrance.tile), exit_tile = copy_tile(exit.tile),
        direction = pair.direction, distance = pair.distance,
        entrance = added_entrance, exit = added_exit}
    else
      return nil, "unknown_step_kind"
    end
    return true, nil
  end

  if spec.steps then
    for _, step in ipairs(spec.steps) do
      local ok, reason = add_step(step)
      if not ok then
        route.status, route.failure_reason = "blocked", reason
        break
      end
    end
  else
    local directions = route_directions(spec.path)
    for index, tile in ipairs(spec.path) do
      local ok, reason = add_step({kind = "belt", tile = tile, direction = directions[index]})
      if not ok then
        route.status, route.failure_reason = "blocked", reason
        break
      end
    end
  end
  if route.status ~= "blocked" then
    local function add_inserter(record, field)
      if not record then return true end
      local added, reason = add_expansion_entity(s, physical, occupancy, plan_id, record)
      if not added then return false, reason end
      route[field] = added
      return true, nil
    end
    local ok, reason = add_inserter(spec.output_inserter, "output_inserter")
    if ok then ok, reason = add_inserter(spec.input_inserter, "input_inserter") end
    if ok then ok, reason = add_inserter(spec.fuel_inserter, "fuel_inserter") end
    if ok then ok, reason = add_inserter(spec.chest_inserter, "chest_inserter") end
    if ok and spec.chest then
      local added, chest_reason = add_expansion_entity(s, physical, occupancy, plan_id, spec.chest)
      if added then route.chest = added else ok, reason = false, chest_reason end
    end
    if not ok then route.status, route.failure_reason = "blocked", reason end
  end
  route.fingerprint = transport.fingerprint(route.item, route.steps)
  physical.connections[#physical.connections + 1] = route
  if route.from_junction and physical.junction_by_id[route.from_junction] then
    local junction = physical.junction_by_id[route.from_junction]
    junction.route_ids[#junction.route_ids + 1] = route.id
  end
  if route.to_junction and physical.junction_by_id[route.to_junction] then
    local junction = physical.junction_by_id[route.to_junction]
    junction.route_ids[#junction.route_ids + 1] = route.id
  end
  return route
end

local function inserter_record(tile, direction, role, connection_id)
  return entity_record(INSERTER, tile, direction, role, connection_id)
end

local function collect_required_items(physical)
  local by_key = {}
  for _, record in ipairs(physical.entities) do
    if record then
      local prototype = prototypes.entity[record.name]
      for _, item in pairs(prototype and prototype.items_to_place_this or {}) do
        local key = item.name .. ":normal"
        by_key[key] = by_key[key] or {name = item.name, count = 0, quality = "normal"}
        by_key[key].count = by_key[key].count + item.count
      end
    end
  end
  physical.required_items = {}
  for _, key in ipairs(sorted_pairs_keys(by_key)) do
    physical.required_items[#physical.required_items + 1] = by_key[key]
  end
end

local function expansion_coal_source(s, physical, occupancy, area, cell, plan_id, coal_split)
  local surface = s.agent.surface
  local target_tile = {x = coal_split.anchor.x - 1, y = coal_split.anchor.y}
  local reference = tile_center(target_tile)
  local search_area = {
    {x = area[1].x - 20, y = area[1].y - 20},
    {x = area[2].x + 20, y = area[2].y + 20},
  }
  local chests = coal_chests(surface, search_area, reference)
  if #chests == 0 then return nil, "missing_fuel_source" end
  local last_reason = "missing_fuel_source"
  -- The splitter input tile is fed by a belt that points east into the splitter.
  for _, chest in ipairs(chests) do
    local chest_tile = tile_of(chest.position)
    local sides = {{dx = 0, dy = 1}, {dx = 1, dy = 0},
      {dx = 0, dy = -1}, {dx = -1, dy = 0}}
    for _, side in ipairs(sides) do
      local inserter_tile = {x = chest_tile.x + side.dx, y = chest_tile.y + side.dy}
      local belt_start = {x = chest_tile.x + side.dx * 2, y = chest_tile.y + side.dy * 2}
      local direction = side.dx < 0 and DIR.east
        or (side.dx > 0 and DIR.west)
        or (side.dy < 0 and DIR.south) or DIR.north
      local direct = same_tile(belt_start, target_tile)
        and same_tile(inserter_tile, {x = target_tile.x - 1, y = target_tile.y})
      if direct then
        local route = expansion_route(s, physical, occupancy, plan_id, {
          id = "coal_source", item = "coal", kind = "fuel",
          from = route_meta("chest", tostring(chest.unit_number), "coal", "junction",
            "coal_split", "input_top"),
          to_junction = "coal_split", to_junction_port = "input_top",
          steps = {{kind = "belt", tile = target_tile, direction = DIR.east}},
          chest_inserter = inserter_record(inserter_tile, direction,
            "fuel_chest_inserter", "coal_source"),
        })
        if route.status ~= "blocked" then
          return {
            status = "route_planned", item = "coal",
            source_chest_unit = chest.unit_number, source_chest_tile = chest_tile,
            direct = true, source_route = route, chest_inserter = route.chest_inserter,
            fuel_inserters = {}, branch_routes = {},
            verification = false, failure_reason = nil,
          }, nil
        end
        last_reason = route.failure_reason or "blocked_fuel_route"
      else
        local pre_goal = {x = target_tile.x - 2, y = target_tile.y}
        local last_belt = {x = target_tile.x - 1, y = target_tile.y}
        if not occupancy[tile_key(pre_goal)] and not occupancy[tile_key(last_belt)] then
          local blocked_copy = {}
          for key, value in pairs(occupancy) do blocked_copy[key] = value end
          mark_point(blocked_copy, chest_tile, "fuel_source", "fuel")
          mark_point(blocked_copy, inserter_tile, "planned", "fuel_chest_inserter")
          local allowed = {[tile_key(pre_goal)] = true}
          local path, reason = search_route(blocked_copy, belt_start, pre_goal,
            {allow = allowed})
          if path then
            local directions = route_directions(path)
            local approach_ok = true
            if #path > 1 then
              local previous = path[#path - 1]
              approach_ok = previous.x == pre_goal.x - 1 and previous.y == pre_goal.y
            end
            if approach_ok then
              local steps = {}
              for index, tile in ipairs(path) do
                steps[#steps + 1] = {kind = "belt", tile = tile, direction = directions[index]}
              end
              steps[#steps + 1] = {kind = "belt", tile = last_belt, direction = DIR.east}
              steps[#steps + 1] = {kind = "belt", tile = target_tile, direction = DIR.east}
              local route = expansion_route(s, physical, occupancy, plan_id, {
                id = "coal_source", item = "coal", kind = "fuel",
                from = route_meta("chest", tostring(chest.unit_number), "coal",
                  "junction", "coal_split", "input_top"),
                to_junction = "coal_split", to_junction_port = "input_top",
                steps = steps,
                chest_inserter = inserter_record(inserter_tile, direction,
                  "fuel_chest_inserter", "coal_source"),
              })
              if route.status ~= "blocked" then
                return {
                  status = "route_planned", item = "coal",
                  source_chest_unit = chest.unit_number, source_chest_tile = chest_tile,
                  direct = false, source_route = route,
                  chest_inserter = route.chest_inserter,
                  fuel_inserters = {}, branch_routes = {},
                  verification = false, failure_reason = nil,
                }, nil
              end
              last_reason = route.failure_reason or "blocked_fuel_route"
            else
              last_reason = "fuel_entry_approach_blocked"
            end
          else
            last_reason = reason or "blocked_fuel_route"
          end
        else
          last_reason = "fuel_entry_blocked"
        end
      end
    end
  end
  return nil, last_reason
end

function M.plan_expansion(s, p)
  local agent = s.agent
  assert(agent and agent.valid, "Agent is not alive")
  assert(not (s.safety and s.safety.active), "Safety controller is active")
  assert(type(p.layout_plan_id) == "string" and p.layout_plan_id ~= "",
    "layout_plan_id is required")
  local layout_plan = layout_plan_by_id(s, p.layout_plan_id)
  if not layout_plan then return {ok = false, status = "unknown_plan"} end
  if not layout_plan.materializable or not is_multi_consumer_plan(layout_plan) then
    return {ok = false, status = "unsupported_plan",
      reason = "plan_is_not_a_multi_consumer_layout"}
  end
  local plan_id = "logi_" .. digest(layout_plan.id .. "|" .. tostring(layout_plan.fingerprint))
    :sub(1, 16)
  local existing = s.logistics and s.logistics.by_id and s.logistics.by_id[plan_id]
  local reusable = existing and existing.mode == "multi_consumer" and
    (existing.status == "planned" or existing.status == "route_placed"
      or existing.status == "connected" or existing.status == "operational"
      or existing.status == "built")
  if reusable then
    return {ok = true, status = existing.status, physical = existing, reused = true}
  end
  local occupancy, area, players = build_occupancy(s, layout_plan, plan_id)
  area.center = {x = (area[1].x + area[2].x) / 2, y = (area[1].y + area[2].y) / 2}
  local physical = {
    schema_version = M.SCHEMA_VERSION, mode = "multi_consumer", id = plan_id,
    layout_plan_id = layout_plan.id, goal_item = layout_plan.goal_item,
    surface_index = agent.surface.index, surface_name = agent.surface.name,
    created_tick = game.tick, status = "planned",
    connections = {}, entities = {}, required_items = {},
    junctions = {}, junction_by_id = {}, underground_pairs = {},
    output = nil, fuel = nil, power = nil,
    observation = {
      gauge_initial = nil, started_tick = nil, output_gears = 0,
      ore_seen = false, coal_seen = false, plate_seen = false,
      gear_produced = false, gear_recipe_ok = false,
      consumers = {
        ore = {}, fuel = {}, plate = {}, gear = {},
      },
      route_flow = {}, plated_by = {}, gear_by = {},
      plate_produced_by = {}, gear_produced_by = {},
      initial_products = {smelting_1 = 0, smelting_2 = 0,
        production_1 = 0, production_2 = 0},
      power_ok = false, fuel_ok = false, all_connected = false,
    },
    blocked = nil, unsupported = nil, cell = layout_plan.logistics.cell,
  }
  local player_block = false
  for _, player in ipairs(players or {}) do
    if player.valid then
      for _, module in ipairs(layout_plan.modules or {}) do
        if player.position.x > module.bounds[1].x - 0.5
          and player.position.x < module.bounds[2].x + 0.5
          and player.position.y > module.bounds[1].y - 0.5
          and player.position.y < module.bounds[2].y + 0.5 then
          player_block = true
        end
      end
    end
  end
  if player_block then
    physical.status, physical.blocked = "blocked", "player_in_module_footprint"
    return {ok = false, status = "blocked", reason = "player_in_module_footprint",
      physical = store_physical(s, physical)}
  end
  local cell = layout_plan.logistics.cell
  local junctions_meta = {
    ore_split = {used_inputs = {[1] = true}, used_outputs = {[1] = true, [2] = true}},
    plate_merge = {used_inputs = {[1] = true, [2] = true}, used_outputs = {[1] = true}},
    plate_split = {used_inputs = {[1] = true}, used_outputs = {[1] = true, [2] = true}},
    gear_merge = {used_inputs = {[1] = true, [2] = true}, used_outputs = {[1] = true}},
    coal_split = {used_inputs = {[1] = true}, used_outputs = {[1] = true, [2] = true}},
  }
  local junction_records = {}
  for _, id in ipairs({"ore_split", "plate_merge", "plate_split", "gear_merge", "coal_split"}) do
    local meta = cell.junctions[id]
    local usage = junctions_meta[id]
    local record, reason = add_expansion_splitter(s, physical, occupancy, plan_id, id,
      meta, meta.kind, usage.used_inputs, usage.used_outputs)
    if not record then
      physical.status, physical.blocked = "blocked", reason or "blocked_splitter"
      return {ok = false, status = "blocked", reason = physical.blocked,
        physical = store_physical(s, physical)}
    end
    junction_records[id] = record
  end
  local mining = module_by_node(layout_plan, "mining_1")
  local smelting1 = module_by_node(layout_plan, "smelting_1")
  local smelting2 = module_by_node(layout_plan, "smelting_2")
  local production1 = module_by_node(layout_plan, "production_1")
  local production2 = module_by_node(layout_plan, "production_2")
  if not (mining and smelting1 and smelting2 and production1 and production2) then
    physical.status, physical.blocked = "blocked", "module_missing"
    return {ok = false, status = "blocked", reason = "module_missing",
      physical = store_physical(s, physical)}
  end
  local anchor = cell.mining_anchor
  local function at(offset)
    return {x = anchor.x + offset.x, y = anchor.y + offset.y}
  end
  -- The fixed cell routes are defined as offsets from the mining anchor. They are
  -- materialized as ordinary belts, inserters, splitters and one underground pair.
  local routes = {
    {
      id = "ore_trunk", item = "iron-ore",
      from = route_meta("module", "mining_1", "ore_output", "junction", "ore_split", "input_top"),
      to_junction = "ore_split", to_junction_port = "input_top",
      source_module_id = "mining_1", source_port_id = "ore_output",
      path = {at({x = 3, y = 1}), at({x = 4, y = 1}), at({x = 5, y = 1})},
    },
    {
      id = "ore_branch_a", item = "iron-ore",
      from = route_meta("junction", "ore_split", "output_top", "module", "smelting_1", "ore_input"),
      from_junction = "ore_split", from_junction_port = "output_top",
      destination_module_id = "smelting_1", destination_port_id = "ore_input",
      path = {at({x = 7, y = 1}), at({x = 8, y = 1})},
      input_inserter = inserter_record(at({x = 9, y = 1}), DIR.west,
        "ore_input_inserter_smelting_1", "ore_branch_a"),
    },
    {
      id = "ore_branch_b", item = "iron-ore",
      from = route_meta("junction", "ore_split", "output_bottom", "module", "smelting_2", "ore_input"),
      from_junction = "ore_split", from_junction_port = "output_bottom",
      destination_module_id = "smelting_2", destination_port_id = "ore_input",
      path = {at({x = 7, y = 2}), at({x = 7, y = 3}), at({x = 7, y = 4}),
        at({x = 7, y = 5}), at({x = 7, y = 6}), at({x = 7, y = 7}), at({x = 8, y = 7})},
      input_inserter = inserter_record(at({x = 9, y = 7}), DIR.west,
        "ore_input_inserter_smelting_2", "ore_branch_b"),
    },
    {
      id = "plate_a", item = "iron-plate",
      from = route_meta("module", "smelting_1", "plate_output", "junction", "plate_merge", "input_top"),
      to_junction = "plate_merge", to_junction_port = "input_top",
      source_module_id = "smelting_1", source_port_id = "plate_output",
      path = {at({x = 13, y = 1}), at({x = 14, y = 1})},
      output_inserter = inserter_record(at({x = 12, y = 1}), DIR.west,
        "plate_output_inserter_smelting_1", "plate_a"),
    },
    {
      id = "plate_b", item = "iron-plate",
      from = route_meta("module", "smelting_2", "plate_output", "junction", "plate_merge", "input_bottom"),
      to_junction = "plate_merge", to_junction_port = "input_bottom",
      source_module_id = "smelting_2", source_port_id = "plate_output",
      path = {at({x = 13, y = 7}), at({x = 13, y = 6}), at({x = 13, y = 5}),
        at({x = 13, y = 4}), at({x = 13, y = 3}), at({x = 13, y = 2}), at({x = 14, y = 2})},
      output_inserter = inserter_record(at({x = 12, y = 7}), DIR.west,
        "plate_output_inserter_smelting_2", "plate_b"),
    },
    {
      id = "plate_trunk", item = "iron-plate",
      from = route_meta("junction", "plate_merge", "output_top", "junction", "plate_split", "input_top"),
      from_junction = "plate_merge", from_junction_port = "output_top",
      to_junction = "plate_split", to_junction_port = "input_top",
      path = {at({x = 16, y = 1}), at({x = 17, y = 1})},
    },
    {
      id = "plate_branch_a", item = "iron-plate",
      from = route_meta("junction", "plate_split", "output_top", "module", "production_1", "plate_input"),
      from_junction = "plate_split", from_junction_port = "output_top",
      destination_module_id = "production_1", destination_port_id = "plate_input",
      path = {at({x = 19, y = 1})},
      input_inserter = inserter_record(at({x = 20, y = 1}), DIR.west,
        "plate_input_inserter_production_1", "plate_branch_a"),
    },
    {
      id = "plate_branch_b", item = "iron-plate",
      from = route_meta("junction", "plate_split", "output_bottom", "module", "production_2", "plate_input"),
      from_junction = "plate_split", from_junction_port = "output_bottom",
      destination_module_id = "production_2", destination_port_id = "plate_input",
      path = {at({x = 19, y = 2}), at({x = 19, y = 3}), at({x = 19, y = 4}),
        at({x = 19, y = 5}), at({x = 19, y = 6})},
      input_inserter = inserter_record(at({x = 20, y = 6}), DIR.west,
        "plate_input_inserter_production_2", "plate_branch_b"),
    },
    {
      id = "gear_a", item = "iron-gear-wheel",
      from = route_meta("module", "production_1", "gear_output", "junction", "gear_merge", "input_top"),
      to_junction = "gear_merge", to_junction_port = "input_top",
      source_module_id = "production_1", source_port_id = "gear_output",
      path = {at({x = 25, y = 1}), at({x = 26, y = 1})},
      output_inserter = inserter_record(at({x = 24, y = 1}), DIR.west,
        "gear_output_inserter_production_1", "gear_a"),
    },
    {
      id = "gear_b", item = "iron-gear-wheel",
      from = route_meta("module", "production_2", "gear_output", "junction", "gear_merge", "input_bottom"),
      to_junction = "gear_merge", to_junction_port = "input_bottom",
      source_module_id = "production_2", source_port_id = "gear_output",
      path = {at({x = 25, y = 6}), at({x = 25, y = 5}), at({x = 25, y = 4}),
        at({x = 25, y = 3}), at({x = 25, y = 2}), at({x = 26, y = 2})},
      output_inserter = inserter_record(at({x = 24, y = 6}), DIR.west,
        "gear_output_inserter_production_2", "gear_b"),
    },
    {
      id = "gear_output", item = "iron-gear-wheel",
      from = route_meta("junction", "gear_merge", "output_top", "output", "gear_chest", "gear_output"),
      from_junction = "gear_merge", from_junction_port = "output_top",
      path = {at({x = 28, y = 1})},
      output_inserter = inserter_record(at({x = 29, y = 1}), DIR.west,
        "gear_common_output_inserter", "gear_output"),
    },
  }
  local route_by_id = {}
  for _, spec in ipairs(routes) do
    local route = expansion_route(s, physical, occupancy, plan_id, spec)
    route_by_id[route.id] = route
  end
  local output_chest_tile = cell.output_chest_tile
  local output_chest = entity_record(OUTPUT_CHEST, output_chest_tile, 0, "output_chest", "output")
  local added_chest, output_reason = add_expansion_entity(s, physical, occupancy, plan_id,
    output_chest)
  if not added_chest then
    physical.status, physical.blocked = "blocked", output_reason or "blocked_output"
    return {ok = false, status = "blocked", reason = physical.blocked,
      physical = store_physical(s, physical)}
  end
  physical.output = {
    status = "route_planned", item = "iron-gear-wheel",
    inserter = route_by_id.gear_output.output_inserter, chest = added_chest,
    route_id = "gear_output", verification = false, initial_gear_count = 0,
  }
  local fuel, fuel_reason = expansion_coal_source(s, physical, occupancy, area, cell,
    plan_id, junction_records.coal_split)
  if not fuel then
    physical.status = fuel_reason == "missing_fuel_source" and "missing_fuel_source"
      or "blocked"
    physical.blocked = fuel_reason
    collect_required_items(physical)
    return {ok = false, status = physical.status, reason = fuel_reason,
      physical = store_physical(s, physical)}
  end
  physical.fuel = fuel
  local coal_branch_a = expansion_route(s, physical, occupancy, plan_id, {
    id = "coal_branch_a", item = "coal", kind = "fuel",
    from = route_meta("junction", "coal_split", "output_top", "module", "smelting_1", "fuel_input"),
    from_junction = "coal_split", from_junction_port = "output_top",
    destination_module_id = "smelting_1", destination_port_id = "fuel_input",
    path = {at({x = 8, y = -2}), at({x = 9, y = -2}), at({x = 10, y = -2}),
      at({x = 11, y = -2})},
    fuel_inserter = inserter_record(at({x = 11, y = -1}), DIR.north,
      "fuel_inserter_smelting_1", "coal_branch_a"),
  })
  local ug = cell.underground
  local ug_pair = transport.underground_pair("underground-belt", ug.entrance,
    ug.direction, ug.distance, "underground")
  if not ug_pair then
    physical.status, physical.blocked = "blocked", "underground_pair_invalid"
    return {ok = false, status = "blocked", reason = "underground_pair_invalid",
      physical = store_physical(s, physical)}
  end
  local coal_branch_b = expansion_route(s, physical, occupancy, plan_id, {
    id = "coal_branch_b", item = "coal", kind = "fuel",
    from = route_meta("junction", "coal_split", "output_bottom", "module", "smelting_2", "fuel_input"),
    from_junction = "coal_split", from_junction_port = "output_bottom",
    destination_module_id = "smelting_2", destination_port_id = "fuel_input",
    steps = {
      {kind = "belt", tile = at({x = 8, y = -1}), direction = DIR.south},
      {kind = "underground", tile = ug.entrance, direction = ug.direction,
        distance = ug.distance},
      {kind = "belt", tile = at({x = 8, y = 3}), direction = DIR.south},
      {kind = "belt", tile = at({x = 8, y = 4}), direction = DIR.east},
      {kind = "belt", tile = at({x = 9, y = 4}), direction = DIR.east},
      {kind = "belt", tile = at({x = 10, y = 4}), direction = DIR.east},
      {kind = "belt", tile = at({x = 11, y = 4}), direction = DIR.east},
    },
    fuel_inserter = inserter_record(at({x = 11, y = 5}), DIR.north,
      "fuel_inserter_smelting_2", "coal_branch_b"),
  })
  fuel.fuel_inserters = {coal_branch_a.fuel_inserter, coal_branch_b.fuel_inserter}
  fuel.branch_routes = {coal_branch_a, coal_branch_b}
  fuel.fuel_splitter = junction_records.coal_split
  local blocked_routes = 0
  for _, route in ipairs(physical.connections) do
    if route.status == "blocked" then blocked_routes = blocked_routes + 1 end
  end
  local power, power_reason = plan_power(s, layout_plan, physical, occupancy, area)
  if not power then
    physical.status = power_reason == "missing_power_source" and "missing_power_source"
      or "blocked"
    physical.blocked = power_reason
    collect_required_items(physical)
    return {ok = false, status = physical.status, reason = power_reason,
      physical = store_physical(s, physical)}
  end
  physical.power = power
  for _, pole in ipairs(power.poles) do physical.entities[#physical.entities + 1] = pole end
  collect_required_items(physical)
  if blocked_routes > 0 or coal_branch_a.status == "blocked"
    or coal_branch_b.status == "blocked" then
    physical.status, physical.blocked = "blocked", "blocked_route"
  else
    physical.status = "planned"
  end
  physical.observation.gauge_initial = 0
  store_physical(s, physical)
  return {ok = physical.status == "planned", status = physical.status,
    physical = physical, reason = physical.blocked}
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
  -- A player anywhere inside the bounded scan rectangle does not invalidate the whole
  -- chain. Only a character physically intersecting a planned module footprint is a hard
  -- planning conflict; routes avoid player work areas through the occupancy map and ghost
  -- placement checks each tile again.
  local player_block = false
  for _, player in ipairs(players or {}) do
    if player.valid then
      for _, module in ipairs(layout_plan.modules or {}) do
        if player.position.x > module.bounds[1].x - 0.5
          and player.position.x < module.bounds[2].x + 0.5
          and player.position.y > module.bounds[1].y - 0.5
          and player.position.y < module.bounds[2].y + 0.5 then
          player_block = true
        end
      end
    end
  end
  if player_block then
    physical.status = "blocked"
    physical.blocked = "player_in_module_footprint"
    return {ok = false, status = "blocked", reason = "player_in_module_footprint",
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
  if record.underground_pair_id then
    tags.ae_underground_pair = record.underground_pair_id
    tags.ae_underground_side = record.underground_side
    tags.ae_underground_direction = record.underground_direction
    tags.ae_underground_other_x = record.underground_other_tile.x
    tags.ae_underground_other_y = record.underground_other_tile.y
  end
  if record.name == "assembling-machine-1" then tags.ae_recipe = "iron-gear-wheel" end
  local ok, ghost = pcall(function()
    return surface.create_entity{
      name = "entity-ghost", inner_name = record.name, position = record.position,
      direction = record.build_direction or record.direction or 0, force = s.agent.force,
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
  local was_built = physical.status == "connected" or physical.status == "operational"
    or physical.status == "built" or physical.status == "blocked"
  if physical.status ~= "planned" and physical.status ~= "route_placed" and not was_built then
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
          elseif was_built then
            -- A built plan is never silently rebuilt. A missing real entity is a player
            -- change or damage; report it and let verification/safety decide.
            blocked[#blocked + 1] = {role = record.role,
              reason = "missing_after_player_change", tile = copy_tile(tile)}
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
  physical.status = was_built and "connected" or "route_placed"
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

-- ---------------------------------------------------------------------------
-- Stage-7 multi-consumer verification and flow observation
-- ---------------------------------------------------------------------------

local function simple_inventory_count(entity, inventory_id, item)
  if not entity or not entity.valid then return 0 end
  local ok, inventory = pcall(function() return entity.get_inventory(inventory_id) end)
  if not ok or not inventory then return 0 end
  return inventory.get_item_count{name = item, quality = "normal"}
end

local function burner_fuel_count(entity)
  if not entity or not entity.valid or not entity.burner then return 0 end
  local ok, value = pcall(function() return entity.burner.remaining_burning_fuel end)
  return ok and value or 0
end

local function module_products_finished(entity)
  if not entity or not entity.valid then return 0 end
  local ok, value = pcall(function() return entity.products_finished end)
  return ok and value or 0
end

local function expansion_machine(surface, layout, node_id)
  return find_machine(surface, module_by_node(layout, node_id))
end

local function ensure_expansion_observation(physical)
  local observation = physical.observation
  observation.consumers = observation.consumers or {}
  observation.consumers.ore = observation.consumers.ore or {}
  observation.consumers.fuel = observation.consumers.fuel or {}
  observation.consumers.plate = observation.consumers.plate or {}
  observation.consumers.gear = observation.consumers.gear or {}
  observation.route_flow = observation.route_flow or {}
  observation.plated_by = observation.plated_by or {}
  observation.gear_by = observation.gear_by or {}
  observation.plate_produced_by = observation.plate_produced_by or {}
  observation.gear_produced_by = observation.gear_produced_by or {}
  observation.initial_products = observation.initial_products or {}
  return observation
end

local function capture_expansion_initial_products(s, physical)
  local surface = game.surfaces[physical.surface_index]
  local layout = layout_plan_by_id(s, physical.layout_plan_id)
  if not surface or not layout then return end
  local observation = ensure_expansion_observation(physical)
  for _, node_id in ipairs({"smelting_1", "smelting_2", "production_1", "production_2"}) do
    if observation.initial_products[node_id] == nil then
      observation.initial_products[node_id] =
        module_products_finished(expansion_machine(surface, layout, node_id))
    end
  end
end

local function expansion_route_connected(surface, route)
  local transitions_bad = false
  for index, step in ipairs(route.steps or {}) do
    local next_step = route.steps[index + 1]
    if step.kind == "belt" then
      local belt = surface.find_entity(BELT,
        {x = step.tile.x + 0.5, y = step.tile.y + 0.5}) or find_real(surface, step.tile, BELT)
      if not belt then return false, "belt_missing" end
      if next_step then
        local expected_tile = next_step.kind == "belt" and next_step.tile
          or (next_step.entrance and next_step.entrance.tile)
        if expected_tile and not transport.belt_outputs_to(belt, expected_tile) then
          return false, "belt_output_not_connected"
        end
      end
    elseif step.kind == "underground" then
      local pair = step.pair
      local verified = transport.verify_underground_pair(surface, pair)
      if not verified.ok then return false, "underground_" .. tostring(verified.reason) end
      if next_step and next_step.kind == "belt" then
        local exit = step.exit and step.exit
        local exit_entity = exit and (surface.find_entity(exit.name,
          {x = exit.tile.x + 0.5, y = exit.tile.y + 0.5})
          or find_real(surface, exit.tile, exit.name))
        if not exit_entity or not transport.belt_outputs_to(exit_entity, next_step.tile) then
          return false, "underground_exit_not_connected"
        end
      end
    end
  end
  return true, nil
end

function M.verify_expansion(s, p)
  local physical = s.logistics and s.logistics.by_id and s.logistics.by_id[p.logistics_plan_id]
  if not physical then return {ok = false, status = "unknown_plan"} end
  local surface = game.surfaces[physical.surface_index]
  if not surface then return {ok = false, status = "blocked", reason = "surface_missing"} end
  capture_expansion_initial_products(s, physical)
  local missing, wrong = {}, {}
  for _, record in ipairs(physical.entities or {}) do
    if record then
      local entity = find_real(surface, record.tile, record.name)
      if not entity then
        missing[#missing + 1] = {role = record.role, name = record.name,
          tile = copy_tile(record.tile)}
      elseif record.direction and entity.direction ~= record.direction
        and entity.type ~= "container" then
        wrong[#wrong + 1] = {role = record.role, name = record.name,
          expected = record.direction, actual = entity.direction}
      else
        record.built_unit = entity.unit_number
      end
    end
  end
  local junction_details = {}
  local all_junctions = true
  for _, junction in ipairs(physical.junctions or {}) do
    local verified = transport.verify_splitter(surface, junction)
    junction.verification = verified
    if not verified.ok then all_junctions = false end
    junction_details[#junction_details + 1] = {
      id = junction.junction_id, kind = junction.kind, ok = verified.ok,
      reason = verified.reason,
    }
  end
  local underground_details = {}
  local all_underground = true
  for _, pair in ipairs(physical.underground_pairs or {}) do
    local verified = transport.verify_underground_pair(surface, pair)
    pair.verification = verified
    if not verified.ok then all_underground = false end
    underground_details[#underground_details + 1] = {
      id = pair.id, ok = verified.ok, reason = verified.reason,
      distance = verified.distance,
    }
  end
  local route_details = {}
  local all_routes = true
  for _, route in ipairs(physical.connections or {}) do
    local ok, reason = expansion_route_connected(surface, route)
    route.engine_connectivity = ok
    if ok then
      route.status, route.failure_reason = "connected", nil
    else
      route.status, route.failure_reason = "blocked", reason or "not_connected"
      all_routes = false
    end
    route_details[#route_details + 1] = {
      id = route.id, item = route.item, status = route.status,
      connected = ok, reason = route.failure_reason, flow = route.flow_observed == true,
    }
  end
  local entities_ok = #missing == 0 and #wrong == 0
  if entities_ok and all_junctions and all_underground and all_routes then
    physical.status = "connected"
  else
    physical.status = "blocked"
    physical.blocked = "route_not_connected"
  end
  local power = M.verify_power(s, physical)
  local observation = M.observe_expansion(s, physical)
  local consumers = {
    ore = {
      smelting_1 = observation.consumers.ore.smelting_1
        and observation.consumers.ore.smelting_1.seen == true,
      smelting_2 = observation.consumers.ore.smelting_2
        and observation.consumers.ore.smelting_2.seen == true,
    },
    fuel = {
      smelting_1 = observation.consumers.fuel.smelting_1
        and observation.consumers.fuel.smelting_1.seen == true,
      smelting_2 = observation.consumers.fuel.smelting_2
        and observation.consumers.fuel.smelting_2.seen == true,
    },
    plate = {
      production_1 = observation.consumers.plate.production_1
        and observation.consumers.plate.production_1.seen == true,
      production_2 = observation.consumers.plate.production_2
        and observation.consumers.plate.production_2.seen == true,
    },
    gear = {
      production_1 = observation.consumers.gear.production_1
        and observation.consumers.gear.production_1.seen == true,
      production_2 = observation.consumers.gear.production_2
        and observation.consumers.gear.production_2.seen == true,
    },
  }
  local function all_true(value)
    for _, result in pairs(value) do if result ~= true then return false end end
    return true
  end
  local consumers_supplied = all_true(consumers.ore) and all_true(consumers.fuel)
    and all_true(consumers.plate)
  local production_active = (observation.plate_produced_by or {}).smelting_1 == true
    and (observation.plate_produced_by or {}).smelting_2 == true
    and (observation.gear_produced_by or {}).production_1 == true
    and (observation.gear_produced_by or {}).production_2 == true
  local output_verified = observation.gear_produced == true
  local fuel_ok = all_true(consumers.fuel)
    and ((observation.coal_remaining or 0) > 0
      or (observation.furnace_fuel_remaining or 0) > 0)
  local ok = entities_ok and power.ok and all_junctions and all_underground
    and all_routes and fuel_ok and consumers_supplied and production_active
    and output_verified
  local status = "connected"
  if not entities_ok or not all_junctions or not all_underground or not all_routes then
    status = "blocked"
  elseif not power.ok then
    status = "missing_power_source"
  elseif not fuel_ok then
    status = "missing_fuel_source"
  elseif not output_verified then
    status = "connected"
  elseif not production_active then
    status = "connected"
  elseif ok then
    status = "operational"
  end
  physical.status = status
  physical.verification = {
    entities = {ok = entities_ok, missing = missing, wrong = wrong},
    power = power, junctions = junction_details, underground = underground_details,
    routes = route_details, fuel = fuel_ok, observation = observation, tick = game.tick,
  }
  return {
    ok = ok, status = status, mode = "multi_consumer",
    entities = entities_ok, power = power.ok, fuel = fuel_ok,
    routes_connected = all_routes and all_junctions and all_underground,
    routes = route_details, junctions = junction_details,
    underground = underground_details,
    consumers = consumers, consumers_supplied = consumers_supplied,
    production_active = production_active and true or false,
    output_verified = output_verified,
    observation = observation,
    missing = missing, wrong_direction = wrong,
    missing_power = power.ok and nil or power.required,
  }
end

function M.observe_expansion(s, physical)
  local surface = game.surfaces[physical.surface_index]
  local layout = layout_plan_by_id(s, physical.layout_plan_id)
  if not surface or not layout then return ensure_expansion_observation(physical) end
  local observation = ensure_expansion_observation(physical)
  observation.started_tick = observation.started_tick or game.tick
  local ore_by_id = {}
  local fuel_by_id = {}
  local plate_by_id = {}
  local gear_by_id = {}
  for _, node_id in ipairs({"smelting_1", "smelting_2"}) do
    local furnace = expansion_machine(surface, layout, node_id)
    local ore = simple_inventory_count(furnace, defines.inventory.crafter_input, "iron-ore")
    local plate = simple_inventory_count(furnace, defines.inventory.crafter_output, "iron-plate")
    local fuel_item = simple_inventory_count(furnace, defines.inventory.fuel, "coal")
    local burning = burner_fuel_count(furnace)
    ore_by_id[node_id] = ore
    fuel_by_id[node_id] = fuel_item + burning
    plate_by_id[node_id] = plate
    local ore_record = observation.consumers.ore[node_id] or {}
    local fuel_record = observation.consumers.fuel[node_id] or {}
    local plate_record = observation.consumers.plate[node_id] or {}
    if ore > 0 then ore_record.seen = true end
    if fuel_item > 0 or burning > 0 or (furnace and furnace.status == defines.entity_status.working) then
      fuel_record.seen = true
    end
    if plate > 0 then plate_record.seen = true end
    ore_record.current = ore
    fuel_record.current = fuel_item
    fuel_record.burning = burning
    plate_record.current = plate
    observation.consumers.ore[node_id] = ore_record
    observation.consumers.fuel[node_id] = fuel_record
    observation.consumers.plate[node_id] = plate_record
    observation.plated_by[node_id] = observation.plated_by[node_id] or plate > 0
    if observation.initial_products[node_id] ~= nil then
      observation.plate_produced_by = observation.plate_produced_by or {}
      if module_products_finished(furnace) > observation.initial_products[node_id] then
        observation.plate_produced_by[node_id] = true
        plate_record.seen = true
        observation.consumers.plate[node_id] = plate_record
      end
    end
    if furnace then
      observation["furnace_" .. node_id .. "_status"] = furnace.status
    end
  end
  for _, node_id in ipairs({"production_1", "production_2"}) do
    local assembler = expansion_machine(surface, layout, node_id)
    local plate = simple_inventory_count(assembler, defines.inventory.crafter_input, "iron-plate")
    local gear = simple_inventory_count(assembler, defines.inventory.crafter_output,
      "iron-gear-wheel")
    local plate_record = observation.consumers.plate[node_id] or {}
    local gear_record = observation.consumers.gear[node_id] or {}
    if plate > 0 then plate_record.seen = true end
    if gear > 0 then gear_record.seen = true end
    plate_record.current = plate
    gear_record.current = gear
    observation.consumers.plate[node_id] = plate_record
    observation.consumers.gear[node_id] = gear_record
    local recipe_name = nil
    if assembler then
      local ok, recipe = pcall(function() return assembler.get_recipe() end)
      recipe_name = ok and recipe and recipe.name or nil
      observation.assembler_recipe_ok = observation.assembler_recipe_ok or
        (recipe_name == "iron-gear-wheel")
    end
    if observation.initial_products[node_id] ~= nil and assembler then
      observation.gear_by = observation.gear_by or {}
      observation.gear_produced_by = observation.gear_produced_by or {}
      if module_products_finished(assembler) > observation.initial_products[node_id] then
        observation.gear_produced_by[node_id] = true
        gear_record.seen = true
        plate_record.seen = true
        observation.consumers.gear[node_id] = gear_record
        observation.consumers.plate[node_id] = plate_record
      end
    end
    if assembler then observation["assembler_" .. node_id .. "_status"] = assembler.status end
  end
  observation.gear_recipe_ok = observation.assembler_recipe_ok == true
  local output_gears = M.count_output_gears(s, physical)
  observation.output_gears = output_gears
  if output_gears > (observation.gauge_initial or 0) then observation.gear_produced = true end
  local coal = 0
  if physical.fuel and physical.fuel.source_chest_unit then
    local chests = surface.find_entities_filtered{type = {"container", "logistic-container"}}
    for _, chest in pairs(chests) do
      if chest.unit_number == physical.fuel.source_chest_unit then
        coal = simple_inventory_count(chest, defines.inventory.chest, "coal")
        break
      end
    end
  end
  observation.coal_remaining = coal
  observation.furnace_ore = ore_by_id
  observation.furnace_fuel = fuel_by_id
  observation.furnace_plate = plate_by_id
  observation.assembler_plate = plate_by_id
  if coal > 0 or (fuel_by_id.smelting_1 or 0) > 0 or (fuel_by_id.smelting_2 or 0) > 0 then
    observation.coal_seen = true
  end
  if (ore_by_id.smelting_1 or 0) > 0 or (ore_by_id.smelting_2 or 0) > 0 then
    observation.ore_seen = true
  end
  if (plate_by_id.smelting_1 or 0) > 0 or (plate_by_id.smelting_2 or 0) > 0 then
    observation.plate_seen = true
  end
  local fuel_total = (fuel_by_id.smelting_1 or 0) + (fuel_by_id.smelting_2 or 0)
  observation.furnace_fuel_remaining = fuel_total
  for _, route in ipairs(physical.connections or {}) do
    if not route.flow_observed and #route.belts > 0 then
      local belt_record = route.belts[1]
      local belt = find_real(surface, belt_record.tile, BELT)
      if belt then
        local flow = transport.read_belt_flow(belt)
        local function has_item(contents)
          for _, item in pairs(contents or {}) do
            if item.name == route.item and (item.count or 0) > 0 then return true end
          end
          return false
        end
        if has_item(flow.left) or has_item(flow.right) then
          route.flow_observed = true
          observation.route_flow[route.id] = true
        end
      end
    end
  end
  return observation
end

function M.verify(s, p)
  local physical = s.logistics and s.logistics.by_id and s.logistics.by_id[p.logistics_plan_id]
  if not physical then return {ok = false, status = "unknown_plan"} end
  if physical.mode == "multi_consumer" then return M.verify_expansion(s, p) end
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
    local key = connection.connected and "connected" or connection.status
    connection_counts[key] = (connection_counts[key] or 0) + 1
  end
  local entities_total = #(physical.entities or {})
  local ghost_count, built_count = 0, 0
  for _, record in ipairs(physical.entities or {}) do
    if record then
      if record.ghost_unit then ghost_count = ghost_count + 1 end
      if record.built_unit then built_count = built_count + 1 end
    end
  end
  local observation = physical.observation or {}
  local consumers = observation.consumers or nil
  local produced_by = observation.gear_produced_by or {}
  return {
    ok = physical.status == "operational",
    mode = physical.mode or "linear_chain",
    logistics_plan_id = physical.id, layout_plan_id = physical.layout_plan_id,
    goal_item = physical.goal_item, status = physical.status,
    connections = connection_counts,
    connection_total = #(physical.connections or {}),
    junctions = #(physical.junctions or {}),
    underground_pairs = #(physical.underground_pairs or {}),
    entities_total = entities_total, ghosts_placed = ghost_count,
    entities_built = built_count,
    consumers = consumers,
    production_active = (produced_by.production_1 == true
      and produced_by.production_2 == true),
    output_verified = observation.gear_produced == true,
    fuel_status = physical.fuel and physical.fuel.status or "missing_fuel_source",
    power_status = physical.power and physical.power.status or "missing_power_source",
    produced = observation.gear_produced == true,
    required_items = physical.required_items,
    reason = physical.blocked,
  }
end

return M
