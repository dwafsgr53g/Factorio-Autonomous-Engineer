-- Deterministic Layout Planner for the declarative module library.
--
-- Phase A (create) resolves a production goal into a minimal module set, finds a bounded,
-- deterministic set of placements and persists the plan. It creates no entity and spends
-- no item. Phase B (apply) revalidates the persisted plan against the live world and asks
-- the existing module placer to create ordinary entity ghosts. Actual paid construction
-- remains the Stage-3 assist_construction executor; this module never revives a ghost.
--
-- Raw coordinates, entity records and ports stay internal. The public summary contains only
-- strategic facts. The layout plan is not a working factory: belts, pipes, inserters, wires,
-- fuel insertion and throughput are outside this stage.
local clearing = require("lib.clearing")
local collaboration = require("lib.collaboration")
local format = require("lib.module_format")
local module_placer = require("lib.module_placer")
local modules = require("lib.modules")
local production_graph = require("lib.production_graph")
local strategy = require("lib.strategy")

local M = {}

M.SCHEMA_VERSION = 1
local PLAN_RADIUS = collaboration.work_radius()
local PLAYER_SAFETY_RADIUS = collaboration.player_work_radius()
local MAX_CANDIDATES_PER_MODULE = 96
local MAX_RING = 24
local RING_STEP = 2
local EXPANSION_MARGIN = 6
local PLANNING_GAP = 1
local INFRASTRUCTURE_RADIUS = 16
local ELECTRIC_RADIUS = 16
local MAX_STORED_PLANS = 32
local HASH_MODULUS = 2147483647

-- Documented deterministic scoring weights. The score is an integer; lower is better.
M.SCORING = {
  connection_distance = 4,
  center_distance = 1,
  clearing_obstacle = 12,
  crowding_obstacle = 2,
  infrastructure_pole_bonus = 3,
  nearby_player = 6,
}
M.TIE_BREAK_ORDER = {
  "score", "connection_distance", "center_distance", "clearing_count",
  "infrastructure_high", "orientation_ascending", "anchor_x", "anchor_y", "node_id",
}

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function hash32(text, seed)
  local value = seed % HASH_MODULUS
  for index = 1, #text do
    value = (value * 131 + string.byte(text, index)) % HASH_MODULUS
  end
  return value
end

local function digest(text)
  return string.format("%08x%08x", hash32(text, 5381), hash32(text, 52711))
end

local function sorted_parameter_string(parameters)
  local names = {}
  for name in pairs(parameters or {}) do names[#names + 1] = name end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    parts[#parts + 1] = name .. "=" .. tostring(parameters[name])
  end
  return table.concat(parts, ";")
end

local function rect(anchor, footprint)
  return {
    left = anchor.x, top = anchor.y,
    right = anchor.x + footprint.width, bottom = anchor.y + footprint.height,
  }
end

local function area_rect(area)
  return {
    left = area[1].x, top = area[1].y, right = area[2].x, bottom = area[2].y,
  }
end

local function rects_overlap(a, b)
  return a.left < b.right - 1e-9 and b.left < a.right - 1e-9
    and a.top < b.bottom - 1e-9 and b.top < a.bottom - 1e-9
end

local function expand_rect(box, amount)
  return {
    left = box.left - amount, top = box.top - amount,
    right = box.right + amount, bottom = box.bottom + amount,
  }
end

local function point_rect_distance(point, box)
  local x = math.max(box.left, math.min(point.x, box.right))
  local y = math.max(box.top, math.min(point.y, box.bottom))
  return distance(point, {x = x, y = y})
end

local function module_areas(module)
  local areas = {area_rect(module.bounds)}
  for _, reserved in ipairs(module.reserved or {}) do
    areas[#areas + 1] = area_rect(reserved.area)
  end
  return areas
end

local function rect_inside_work_area(box, center)
  return box.left >= center.x - PLAN_RADIUS and box.top >= center.y - PLAN_RADIUS
    and box.right <= center.x + PLAN_RADIUS and box.bottom <= center.y + PLAN_RADIUS
end

local function plan_center(s, agent)
  local center = agent.position
  if s.home and s.home.surface_index == agent.surface.index then
    center = s.home.position
  end
  return {x = center.x, y = center.y}
end

local function sorted_orientations(definition)
  local orientations = {}
  for _, orientation in ipairs(definition.geometry.supported_orientations or {}) do
    orientations[#orientations + 1] = orientation
  end
  table.sort(orientations)
  return orientations
end

-- Internal harness/request hint. The model-facing API never supplies it. It allows the
-- engine tests to exercise every advertised orientation through the same planner path.
local function orientations_for(definition, node, hints)
  local supported = sorted_orientations(definition)
  local wanted = hints and (hints[node.module_id] or hints[node.id]) or nil
  if wanted == nil then return supported end
  for _, candidate in ipairs(supported) do
    if candidate == wanted then return {wanted} end
  end
  return {}
end

local function find_port(ports, port_id)
  for _, port in ipairs(ports or {}) do
    if port.id == port_id then return port end
  end
  return nil
end

local function module_instance_key(plan_id, node_id)
  return "plan:" .. plan_id .. ":" .. node_id
end

local function plan_instance_keys(plan)
  local keys = {}
  for _, module in ipairs(plan.modules or {}) do
    keys[module_instance_key(plan.id, module.node_id)] = true
  end
  return keys
end

local function surface_entities_in_area(surface, box)
  return surface.find_entities_filtered{
    area = {{box.left, box.top}, {box.right, box.bottom}},
  }
end

local function expected_plan_entity(module, entity)
  for _, expected in ipairs(module.entities or {}) do
    if expected.name == entity.name then
      local dx = expected.position.x - entity.position.x
      local dy = expected.position.y - entity.position.y
      if dx * dx + dy * dy <= 2.25 then return true end
    end
  end
  return false
end

local function iter_entity_signature(entity, agent_unit_number, module)
  if not entity.valid then return nil end
  if entity.unit_number and entity.unit_number == agent_unit_number then return nil end
  local kind = entity.type
  if kind == "character" or kind == "item-entity" or kind == "corpse"
    or kind == "smoke" or kind == "fish" then
    return nil
  end
  -- Natural trees/rocks are recorded as clearing requirements, not stale-plan
  -- conflicts. Their later removal must not invalidate an otherwise valid plan.
  if clearing.is_clearable(entity) then return nil end
  -- A player may complete one of the plan's own ghosts. That is construction
  -- progress, not a foreign obstruction.
  if module and kind ~= "entity-ghost" and expected_plan_entity(module, entity) then
    return nil
  end
  local amount = 0
  if kind == "resource" then amount = entity.amount or 0 end
  return table.concat({
    kind, entity.name,
    tostring(math.floor(entity.position.x * 2 + 0.5)),
    tostring(math.floor(entity.position.y * 2 + 0.5)),
    tostring(entity.unit_number or 0), tostring(amount),
  }, "|")
end

-- Local world fingerprint used for stale-plan detection. It covers entities and resources
-- inside planned footprints/reserved areas, nearby electric poles and the exact positions
-- of non-agent characters within the player-work radius. The plan's own ghosts are ignored
-- so repeated apply remains idempotent.
function M.environment_signature(s, plan)
  local agent = s.agent
  local surface = game.surfaces[plan.surface_index]
  if not agent or not agent.valid or not surface then return nil end
  local agent_unit = agent.unit_number
  local keys, seen = {}, {}
  local function add(key)
    if key and not seen[key] then seen[key] = true keys[#keys + 1] = key end
  end
  for _, module in ipairs(plan.modules or {}) do
    for _, box in ipairs(module_areas(module)) do
      for _, entity in pairs(surface_entities_in_area(surface, box)) do
        if entity.valid then
          if entity.type == "entity-ghost" then
            local plan_tag = entity.tags and entity.tags.ae_plan_id or nil
            if plan_tag ~= plan.id then
              add(iter_entity_signature(entity, agent_unit, module))
            end
          else
            add(iter_entity_signature(entity, agent_unit, module))
          end
        end
      end
      local expanded = {
        left = box.left - PLAYER_SAFETY_RADIUS, top = box.top - PLAYER_SAFETY_RADIUS,
        right = box.right + PLAYER_SAFETY_RADIUS, bottom = box.bottom + PLAYER_SAFETY_RADIUS,
      }
      for _, character in pairs(surface.find_entities_filtered{
        area = {{expanded.left, expanded.top}, {expanded.right, expanded.bottom}},
        type = "character"}) do
        if character.valid and character.unit_number ~= agent_unit then
          add("player|" .. tostring(character.unit_number) .. "|"
            .. tostring(math.floor(character.position.x * 2 + 0.5)) .. "|"
            .. tostring(math.floor(character.position.y * 2 + 0.5)))
        end
      end
    end
    local bounds = area_rect(module.bounds)
    local pole_area = {
      left = bounds.left - ELECTRIC_RADIUS, top = bounds.top - ELECTRIC_RADIUS,
      right = bounds.right + ELECTRIC_RADIUS, bottom = bounds.bottom + ELECTRIC_RADIUS,
    }
    for _, pole in pairs(surface.find_entities_filtered{
      area = {{pole_area.left, pole_area.top}, {pole_area.right, pole_area.bottom}},
      type = "electric-pole"}) do
      if pole.valid and pole.electric_network_id then
        add("pole|" .. tostring(pole.unit_number) .. "|" .. pole.name)
      end
    end
  end
  table.sort(keys)
  return digest(table.concat(keys, "\n")), #keys
end

local function canonical_plan_text(plan)
  local parts = {"schema=" .. tostring(plan.schema_version), "goal=" .. plan.goal_item}
  local modules_sorted = {}
  for _, module in ipairs(plan.modules or {}) do
    modules_sorted[#modules_sorted + 1] = module
  end
  table.sort(modules_sorted, function(a, b) return a.node_id < b.node_id end)
  for _, module in ipairs(modules_sorted) do
    parts[#parts + 1] = table.concat({
      "module", module.node_id, module.module_id, tostring(module.module_version),
      tostring(module.orientation), module.anchor.x, module.anchor.y,
      sorted_parameter_string(module.parameters),
    }, "|")
  end
  local edges_sorted = {}
  for _, edge in ipairs(plan.edges or {}) do edges_sorted[#edges_sorted + 1] = edge end
  table.sort(edges_sorted, function(a, b)
    return table.concat({tostring(a.to), tostring(a.to_port), tostring(a.from),
      tostring(a.from_port), tostring(a.kind), tostring(a.item)}, "|")
      < table.concat({tostring(b.to), tostring(b.to_port), tostring(b.from),
        tostring(b.from_port), tostring(b.kind), tostring(b.item)}, "|")
  end)
  for _, edge in ipairs(edges_sorted) do
    parts[#parts + 1] = table.concat({
      "edge", tostring(edge.from), tostring(edge.from_port), tostring(edge.to),
      tostring(edge.to_port), tostring(edge.kind), tostring(edge.item),
      tostring(edge.status),
    }, "|")
  end
  return table.concat(parts, "\n")
end

local function resource_constraints(definition)
  local result = {}
  for _, constraint in ipairs(definition.placement.constraints or {}) do
    if constraint.type == "resource_patch" then result[#result + 1] = constraint end
  end
  return result
end

local function resource_candidates(surface, center, definition, orientations)
  local candidates, seen = {}, {}
  local constraints = resource_constraints(definition)
  if #constraints == 0 then return candidates end
  for _, constraint in ipairs(constraints) do
    local resources = surface.find_entities_filtered{
      area = {{center.x - PLAN_RADIUS, center.y - PLAN_RADIUS},
        {center.x + PLAN_RADIUS, center.y + PLAN_RADIUS}},
      name = constraint.resource, type = "resource",
    }
    table.sort(resources, function(a, b)
      local da, db = distance(a.position, center), distance(b.position, center)
      if math.abs(da - db) > 1e-9 then return da < db end
      if a.position.x ~= b.position.x then return a.position.x < b.position.x end
      if a.position.y ~= b.position.y then return a.position.y < b.position.y end
      return (a.unit_number or 0) < (b.unit_number or 0)
    end)
    local offsets = {
      {x = 0, y = 0}, {x = -1, y = 0}, {x = 1, y = 0}, {x = 0, y = -1},
      {x = 0, y = 1}, {x = -1, y = -1}, {x = 1, y = -1}, {x = -1, y = 1},
      {x = 1, y = 1}, {x = -2, y = 0}, {x = 2, y = 0}, {x = 0, y = -2},
      {x = 0, y = 2}, {x = -2, y = -1}, {x = 2, y = -1},
    }
    local seeds = math.min(#resources, 24)
    for index = 1, seeds do
      local resource = resources[index]
      for _, orientation in ipairs(orientations) do
        local expanded = format.expand(definition, {}, orientation)
        if expanded then
          local width, height = expanded.footprint.width, expanded.footprint.height
          local base = {
            x = math.floor(resource.position.x - width / 2),
            y = math.floor(resource.position.y - height / 2),
          }
          for _, offset in ipairs(offsets) do
            local anchor = {x = base.x + offset.x, y = base.y + offset.y}
            local key = tostring(anchor.x) .. "," .. tostring(anchor.y) .. ","
              .. tostring(orientation)
            if not seen[key] then
              seen[key] = true
              candidates[#candidates + 1] = {
                anchor = anchor, orientation = orientation,
                footprint = {width = width, height = height},
              }
            end
          end
        end
      end
    end
  end
  return candidates
end

local function ring_offsets()
  local offsets = {{x = 0, y = 0}}
  for radius = RING_STEP, MAX_RING, RING_STEP do
    local ring = {}
    for x = -radius, radius, RING_STEP do
      ring[#ring + 1] = {x = x, y = -radius}
      ring[#ring + 1] = {x = x, y = radius}
    end
    for y = -radius + RING_STEP, radius - RING_STEP, RING_STEP do
      ring[#ring + 1] = {x = -radius, y = y}
      ring[#ring + 1] = {x = radius, y = y}
    end
    table.sort(ring, function(a, b)
      local da, db = math.abs(a.x) + math.abs(a.y), math.abs(b.x) + math.abs(b.y)
      if da ~= db then return da < db end
      if a.x ~= b.x then return a.x < b.x end
      return a.y < b.y
    end)
    for _, offset in ipairs(ring) do offsets[#offsets + 1] = offset end
  end
  return offsets
end

local OFFSETS = ring_offsets()

local function local_candidates(center, focus_points, definition, orientations)
  local candidates, seen = {}, {}
  for _, focus in ipairs(focus_points) do
    for _, orientation in ipairs(orientations) do
      local expanded = format.expand(definition, {}, orientation)
      if expanded then
        local width, height = expanded.footprint.width, expanded.footprint.height
        local base = {
          x = math.floor(focus.x - width / 2),
          y = math.floor(focus.y - height / 2),
        }
        for _, offset in ipairs(OFFSETS) do
          local anchor = {x = base.x + offset.x, y = base.y + offset.y}
          local key = tostring(anchor.x) .. "," .. tostring(anchor.y) .. ","
            .. tostring(orientation)
          if not seen[key] then
            seen[key] = true
            local anchor_center = {x = anchor.x + width / 2, y = anchor.y + height / 2}
            candidates[#candidates + 1] = {
              anchor = anchor, orientation = orientation,
              footprint = {width = width, height = height},
              focus_distance = math.abs(anchor_center.x - focus.x)
                + math.abs(anchor_center.y - focus.y),
              center_distance = math.abs(anchor_center.x - center.x)
                + math.abs(anchor_center.y - center.y),
            }
          end
        end
      end
    end
  end
  return candidates
end

local function rough_sort_and_limit(candidates, center)
  for _, candidate in ipairs(candidates) do
    if not candidate.center_distance then
      local anchor_center = {
        x = candidate.anchor.x + candidate.footprint.width / 2,
        y = candidate.anchor.y + candidate.footprint.height / 2,
      }
      candidate.center_distance = math.abs(anchor_center.x - center.x)
        + math.abs(anchor_center.y - center.y)
      candidate.focus_distance = candidate.center_distance
    end
  end
  table.sort(candidates, function(a, b)
    local sa = (a.focus_distance or 0) * 4 + (a.center_distance or 0)
    local sb = (b.focus_distance or 0) * 4 + (b.center_distance or 0)
    if sa ~= sb then return sa < sb end
    if a.orientation ~= b.orientation then return a.orientation < b.orientation end
    if a.anchor.x ~= b.anchor.x then return a.anchor.x < b.anchor.x end
    return a.anchor.y < b.anchor.y
  end)
  while #candidates > MAX_CANDIDATES_PER_MODULE do table.remove(candidates) end
  return candidates
end

local function connection_terms(node, resolved, graph, placed_by_node)
  local minimum, total = nil, 0
  for _, edge in ipairs(graph.edges) do
    if edge.to == node.id and placed_by_node[edge.from] then
      local supplier = placed_by_node[edge.from]
      local from_port = find_port(supplier.ports, edge.from_port)
      local to_port = find_port(resolved.ports, edge.to_port)
      if from_port and to_port then
        local value = math.abs(from_port.position.x - to_port.position.x)
          + math.abs(from_port.position.y - to_port.position.y)
        total = total + value
        if not minimum or value < minimum then minimum = value end
      end
    end
  end
  return minimum or 0, total
end

local function crowding_near(surface, box)
  local expanded = {
    left = box.left - EXPANSION_MARGIN, top = box.top - EXPANSION_MARGIN,
    right = box.right + EXPANSION_MARGIN, bottom = box.bottom + EXPANSION_MARGIN,
  }
  local count = 0
  for _, entity in pairs(surface.find_entities_filtered{
    area = {{expanded.left, expanded.top}, {expanded.right, expanded.bottom}}}) do
    if entity.valid then
      local kind = entity.type
      if kind ~= "resource" and kind ~= "entity-ghost" and kind ~= "tile-ghost"
        and kind ~= "character" and kind ~= "item-entity" and kind ~= "corpse"
        and kind ~= "smoke" and kind ~= "fish" then
        count = count + 1
      end
    end
  end
  return count
end

local function infrastructure_near(surface, box)
  local count = 0
  for _, pole in pairs(surface.find_entities_filtered{
    area = {{box.left - INFRASTRUCTURE_RADIUS, box.top - INFRASTRUCTURE_RADIUS},
      {box.right + INFRASTRUCTURE_RADIUS, box.bottom + INFRASTRUCTURE_RADIUS}},
    type = "electric-pole"}) do
    if pole.valid and pole.electric_network_id then count = count + 1 end
  end
  return count
end

local function nearby_players(agent, surface, box)
  local expanded = {
    left = box.left - PLAYER_SAFETY_RADIUS, top = box.top - PLAYER_SAFETY_RADIUS,
    right = box.right + PLAYER_SAFETY_RADIUS, bottom = box.bottom + PLAYER_SAFETY_RADIUS,
  }
  local players = {}
  for _, character in pairs(surface.find_entities_filtered{
    area = {{expanded.left, expanded.top}, {expanded.right, expanded.bottom}},
    type = "character"}) do
    if character.valid and character.unit_number ~= agent.unit_number then
      players[#players + 1] = character
    end
  end
  return players
end

local function candidate_better(a, b)
  if a.score ~= b.score then return a.score < b.score end
  local ta, tb = a.terms, b.terms
  if ta.connection_distance ~= tb.connection_distance then
    return ta.connection_distance < tb.connection_distance
  end
  if ta.center_distance ~= tb.center_distance then
    return ta.center_distance < tb.center_distance
  end
  if ta.clearing_count ~= tb.clearing_count then
    return ta.clearing_count < tb.clearing_count
  end
  if ta.infrastructure ~= tb.infrastructure then
    return ta.infrastructure > tb.infrastructure
  end
  if a.orientation ~= b.orientation then return a.orientation < b.orientation end
  if a.anchor.x ~= b.anchor.x then return a.anchor.x < b.anchor.x end
  if a.anchor.y ~= b.anchor.y then return a.anchor.y < b.anchor.y end
  return a.node_id < b.node_id
end

local function evaluate_candidate(s, definition, node, candidate, graph, center,
                                  placed_by_node, occupied)
  local agent = s.agent
  local surface = agent.surface
  local evaluated = module_placer.evaluate(s, {
    definition = definition, module_id = node.module_id,
    anchor = candidate.anchor, orientation = candidate.orientation, parameters = {},
  })
  if not evaluated.ok then return nil, evaluated.reason end
  local resolved = evaluated.resolved
  local bounds_box = area_rect(resolved.absolute_bounds)
  if not rect_inside_work_area(bounds_box, center) then return nil, "outside_work_area" end
  for _, reserved in ipairs(resolved.reserved) do
    local box = area_rect(reserved.area)
    if not rect_inside_work_area(box, center) then return nil, "outside_work_area" end
  end
  local players = nearby_players(agent, surface, bounds_box)
  if #players > 0 then return nil, "player_working_nearby" end
  for _, other in ipairs(occupied) do
    -- Keep one tile of clearance. The Stage-4 instantiator treats a half-tile padded
    -- instance footprint as overlapping, so adjacent modules must not merely touch.
    local other_box = expand_rect(other.box, PLANNING_GAP)
    if rects_overlap(other_box, bounds_box) then return nil, "planned_module_overlap" end
    for _, reserved in ipairs(resolved.reserved) do
      local box = area_rect(reserved.area)
      if rects_overlap(other_box, box) then return nil, "planned_reserved_overlap" end
      for _, adjacent in ipairs(other.areas or {}) do
        if rects_overlap(expand_rect(adjacent, PLANNING_GAP), box) then
          return nil, "planned_reserved_overlap"
        end
      end
    end
    for _, adjacent in ipairs(other.areas or {}) do
      if rects_overlap(expand_rect(adjacent, PLANNING_GAP), bounds_box) then
        return nil, "planned_reserved_overlap"
      end
    end
  end
  local connection, total = connection_terms(node, resolved, graph, placed_by_node)
  local clearing = #evaluated.clearable
  local crowding = crowding_near(surface, bounds_box)
  local infrastructure = infrastructure_near(surface, bounds_box)
  local anchor_center = {
    x = candidate.anchor.x + resolved.footprint.width / 2,
    y = candidate.anchor.y + resolved.footprint.height / 2,
  }
  local center_distance = math.abs(anchor_center.x - center.x)
    + math.abs(anchor_center.y - center.y)
  local player_penalty = 0
  local nearest_player = nil
  for _, character in ipairs(players) do
    local point_distance = point_rect_distance(character.position, bounds_box)
    if not nearest_player or point_distance < nearest_player then nearest_player = point_distance end
  end
  if nearest_player then
    player_penalty = math.max(0, 32 - nearest_player) * M.SCORING.nearby_player
  end
  local terms = {
    connection_distance = connection, connection_total = total,
    center_distance = center_distance, clearing_count = clearing,
    crowding = crowding, infrastructure = infrastructure,
    nearby_player = player_penalty,
  }
  local score = connection * M.SCORING.connection_distance
    + center_distance * M.SCORING.center_distance
    + clearing * M.SCORING.clearing_obstacle
    + crowding * M.SCORING.crowding_obstacle
    + player_penalty
    - infrastructure * M.SCORING.infrastructure_pole_bonus
  return {
    node_id = node.id, anchor = {x = candidate.anchor.x, y = candidate.anchor.y},
    orientation = candidate.orientation, resolved = resolved,
    clearable = evaluated.clearable, score = score, terms = terms,
  }
end

local function build_module_record(node, choice)
  local resolved = choice.resolved
  local clearable_names = {}
  for _, entity in ipairs(choice.clearable) do
    clearable_names[entity.name] = (clearable_names[entity.name] or 0) + 1
  end
  return {
    node_id = node.id, module_id = node.module_id,
    module_version = node.module_version, name = node.name, category = node.category,
    recipe = node.recipe, parameters = resolved.parameters,
    orientation = choice.orientation, anchor = choice.anchor,
    footprint = resolved.footprint, bounds = resolved.absolute_bounds,
    reserved = resolved.reserved, ports = resolved.ports, entities = resolved.entities,
    cost_estimate = resolved.cost_estimate,
    placement_status = "valid", needs_clearing = #choice.clearable > 0,
    clearable = clearable_names, score = choice.score, score_terms = choice.terms,
  }
end

local function build_edges(graph, placed_by_node)
  local edges = {}
  for _, edge in ipairs(graph.edges) do
    local record = {}
    for field, value in pairs(edge) do record[field] = value end
    record.compatible = edge.status == "route_required"
      or edge.status == "externally_supplied"
    record.physical_connection = false
    if edge.kind == "electric" then
      local to_module = placed_by_node[edge.to]
      local port = to_module and find_port(to_module.ports, edge.to_port) or nil
      record.to_position = port and port.position or nil
      record.routing_required = false
      if not to_module and record.status ~= "externally_supplied" then
        record.status = "blocked"
        record.reason = "module_instance_unplaced"
      end
    elseif edge.to == "requested_output" then
      local from_module = placed_by_node[edge.from]
      local port = from_module and find_port(from_module.ports, edge.from_port) or nil
      record.from_position = port and port.position or nil
      record.routing_required = false
      if not from_module then
        record.status = "blocked"
        record.reason = "module_instance_unplaced"
      end
    elseif edge.from:sub(1, 8) ~= "missing:"
      and (not placed_by_node[edge.from] or not placed_by_node[edge.to]) then
      record.status = "blocked"
      record.reason = "module_instance_unplaced"
      record.routing_required = false
    elseif placed_by_node[edge.from] and placed_by_node[edge.to] then
      local from_module = placed_by_node[edge.from]
      local to_module = placed_by_node[edge.to]
      local from_port = find_port(from_module.ports, edge.from_port)
      local to_port = find_port(to_module.ports, edge.to_port)
      if from_port and to_port then
        record.from_position = from_port.position
        record.to_position = to_port.position
        record.distance = math.abs(from_port.position.x - to_port.position.x)
          + math.abs(from_port.position.y - to_port.position.y)
        record.routing_required = true
      else
        record.status = "unsupported"
        record.reason = "declared_port_not_found"
      end
    end
    edges[#edges + 1] = record
  end
  table.sort(edges, function(a, b)
    return table.concat({tostring(a.to), tostring(a.to_port), tostring(a.from),
      tostring(a.from_port), tostring(a.kind), tostring(a.item)}, "|")
      < table.concat({tostring(b.to), tostring(b.to_port), tostring(b.from),
        tostring(b.from_port), tostring(b.kind), tostring(b.item)}, "|")
  end)
  return edges
end

local function connection_counts(edges)
  local counts = {
    compatible = 0, route_required = 0, externally_supplied = 0,
    missing_supplier = 0, unsupported = 0, blocked = 0, requested_output = 0,
  }
  for _, edge in ipairs(edges) do
    if counts[edge.status] then
      counts[edge.status] = counts[edge.status] + 1
    else
      counts.unsupported = counts.unsupported + 1
    end
  end
  return counts
end

local function build_external_dependencies(graph)
  local result = {}
  for _, record in ipairs(graph.external_dependencies or {}) do
    result[#result + 1] = {
      kind = record.kind, item = record.item, node_id = record.node_id,
      port_id = record.port_id, external = record.external == true,
      message = record.message,
    }
  end
  table.sort(result, function(a, b)
    if a.kind ~= b.kind then return tostring(a.kind) < tostring(b.kind) end
    if tostring(a.item) ~= tostring(b.item) then
      return tostring(a.item) < tostring(b.item)
    end
    return tostring(a.node_id) < tostring(b.node_id)
  end)
  return result
end

local function store_plan(s, plan)
  s.layout_plans = s.layout_plans or {by_id = {}, order = {}, next_plan_number = 0}
  local existing = s.layout_plans.by_id[plan.id]
  if existing then return existing, true end
  s.layout_plans.by_id[plan.id] = plan
  s.layout_plans.order[#s.layout_plans.order + 1] = plan.id
  while #s.layout_plans.order > MAX_STORED_PLANS do
    local oldest = table.remove(s.layout_plans.order, 1)
    s.layout_plans.by_id[oldest] = nil
  end
  return plan, false
end

function M.create(s, p)
  local agent = s.agent
  assert(agent and agent.valid, "Agent is not alive")
  assert(not (s.safety and s.safety.active), "Safety controller is active")
  assert(type(p.goal_item) == "string" and p.goal_item ~= "",
    "goal_item must be a non-empty string")
  local surface = agent.surface
  local center = plan_center(s, agent)
  local context = strategy.context(s)
  local env = {
    prototypes = prototypes, force = agent.force, surface = surface,
    stage = context.stage.id,
  }
  local graph, error_record = production_graph.resolve(env, p.goal_item)
  if not graph then
    return {ok = false, reason = error_record and error_record.code or "goal_unresolved",
      message = error_record and error_record.message or nil}
  end
  -- Reuse a still-valid persisted plan for the same goal. This keeps plan_layout
  -- idempotent after apply: the plan's own ghosts and expected real entities are ignored by
  -- revalidation, so repeating the request returns the same plan instead of replanning
  -- around its own construction.
  if not p.force_new then
    local candidates = {}
    for _, existing in pairs(s.layout_plans and s.layout_plans.by_id or {}) do
      if existing.goal_item == p.goal_item and existing.materializable then
        candidates[#candidates + 1] = existing
      end
    end
    table.sort(candidates, function(a, b)
      if a.created_tick ~= b.created_tick then return a.created_tick > b.created_tick end
      return a.id < b.id
    end)
    for _, existing in ipairs(candidates) do
      local revalidation = M.revalidate(s, existing)
      if revalidation.valid then return {ok = true, plan = existing, reused = true} end
    end
  end

  local catalog = modules.load(env)
  local definitions = {}
  for _, summary in ipairs(catalog.modules) do
    definitions[summary.id] = catalog.by_id[summary.id].definition
  end

  local order = {}
  local seen_order = {}
  for _, node_id in ipairs(graph.order) do
    if not seen_order[node_id] then seen_order[node_id] = true order[#order + 1] = node_id end
  end
  for _, node in ipairs(graph.nodes) do
    if not seen_order[node.id] then seen_order[node.id] = true order[#order + 1] = node.id end
  end

  local placed_by_node, occupied, modules_plan = {}, {}, {}
  local unplaced = {}
  for _, node_id in ipairs(order) do
    local node = nil
    for _, candidate in ipairs(graph.nodes) do
      if candidate.id == node_id then node = candidate break end
    end
    local definition = node and definitions[node.module_id] or nil
    if not node or not definition then
      unplaced[#unplaced + 1] = {node_id = node_id, reason = "module_definition_missing"}
    elseif node.unsupported then
      unplaced[#unplaced + 1] = {node_id = node_id, reason = node.unsupported}
    else
      local orientations = orientations_for(definition, node, p.orientation_hints)
      local focus_points = {{x = center.x, y = center.y}}
      for _, edge in ipairs(graph.edges) do
        if edge.to == node.id and placed_by_node[edge.from] then
          local port = find_port(placed_by_node[edge.from].ports, edge.from_port)
          if port then focus_points[#focus_points + 1] = port.position end
        end
      end
      local candidates
      if #resource_constraints(definition) > 0 then
        -- A resource-constrained module cannot be validly placed on generic
        -- center-proximate anchors. Mixing them would let a bound limit crowd out the
        -- only candidates that can satisfy the constraint.
        candidates = resource_candidates(surface, center, definition, orientations)
      else
        candidates = local_candidates(center, focus_points, definition, orientations)
      end
      rough_sort_and_limit(candidates, center)
      local best = nil
      local last_reason = "no_candidate"
      for _, candidate in ipairs(candidates) do
        local choice, reason = evaluate_candidate(
          s, definition, node, candidate, graph, center, placed_by_node, occupied)
        if choice then
          if not best or candidate_better(choice, best) then best = choice end
        elseif reason then
          last_reason = reason
        end
      end
      if best then
        local record = build_module_record(node, best)
        record.instance_key = module_instance_key("pending", node.id)
        placed_by_node[node.id] = record
        modules_plan[#modules_plan + 1] = record
        occupied[#occupied + 1] = {
          box = area_rect(record.bounds),
          areas = (function()
            local areas = {}
            for _, reserved in ipairs(record.reserved) do
              areas[#areas + 1] = area_rect(reserved.area)
            end
            return areas
          end)(),
          node_id = node.id,
        }
      else
        unplaced[#unplaced + 1] = {node_id = node.id, reason = last_reason}
      end
    end
  end

  local bounds_by_node = {}
  for node_id, module in pairs(placed_by_node) do
    bounds_by_node[node_id] = module.bounds
  end
  local infrastructure = production_graph.evaluate_infrastructure(graph, {
    surface = surface, bounds_by_node = bounds_by_node, radius = ELECTRIC_RADIUS,
  })
  local edges = build_edges(graph, placed_by_node)

  local clearing_modules, clearing_counts = 0, {}
  for _, module in ipairs(modules_plan) do
    if module.needs_clearing then
      clearing_modules = clearing_modules + 1
      for name, count in pairs(module.clearable) do
        clearing_counts[name] = (clearing_counts[name] or 0) + count
      end
    end
  end

  local external = build_external_dependencies(graph)
  local placement_valid = #unplaced == 0
  local needs_clearing = clearing_modules > 0
  local status
  if not placement_valid then
    status = "invalid"
  elseif #external > 0 or needs_clearing then
    status = "partial"
  else
    local blocking_missing = false
    for _, record in ipairs(graph.missing or {}) do
      if record.external ~= true then blocking_missing = true break end
    end
    status = blocking_missing and "partial" or "complete"
  end
  local placement_status = "invalid"
  if placement_valid then
    placement_status = needs_clearing and "requires_clearing" or "valid"
  end

  local plan = {
    schema_version = M.SCHEMA_VERSION, goal_item = p.goal_item,
    surface_index = surface.index, surface_name = surface.name,
    center = center, radius = PLAN_RADIUS,
    created_tick = game.tick,
    status = status, placement_status = placement_status,
    materializable = placement_valid,
    unplaced = unplaced,
    modules = modules_plan, order = order, edges = edges,
    connection_counts = connection_counts(edges),
    external_dependencies = external,
    graph_status = graph.status,
    available_modules = graph.available_modules,
    selected_modules = graph.selected_modules,
    consumers = graph.consumers, producers = graph.producers,
    infrastructure = infrastructure,
    clearing = {modules = clearing_modules, obstacles = clearing_counts},
    throughput_analysis = graph.throughput_analysis,
    application = {status = "not_applied", instances = {}, attempts = 0},
    notes = {
      "A layout plan is not an operational factory.",
      "Item and fluid connections still require physical belt/pipe routing.",
      "Electric network presence does not prove physical wire coverage.",
      "Furnace fuel supply is not provided by the current module catalog.",
    },
  }
  plan.fingerprint = digest(canonical_plan_text(plan))
  local environment_signature = M.environment_signature(s, plan)
  plan.environment_signature = environment_signature
  plan.id = "plan_" .. digest(plan.fingerprint .. "|" .. tostring(environment_signature)):sub(1, 16)
  for _, module in ipairs(plan.modules) do
    module.instance_key = module_instance_key(plan.id, module.node_id)
  end
  local stored, reused = store_plan(s, plan)
  if reused then return {ok = true, plan = stored, reused = true} end
  return {ok = true, plan = stored, reused = false}
end

function M.revalidate(s, plan)
  local agent = s.agent
  local surface = game.surfaces[plan.surface_index]
  local problems = {}
  if not agent or not agent.valid then
    problems[#problems + 1] = "agent_unavailable"
  end
  if not surface or (agent and agent.surface ~= surface) then
    problems[#problems + 1] = "surface_unavailable"
  end
  if not plan.materializable or #plan.unplaced > 0 then
    problems[#problems + 1] = "plan_invalid"
  end
  if #problems > 0 then
    return {valid = false, stale = false, reasons = problems}
  end
  local signature, signature_count = M.environment_signature(s, plan)
  if signature ~= plan.environment_signature then
    problems[#problems + 1] = "world_changed"
  end
  local ignored_keys = plan_instance_keys(plan)
  local context = strategy.context(s)
  local env = {
    prototypes = prototypes, force = agent.force, surface = surface,
    stage = context.stage.id,
  }
  local catalog = modules.load(env)
  for _, module in ipairs(plan.modules) do
    local recorded = plan.application.instances[module.node_id]
    local entry = catalog.by_id[module.module_id]
    if recorded then
      -- The plan already owns a module instance for this node. Its live status is
      -- reconciled during apply; a player-built expected entity is not a foreign blocker.
    elseif not entry then
      problems[#problems + 1] = "module_no_longer_available:" .. module.module_id
    elseif not entry.availability.available then
      problems[#problems + 1] = "module_unavailable:" .. module.module_id
    else
      local evaluated = module_placer.evaluate(s, {
        definition = entry.definition, module_id = module.module_id,
        anchor = module.anchor, orientation = module.orientation,
        parameters = module.parameters, ignore_plan_id = plan.id,
        ignore_instance_keys = ignored_keys,
      })
      if not evaluated.ok then
        problems[#problems + 1] = "placement_invalid:" .. module.node_id .. ":"
          .. tostring(evaluated.reason)
      end
    end
  end
  local unique, seen = {}, {}
  for _, reason in ipairs(problems) do
    if not seen[reason] then seen[reason] = true unique[#unique + 1] = reason end
  end
  return {valid = #unique == 0, stale = #unique > 0,
    reasons = unique, signature = signature, signature_count = signature_count}
end

function M.apply(s, p)
  local agent = s.agent
  assert(agent and agent.valid, "Agent is not alive")
  assert(not (s.safety and s.safety.active), "Safety controller is active")
  assert(type(p.plan_id) == "string" and p.plan_id ~= "", "plan_id is required")
  local plans = s.layout_plans and s.layout_plans.by_id or {}
  local plan = plans[p.plan_id]
  if not plan then
    return {ok = false, status = "unknown_plan", plan_id = p.plan_id}
  end
  local revalidation = M.revalidate(s, plan)
  plan.application.attempts = (plan.application.attempts or 0) + 1
  plan.application.last_attempt_tick = game.tick
  if not revalidation.valid then
    plan.application.status = "stale"
    plan.application.last_reasons = revalidation.reasons
    return {ok = false, status = "stale_plan", plan_id = plan.id,
      reasons = revalidation.reasons, fingerprint = plan.fingerprint,
      environment_signature = plan.environment_signature,
      current_signature = revalidation.signature}
  end
  local created, already, failed, cancelled = {}, {}, {}, {}
  for _, module in ipairs(plan.modules) do
    local recorded = plan.application.instances[module.node_id]
    local key = module.instance_key or module_instance_key(plan.id, module.node_id)
    if recorded then
      local status = module_placer.instance_status(s, recorded.instance_key)
      if status and status.status ~= "missing" then
        already[#already + 1] = {node_id = module.node_id, module_id = module.module_id,
          status = status.status}
      elseif status then
        cancelled[#cancelled + 1] = {node_id = module.node_id, reason = "ghosts_removed"}
      else
        cancelled[#cancelled + 1] = {node_id = module.node_id, reason = "instance_missing"}
      end
    else
      local result, reason, details = module_placer.instantiate(s, {
        module_id = module.module_id, anchor = module.anchor,
        orientation = module.orientation, parameters = module.parameters,
        instance_key = key, plan_id = plan.id, stage = strategy.context(s).stage.id,
      })
      if result and result.instance then
        local units = {}
        for _, entity in ipairs(result.instance.entities or {}) do
          units[#units + 1] = entity.unit_number
        end
        plan.application.instances[module.node_id] = {
          instance_key = key, module_id = module.module_id,
          ghost_units = units, ghost_count = #units,
          status = result.instance.status, created_tick = game.tick,
        }
        created[#created + 1] = {node_id = module.node_id, module_id = module.module_id,
          ghost_count = #units, deduplicated = result.deduplicated}
      else
        failed[#failed + 1] = {node_id = module.node_id, module_id = module.module_id,
          reason = reason or "instantiate_failed", details = details}
      end
    end
  end
  local status
  if #failed > 0 or #cancelled > 0 then
    status = "partially_applied"
  elseif #created > 0 then
    status = "applied"
  else
    status = "already_applied"
  end
  plan.application.status = status
  plan.application.last_applied_tick = game.tick
  plan.application.created = created
  plan.application.already = already
  plan.application.failed = failed
  plan.application.cancelled = cancelled
  return {
    ok = #failed == 0 and #cancelled == 0,
    status = status, plan_id = plan.id, goal_item = plan.goal_item,
    fingerprint = plan.fingerprint,
    created = created, already_applied = already, failed = failed,
    cancelled = cancelled,
    world_changed = false,
    materializable = plan.materializable,
    notes = plan.notes,
  }
end

function M.public_summary(plan)
  if not plan then return {ok = false, status = "unknown_plan"} end
  local modules_summary = {}
  for _, module in ipairs(plan.modules) do
    modules_summary[#modules_summary + 1] = {
      instance_id = module.node_id, module_id = module.module_id,
      name = module.name, category = module.category,
      parameters = module.parameters, recipe = module.recipe,
      placement_status = module.placement_status,
      needs_clearing = module.needs_clearing,
    }
  end
  local unresolved = {}
  for _, record in ipairs(plan.external_dependencies or {}) do
    unresolved[#unresolved + 1] = {
      kind = record.kind, item = record.item, module_instance = record.node_id,
      message = record.message,
    }
  end
  local infrastructure = {}
  for _, record in ipairs(plan.external_dependencies or {}) do
    if record.kind == "infrastructure" then
      infrastructure[#infrastructure + 1] = "electric_network"
    end
  end
  local clearing_obstacles = {}
  for name, count in pairs(plan.clearing.obstacles or {}) do
    clearing_obstacles[name] = count
  end
  return {
    ok = true, plan_id = plan.id, goal_item = plan.goal_item,
    fingerprint = plan.fingerprint,
    plan_status = plan.status, placement_status = plan.placement_status,
    materializable = plan.materializable,
    application_status = plan.application.status,
    modules = modules_summary,
    available_modules = plan.available_modules,
    selected_module_count = #plan.modules,
    resolved_module_count = #plan.order,
    connections = plan.connection_counts,
    unresolved_dependencies = unresolved,
    external_infrastructure = infrastructure,
    clearing = {modules_requiring_clearing = plan.clearing.modules,
      obstacles = clearing_obstacles},
    throughput_analysis = plan.throughput_analysis,
    world_changed = false,
    notes = plan.notes,
  }
end

function M.public_apply_summary(result)
  if not result then return {ok = false, status = "unknown"} end
  return {
    ok = result.ok == true, status = result.status, plan_id = result.plan_id,
    goal_item = result.goal_item, fingerprint = result.fingerprint,
    created_module_count = #(result.created or {}),
    already_applied_module_count = #(result.already_applied or {}),
    failed_module_count = #(result.failed or {}),
    cancelled_module_count = #(result.cancelled or {}),
    stale = result.status == "stale_plan",
    stale_reasons = result.reasons,
    world_changed = result.status == "stale_plan",
    materializable = result.materializable,
    notes = result.notes or {
      "Only entity ghosts were requested; paid construction remains assist_construction.",
    },
  }
end

function M.status(s, plan_id)
  local plan = s.layout_plans and s.layout_plans.by_id and s.layout_plans.by_id[plan_id]
  if not plan then return {ok = false, reason = "unknown_plan"} end
  return {ok = true, plan = plan}
end

function M.plans(s)
  local result = {}
  for _, plan in pairs(s.layout_plans and s.layout_plans.by_id or {}) do
    result[#result + 1] = {
      plan_id = plan.id, goal_item = plan.goal_item, status = plan.status,
      placement_status = plan.placement_status, application_status = plan.application.status,
      fingerprint = plan.fingerprint, created_tick = plan.created_tick,
    }
  end
  table.sort(result, function(a, b) return a.plan_id < b.plan_id end)
  return result
end

function M.limits()
  return {
    plan_radius = PLAN_RADIUS, player_safety_radius = PLAYER_SAFETY_RADIUS,
    max_candidates_per_module = MAX_CANDIDATES_PER_MODULE,
    max_stored_plans = MAX_STORED_PLANS,
    scoring = M.SCORING, tie_break_order = M.TIE_BREAK_ORDER,
  }
end

return M
