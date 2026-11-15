-- Deterministic transport primitives for Stage 7.
--
-- This module owns the physical geometry and read-only verification rules for ordinary
-- belts, splitters and underground belt pairs. It creates no entity, spends no item and
-- never mutates a LuaTransportLine. Actual construction still happens through ordinary
-- entity-ghosts revived by the paid Stage-3 executor.
--
-- Geometry was verified against Factorio 2.1.24 in the engine:
--   * splitter collision box is 2x1 across the flow direction (1x2 when facing east/west);
--   * a splitter has two input belt connectors on its back side and two output connectors
--     on its front side;
--   * underground-belt prototypes expose `max_underground_distance`;
--   * `belt_neighbours` reports ordinary belt-connectable inputs/outputs, while the other
--     end of an underground pair is exposed only through `underground_belt_neighbour`.
local M = {}

M.DIR = {north = 0, east = 4, south = 8, west = 12}
M.VEC = {
  [0] = {dx = 0, dy = -1},
  [4] = {dx = 1, dy = 0},
  [8] = {dx = 0, dy = 1},
  [12] = {dx = -1, dy = 0},
}
M.OPPOSITE = {[0] = 8, [4] = 12, [8] = 0, [12] = 4}
M.NEIGHBOURS = {{0, -1}, {1, 0}, {0, 1}, {-1, 0}}

local MAX_NODES = 4096
local MAX_LENGTH = 128

local function tile_key(tile)
  return tostring(tile.x) .. "," .. tostring(tile.y)
end

local function copy_tile(tile)
  return {x = tile.x, y = tile.y}
end

local function tile_center(tile)
  return {x = tile.x + 0.5, y = tile.y + 0.5}
end

local function add(tile, direction, count)
  local vector = M.VEC[direction]
  return {x = tile.x + vector.dx * (count or 1), y = tile.y + vector.dy * (count or 1)}
end

local function direction_between(a, b)
  if b.x > a.x then return M.DIR.east end
  if b.x < a.x then return M.DIR.west end
  if b.y > a.y then return M.DIR.south end
  return M.DIR.north
end

local function sorted_keys(value)
  local keys = {}
  for key in pairs(value or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
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

local function entity_position(name, anchor, direction)
  local prototype = prototypes.entity[name]
  local box = prototype and prototype.collision_box
  if not box then return tile_center(anchor) end
  local width = box.right_bottom.x - box.left_top.x
  local height = box.right_bottom.y - box.left_top.y
  local footprint = {width = math.ceil(width - 1e-6), height = math.ceil(height - 1e-6)}
  if direction == M.DIR.east or direction == M.DIR.west then
    footprint = {width = footprint.height, height = footprint.width}
  end
  return {
    x = anchor.x + footprint.width / 2,
    y = anchor.y + footprint.height / 2,
  }, footprint
end

-- Splitter geometry for a top-left tile anchor. The 2x1/1x2 footprint rotates with the
-- flow direction. Inputs are on the back side and outputs on the front side.
function M.splitter_geometry(anchor, direction)
  local position, footprint = entity_position("splitter", anchor, direction)
  local inputs, outputs = {}, {}
  if direction == M.DIR.east then
    inputs = {{x = anchor.x - 1, y = anchor.y},
      {x = anchor.x - 1, y = anchor.y + 1}}
    outputs = {{x = anchor.x + 1, y = anchor.y},
      {x = anchor.x + 1, y = anchor.y + 1}}
  elseif direction == M.DIR.west then
    inputs = {{x = anchor.x + 1, y = anchor.y},
      {x = anchor.x + 1, y = anchor.y + 1}}
    outputs = {{x = anchor.x - 1, y = anchor.y},
      {x = anchor.x - 1, y = anchor.y + 1}}
  elseif direction == M.DIR.north then
    inputs = {{x = anchor.x, y = anchor.y + 1},
      {x = anchor.x + 1, y = anchor.y + 1}}
    outputs = {{x = anchor.x, y = anchor.y - 1},
      {x = anchor.x + 1, y = anchor.y - 1}}
  elseif direction == M.DIR.south then
    inputs = {{x = anchor.x, y = anchor.y - 1},
      {x = anchor.x + 1, y = anchor.y - 1}}
    outputs = {{x = anchor.x, y = anchor.y + 1},
      {x = anchor.x + 1, y = anchor.y + 1}}
  end
  return {
    anchor = copy_tile(anchor), direction = direction, position = position,
    footprint = footprint,
    tiles = (direction == M.DIR.east or direction == M.DIR.west)
      and {{x = anchor.x, y = anchor.y}, {x = anchor.x, y = anchor.y + 1}}
      or {{x = anchor.x, y = anchor.y}, {x = anchor.x + 1, y = anchor.y}},
    inputs = inputs, outputs = outputs,
  }
end

function M.splitter_record(name, anchor, direction, role, junction_id)
  local geometry = M.splitter_geometry(anchor, direction)
  return {
    name = name, role = role or "splitter", junction_id = junction_id,
    anchor = geometry.anchor, tile = geometry.anchor, direction = direction,
    position = geometry.position, footprint = geometry.footprint,
    tiles = geometry.tiles, inputs = geometry.inputs, outputs = geometry.outputs,
    status = "planned", ghost_unit = nil, built_unit = nil,
  }
end

function M.underground_max_distance(name)
  local prototype = prototypes.entity[name]
  if not prototype then return nil end
  local ok, value = pcall(function() return prototype.max_underground_distance end)
  if ok and type(value) == "number" then return value end
  return nil
end

-- Build the two endpoint records of an ordinary underground pair. ``direction`` is the
-- travel direction of the belt; both endpoints expose that same direction to the engine.
-- The exit ghost is intentionally created with the opposite direction because Factorio
-- 2.1.24 uses that build hint to mark the endpoint as an output; the paid executor then
-- reasserts the true travel direction after both endpoints exist.
function M.underground_pair(name, entrance_tile, direction, distance, role)
  local max_distance = M.underground_max_distance(name)
  if not max_distance then return nil, "underground_prototype_missing" end
  if type(distance) ~= "number" or distance < 1 then
    return nil, "underground_distance_invalid"
  end
  if distance > max_distance then return nil, "underground_distance_exceeded" end
  local exit_tile = add(entrance_tile, direction, distance)
  local pair_id = "ug_" .. digest(tostring(name) .. "|" .. tostring(entrance_tile.x) .. ","
    .. tostring(entrance_tile.y) .. "|" .. tostring(direction) .. "|"
    .. tostring(distance)):sub(1, 12)
  local entrance = {
    name = name, role = role or "underground", side = "entrance",
    pair_id = pair_id, tile = copy_tile(entrance_tile),
    position = tile_center(entrance_tile), direction = direction,
    other_tile = copy_tile(exit_tile), distance = distance, status = "planned",
  }
  local exit = {
    name = name, role = role or "underground", side = "exit",
    pair_id = pair_id, tile = copy_tile(exit_tile),
    position = tile_center(exit_tile), direction = direction,
    build_direction = M.OPPOSITE[direction] or direction,
    other_tile = copy_tile(entrance_tile), distance = distance, status = "planned",
  }
  return {id = pair_id, name = name, direction = direction, distance = distance,
    max_distance = max_distance, entrance = entrance, exit = exit}
end

function M.direction_between(a, b)
  return direction_between(a, b)
end

function M.tile_key(tile)
  return tile_key(tile)
end

function M.copy_tile(tile)
  return copy_tile(tile)
end

function M.tile_center(tile)
  return tile_center(tile)
end

-- Deterministic cardinal A* with optional underground shortcuts. A shortcut step jumps
-- from the current tile to a straight-line exit tile; intermediate tiles are passed
-- underneath and may only be blocked by transport entities approved by ``under_ok``.
-- Ordinary steps cost one tile; a shortcut costs one extra tile plus its length so the
-- router prefers surface routes when both are possible.
function M.search_steps(blocked, start, goal, options)
  options = options or {}
  local max_nodes = options.max_nodes or MAX_NODES
  local max_length = options.max_length or MAX_LENGTH
  local allow = options.allow or {}
  local under_ok = options.under_ok
  local under_name = options.underground_name
  local max_under = options.max_underground_distance
  if under_name and not max_under then max_under = M.underground_max_distance(under_name) end

  local function passable(tile)
    local key = tile_key(tile)
    if allow[key] then return true end
    return not blocked[key]
  end

  if not passable(start) then return nil, "route_start_blocked" end
  if not passable(goal) then return nil, "route_goal_blocked" end
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
      if best_value == nil or value < best_value
        or (value == best_value and (tile.x < best_tile.x
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
        local parent_record = parent[tile_key(cursor)]
        cursor = parent_record and parent_record.tile or nil
      end
      return path, nil
    end
    closed[current_key] = true
    visited = visited + 1
    if visited > max_nodes then return nil, "route_search_budget_exceeded" end
    local current_g = g[current_key]
    for _, offset in ipairs(M.NEIGHBOURS) do
      local next_tile = {x = current.x + offset[1], y = current.y + offset[2]}
      local next_key = tile_key(next_tile)
      if not closed[next_key] and passable(next_tile) then
        local tentative = current_g + 1
        if tentative <= max_length and (g[next_key] == nil or tentative < g[next_key]) then
          parent[next_key] = {tile = current, kind = "belt"}
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
    if under_ok and under_name and max_under then
      for _, direction in ipairs({0, 4, 8, 12}) do
        local vector = M.VEC[direction]
        for distance = 2, max_under do
          local exit_tile = {
            x = current.x + vector.dx * distance,
            y = current.y + vector.dy * distance,
          }
          local exit_key = tile_key(exit_tile)
          if not closed[exit_key] and passable(exit_tile)
            and under_ok(current, exit_tile, direction, distance) then
            local tentative = current_g + 2 + distance
            if tentative <= max_length
              and (g[exit_key] == nil or tentative < g[exit_key]) then
              parent[exit_key] = {tile = current, kind = "underground",
                direction = direction, distance = distance}
              g[exit_key] = tentative
              f[exit_key] = tentative + math.abs(exit_tile.x - goal.x)
                + math.abs(exit_tile.y - goal.y)
              if not in_open[exit_key] then
                open[#open + 1] = exit_tile
                in_open[exit_key] = true
              end
            end
          end
        end
      end
    end
  end
  return nil, "no_route"
end

-- Convert a tile path with underground shortcuts into ordered steps. The path returned by
-- search_steps places both endpoints next to each other; adjacent path tiles are ordinary
-- belts, while a non-adjacent jump is an underground entrance/exit pair.
function M.path_to_steps(path, item)
  local steps = {}
  local index = 1
  while index <= #path do
    local tile = path[index]
    local next_tile = path[index + 1]
    if next_tile then
      local dx, dy = next_tile.x - tile.x, next_tile.y - tile.y
      if math.abs(dx) + math.abs(dy) == 1 then
        steps[#steps + 1] = {
          kind = "belt", tile = copy_tile(tile), direction = direction_between(tile, next_tile),
        }
        index = index + 1
      else
        local direction = direction_between(tile, next_tile)
        local distance = math.abs(dx) + math.abs(dy)
        local pair = M.underground_pair("underground-belt", tile, direction, distance)
        if not pair then return nil, "underground_step_invalid" end
        steps[#steps + 1] = {kind = "underground", pair = pair, tile = copy_tile(tile),
          exit_tile = copy_tile(next_tile), direction = direction, distance = distance}
        index = index + 2
      end
    else
      local direction = M.DIR.east
      if index > 1 then
        local previous = path[index - 1]
        if math.abs(tile.x - previous.x) + math.abs(tile.y - previous.y) == 1 then
          direction = direction_between(previous, tile)
        end
      end
      steps[#steps + 1] = {kind = "belt", tile = copy_tile(tile), direction = direction}
      index = index + 1
    end
  end
  return steps
end

function M.fingerprint(item, steps)
  local parts = {tostring(item)}
  for _, step in ipairs(steps or {}) do
    if step.kind == "underground" then
      parts[#parts + 1] = "ug:" .. tostring(step.tile.x) .. ":" .. tostring(step.tile.y)
        .. ":" .. tostring(step.direction) .. ":" .. tostring(step.distance)
    else
      parts[#parts + 1] = "b:" .. tostring(step.tile.x) .. ":" .. tostring(step.tile.y)
        .. ":" .. tostring(step.direction)
    end
  end
  return digest(table.concat(parts, "|"))
end

local function positions_match(actual, expected, tolerance)
  if not actual then return false end
  local position = actual.position or actual
  if not position or not position.x or not position.y then return false end
  return math.abs(position.x - (expected.x + 0.5)) < (tolerance or 0.1)
    and math.abs(position.y - (expected.y + 0.5)) < (tolerance or 0.1)
end

local function neighbour_list(entity, key)
  local neighbours = entity and entity.belt_neighbours
  return neighbours and neighbours[key] or {}
end

function M.belt_outputs_to(belt, expected_tile)
  for _, position in pairs(neighbour_list(belt, "outputs")) do
    if positions_match(position, expected_tile) then return true end
  end
  return false
end

function M.belt_inputs_from(belt, expected_tile)
  for _, position in pairs(neighbour_list(belt, "inputs")) do
    if positions_match(position, expected_tile) then return true end
  end
  return false
end

-- Verify a splitter's real type, direction and used connectors. Unused connectors are
-- required to be empty so an accidental side-load is reported instead of hidden.
function M.verify_splitter(surface, record)
  local entity = surface.find_entity(record.name, record.position)
  if not entity then return {ok = false, reason = "missing"} end
  if entity.type ~= "splitter" then return {ok = false, reason = "wrong_type"} end
  if entity.direction ~= record.direction then
    return {ok = false, reason = "wrong_direction", actual = entity.direction}
  end
  local inputs, outputs = {}, {}
  local inputs_ok, outputs_ok = true, true
  for index, tile in ipairs(record.inputs) do
    local found = false
    for _, position in pairs(neighbour_list(entity, "inputs")) do
      if positions_match(position, tile) then found = true break end
    end
    inputs[index] = found
    if record.used_inputs and record.used_inputs[index] and not found then inputs_ok = false end
    if record.used_inputs and not record.used_inputs[index] and found then inputs_ok = false end
  end
  for index, tile in ipairs(record.outputs) do
    local found = false
    for _, position in pairs(neighbour_list(entity, "outputs")) do
      if positions_match(position, tile) then found = true break end
    end
    outputs[index] = found
    if record.used_outputs and record.used_outputs[index] and not found then outputs_ok = false end
    if record.used_outputs and not record.used_outputs[index] and found then outputs_ok = false end
  end
  local ok = inputs_ok and outputs_ok
  return {ok = ok, inputs = inputs, outputs = outputs,
    reason = ok and nil or "connector_mismatch"}
end

function M.verify_underground_pair(surface, pair)
  local entrance = surface.find_entity(pair.name, pair.entrance.position)
  local exit = surface.find_entity(pair.name, pair.exit.position)
  if not entrance then return {ok = false, reason = "entrance_missing"} end
  if not exit then return {ok = false, reason = "exit_missing"} end
  if entrance.type ~= "underground-belt" or exit.type ~= "underground-belt" then
    return {ok = false, reason = "wrong_type"}
  end
  if entrance.direction ~= pair.direction or exit.direction ~= pair.direction then
    return {ok = false, reason = "wrong_direction", entrance = entrance.direction,
      exit = exit.direction}
  end
  local entrance_type = entrance.belt_to_ground_type
  local exit_type = exit.belt_to_ground_type
  if entrance_type ~= "input" or exit_type ~= "output" and exit_type ~= "input" then
    -- Factorio 2.1.24 returns "input" for an unpaired endpoint and "output" for the far
    -- side of a live pair. Require the engine's neighbour relation below regardless.
  end
  local entrance_neighbour = entrance.underground_belt_neighbour
  local exit_neighbour = exit.underground_belt_neighbour
  if not entrance_neighbour or not exit_neighbour then
    return {ok = false, reason = "not_paired"}
  end
  if math.abs(entrance_neighbour.position.x - exit.position.x) > 0.1
    or math.abs(entrance_neighbour.position.y - exit.position.y) > 0.1 then
    return {ok = false, reason = "wrong_partner"}
  end
  if math.abs(exit_neighbour.position.x - entrance.position.x) > 0.1
    or math.abs(exit_neighbour.position.y - entrance.position.y) > 0.1 then
    return {ok = false, reason = "wrong_partner"}
  end
  return {ok = true, entrance_type = entrance_type, exit_type = exit_type,
    distance = math.abs(entrance.position.x - exit.position.x)
      + math.abs(entrance.position.y - exit.position.y)}
end

-- Read-only sample of the items currently on a transport belt. Production code never
-- inserts or removes anything; this is used only for flow observation.
function M.read_belt_flow(entity)
  if not entity or not entity.valid then return {} end
  local result = {}
  local ok, line = pcall(function() return entity.get_transport_line(1, true) end)
  if ok and line then
    local read, contents = pcall(function() return line.get_contents() end)
    if read and contents then result.left = contents end
  end
  local ok2, line2 = pcall(function() return entity.get_transport_line(2, true) end)
  if ok2 and line2 then
    local read, contents = pcall(function() return line2.get_contents() end)
    if read and contents then result.right = contents end
  end
  return result
end

return M
