-- Centralised autonomous character movement.
--
-- This module is the only place in the mod allowed to write
-- LuaControl.walking_state for the agent character. Tasks submit movement
-- intents, the controller requests paths from the Factorio pathfinder,
-- follows the returned waypoints with ordinary walking and recovers from
-- belts, ghosts, occupied destinations and stale routes.
--
-- No movement in this module uses LuaEntity.teleport(). A distance helper is
-- only used to decide when a waypoint has actually been reached.
local M = {}

local WAYPOINT_TOLERANCE = 0.42
local DEFAULT_ARRIVAL = 1.2
local PATH_TIMEOUT_TICKS = 60 * 20
local TRY_AGAIN_DELAY = 30
local TRY_AGAIN_LIMIT = 8
local NO_PATH_RETRY_DELAY = 45
local NO_PATH_RETRY_LIMIT = 2
local STUCK_WINDOW_TICKS = 24
local STUCK_MIN_DISTANCE = 0.35
local PROGRESS_SAMPLE_INTERVAL = 2
local PROGRESS_SAMPLE_LIMIT = 48
local GHOST_GRACE_TICKS = 3
local RECOVERY_LIMIT = 6
-- Belt exits are selected once and reached with Factorio's built-in unit pathfinder.
-- Candidates include a clearance margin for the character's collision area.
local BELT_EXIT_SEARCH_RADIUS = 32
local BELT_EXIT_CLEARANCE = 1.25
local BELT_EXIT_DIRECTIONS = 16
local BELT_EXIT_PATH_RADIUS = 0.25
local BELT_EXIT_STALE_START_DISTANCE = 1.0
local BELT_STEP_OUT_WINDOW_TICKS = 180
local RECOVERY_WAIT_TICKS = 60
local OCCUPIED_LIMIT = 3
local REPLAN_LIMIT = 4
local MAX_INTENT_RECORDS = 24

local PRIORITY_TASK = 10
local PRIORITY_RECOVERY = 50
local PRIORITY_EMERGENCY = 100

-- Locals are reset by a save/load, so this flag reliably identifies the first
-- tick after loading. Path request handles and waypoint arrays are never
-- trusted across that boundary.
local loaded_from_save = false
script.on_load(function()
  loaded_from_save = true
end)

local function distance(a, b)
  if not a or not b then return math.huge end
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function position_copy(position)
  if not position then return nil end
  return {x = position.x, y = position.y}
end

local function position_key(position)
  return tostring(position.x) .. "," .. tostring(position.y)
end

local function point_inside_box(position, box, margin)
  if not position or not box then return false end
  margin = margin or 0
  return position.x > box.left_top.x - margin and position.x < box.right_bottom.x + margin
    and position.y > box.left_top.y - margin and position.y < box.right_bottom.y + margin
end

local function direction_toward(from, to)
  local angle = math.atan2(to.x - from.x, -(to.y - from.y))
  return (math.floor(angle / (math.pi / 4) + 0.5) * 2) % 16
end

local function stop_walking(agent, movement)
  if not agent or not agent.valid then return end
  if movement then movement.walking = false end
  agent.walking_state = {walking = false, direction = defines.direction.north}
end

local function start_walking(agent, movement, direction, intent)
  if not agent or not agent.valid then return end
  if movement then movement.walking = true end
  if intent then intent.walk_direction = direction end
  agent.walking_state = {walking = true, direction = direction}
end

local function on_belt(surface, position, clearance)
  if not surface or not position then return false, nil end
  local margin = clearance or 0.45
  local entities = surface.find_entities_filtered{
    area = {{x = position.x - margin, y = position.y - margin},
      {x = position.x + margin, y = position.y + margin}},
    type = {"transport-belt", "underground-belt", "splitter"},
  }
  for _, entity in pairs(entities) do
    if entity.valid then return true, entity end
  end
  return false, nil
end

local function inside_ghost(surface, position)
  if not surface or not position then return false, nil end
  local ghosts = surface.find_entities_filtered{
    area = {{x = position.x - 1.5, y = position.y - 1.5},
      {x = position.x + 1.5, y = position.y + 1.5}},
    type = {"entity-ghost", "tile-ghost"},
  }
  for _, ghost in pairs(ghosts) do
    if ghost.valid and point_inside_box(position, ghost.bounding_box, 0.12) then
      return true, ghost
    end
  end
  return false, nil
end

local function other_character_near(agent, position, radius)
  if not agent or not agent.valid or not position then return nil end
  local characters = agent.surface.find_entities_filtered{
    position = position, radius = radius or 1.0, type = "character",
  }
  for _, character in pairs(characters) do
    if character.valid and character.unit_number ~= agent.unit_number then
      return character
    end
  end
  return nil
end

-- A belt can carry a character into a position whose collision box clips the
-- belt's own box. The engine still lets the character walk, but the pathfinder
-- refuses to plan from a non-placeable start and returns an empty path, so a
-- route would otherwise look permanently unreachable. This probe lets the
-- controller step out before giving up on a target.
--
-- ``can_place_entity{name = "character"}`` cannot be used here: the character's
-- own body blocks its own position. The engine's nearest free position is used
-- instead, which returns the current position when it is already walkable.
local function character_position_is_free(agent)
  if not agent or not agent.valid then return false end
  local ok, free = pcall(function()
    return agent.surface.find_non_colliding_position(
      "character", agent.position, 1.0, 0.05)
  end)
  if not ok or not free then return false end
  return distance(free, agent.position) < 0.2
end

local function state()
  local s = storage.autonomous_engineer
  s.movement = s.movement or {
    next_id = 0, intents = {}, primary = nil, emergency = nil,
    path_request = nil, world_revision = 0, stats = {},
  }
  s.movement.stats = s.movement.stats or {}
  s.movement.intents = s.movement.intents or {}
  return s.movement
end

local function bump_stat(movement, name, amount)
  movement.stats[name] = (movement.stats[name] or 0) + (amount or 1)
end

local function prune_intents(movement)
  local ids = {}
  for id, intent in pairs(movement.intents) do
    if intent.state == "cancelled" or intent.state == "arrived" or intent.state == "blocked" then
      ids[#ids + 1] = id
    end
  end
  if #ids <= MAX_INTENT_RECORDS then return end
  table.sort(ids, function(a, b)
    local ia, ib = movement.intents[a], movement.intents[b]
    return (ia.finished_tick or 0) < (ib.finished_tick or 0)
  end)
  while #ids > MAX_INTENT_RECORDS do
    movement.intents[table.remove(ids, 1)] = nil
  end
end

local function new_intent(movement, agent, spec, priority, kind)
  movement.next_id = (movement.next_id or 0) + 1
  local id = "mv:" .. tostring(movement.next_id)
  local intent = {
    id = id,
    owner = spec.owner or "unknown",
    purpose = spec.purpose or "move",
    kind = kind or "task",
    priority = priority,
    destination = position_copy(spec.destination),
    entity_unit = spec.entity_unit,
    arrival_tolerance = spec.arrival_tolerance or DEFAULT_ARRIVAL,
    -- A stand intent ends at a place where the character must remain (a working
    -- position, a chest/obstacle/module approach). Only those intents step off a
    -- belt. Ordinary travel crosses belts: the belt only slows the character down,
    -- it does not need to be left.
    stand = spec.stand == true,
    state = "idle",
    waypoint_index = 1,
    generation = (movement.generation or 0) + 1,
    retries = 0, try_again_count = 0, no_path_count = 0,
    recovery_count = 0, replan_count = 0,
    created_tick = game.tick,
    last_progress_tick = game.tick,
    started = position_copy(agent and agent.valid and agent.position or nil),
    samples = {},
  }
  movement.generation = intent.generation
  movement.intents[id] = intent
  prune_intents(movement)
  return intent
end

local function cancel_intent(movement, intent, reason)
  if not intent then return end
  if intent.state == "cancelled" or intent.state == "arrived" or intent.state == "blocked" then
    return
  end
  intent.state = "cancelled"
  intent.reason = reason or "cancelled"
  intent.finished_tick = game.tick
  intent.path = nil
  intent.recovery = nil
end

local function active_intent(movement)
  local emergency = movement.emergency and movement.intents[movement.emergency]
  if emergency and emergency.state ~= "cancelled" and emergency.state ~= "blocked" then
    return emergency
  end
  local primary = movement.primary and movement.intents[movement.primary]
  if primary and primary.state ~= "cancelled" and primary.state ~= "blocked" then
    return primary
  end
  return nil
end

local function clear_path_request(movement)
  movement.path_request = nil
end

-- The engine's nearest free character position, clamped to a short walk. It is the
-- step-off target when the immediate rings around the character offer nothing better.
local function nearest_free_position(surface, position, radius)
  if not surface or not position then return nil end
  local ok, free = pcall(function()
    return surface.find_non_colliding_position("character", position, radius or 6, 0.1)
  end)
  if ok and free then return free end
  return nil
end

local function find_safe_recovery_positions(surface, agent)
  if not surface or not agent or not agent.valid then return {} end
  local start = agent.position
  local scan = BELT_EXIT_SEARCH_RADIUS + BELT_EXIT_CLEARANCE + 1
  local belts = surface.find_entities_filtered{
    area = {{x = start.x - scan, y = start.y - scan},
      {x = start.x + scan, y = start.y + scan}},
    type = {"transport-belt", "underground-belt", "splitter"},
  }
  local function belt_clear(position)
    for _, belt in pairs(belts) do
      if belt.valid and point_inside_box(position, belt.bounding_box, BELT_EXIT_CLEARANCE) then
        return false
      end
    end
    return true
  end
  -- Keep the first valid off-belt point on each ray. Candidates are ordered by
  -- geometric distance; the engine pathfinder decides reachability and route shape.
  local result = {}
  for index = 0, BELT_EXIT_DIRECTIONS - 1 do
    local angle = index * (2 * math.pi / BELT_EXIT_DIRECTIONS)
    for radius = 1.5, BELT_EXIT_SEARCH_RADIUS, 0.5 do
      local candidate = {
        x = start.x + math.cos(angle) * radius,
        y = start.y + math.sin(angle) * radius,
      }
      if belt_clear(candidate) then
        local ghost = inside_ghost(surface, candidate)
        local occupied = other_character_near(agent, candidate, 0.8)
        if not ghost and not occupied
          and surface.can_place_entity{name = "character", position = candidate,
            force = agent.force} then
          result[#result + 1] = candidate
          break
        end
      end
    end
  end
  table.sort(result, function(a, b)
    local da, db = distance(start, a), distance(start, b)
    if math.abs(da - db) > 1e-9 then return da < db end
    return position_key(a) < position_key(b)
  end)
  return result
end

local function request_path(movement, intent, agent)
  if not agent or not agent.valid or not intent.destination then return false end
  if movement.path_request then return false end
  local surface = agent.surface
  local ok, request_id = pcall(function()
    return surface.request_path{
      bounding_box = agent.prototype.collision_box,
      collision_mask = agent.prototype.collision_mask,
      start = agent.position,
      goal = intent.destination,
      force = agent.force,
      radius = intent.recovery and intent.recovery.kind == "belt"
        and BELT_EXIT_PATH_RADIUS or 1,
      entity_to_ignore = agent,
      pathfind_flags = {prefer_straight_paths = true},
    }
  end)
  if not ok or not request_id then
    intent.state = "waiting"
    intent.reason = "path_request_failed"
    intent.wait_until = game.tick + NO_PATH_RETRY_DELAY
    intent.no_path_count = (intent.no_path_count or 0) + 1
    if intent.no_path_count > NO_PATH_RETRY_LIMIT then
      intent.state, intent.reason = "blocked", "path_request_failed"
      intent.finished_tick = game.tick
    end
    return false
  end
  movement.path_request = {
    id = request_id, intent_id = intent.id, generation = intent.generation,
    requested_tick = game.tick, start_position = position_copy(agent.position),
  }
  intent.state = "path_pending"
  intent.path_request_id = request_id
  intent.path_requested_tick = game.tick
  intent.waypoint_index = 1
  intent.path_requests = (intent.path_requests or 0) + 1
  bump_stat(movement, "path_requests")
  return true
end

local function request_next_belt_exit_path(movement, intent, agent)
  local recovery = intent and intent.recovery
  if not recovery or recovery.kind ~= "belt" then return false end
  if movement.path_request then return false end
  if not recovery.exit_candidates then
    recovery.exit_candidates = find_safe_recovery_positions(agent.surface, agent)
    recovery.candidate_index = 0
  end
  local candidates = recovery.exit_candidates
  while (recovery.candidate_index or 0) < #candidates do
    recovery.candidate_index = (recovery.candidate_index or 0) + 1
    local candidate = candidates[recovery.candidate_index]
    intent.destination = position_copy(candidate)
    intent.entity_unit = nil
    intent.arrival_tolerance = 0.25
    intent.path, intent.waypoint_index = nil, 1
    intent.samples = {}
    intent.step_out_use_path = true
    intent.step_out_kind = "belt"
    intent.state, intent.reason = "recovering", "belt_exit_pathing"
    if request_path(movement, intent, agent) then
      bump_stat(movement, "belt_exit_path_requests")
      return true
    end
    if intent.state == "waiting" then return true end
  end
  intent.state, intent.reason = "blocked", "belt_exit_unreachable"
  intent.finished_tick = game.tick
  intent.path = nil
  stop_walking(agent, movement)
  bump_stat(movement, "belt_exit_exhausted")
  return false
end


local function record_sample(movement, intent, agent)
  if not agent or not agent.valid then return end
  local samples = intent.samples or {}
  intent.samples = samples
  local tick = game.tick
  if #samples > 0 and tick - samples[#samples].tick < PROGRESS_SAMPLE_INTERVAL then return end
  local previous = samples[#samples]
  if previous then
    local dx, dy = agent.position.x - previous.x, agent.position.y - previous.y
    local travelled = math.sqrt(dx * dx + dy * dy)
    intent.distance_travelled = (intent.distance_travelled or 0) + travelled
    bump_stat(movement, "distance_travelled", travelled)
  end
  samples[#samples + 1] = {tick = tick, x = agent.position.x, y = agent.position.y}
  while #samples > PROGRESS_SAMPLE_LIMIT do table.remove(samples, 1) end
end

local function progress_distance(intent, ticks)
  local samples = intent.samples or {}
  if #samples < 2 then return nil end
  local latest = samples[#samples]
  for index = #samples - 1, 1, -1 do
    local sample = samples[index]
    if latest.tick - sample.tick >= ticks then
      local dx, dy = latest.x - sample.x, latest.y - sample.y
      return math.sqrt(dx * dx + dy * dy)
    end
  end
  local first = samples[1]
  local dx, dy = latest.x - first.x, latest.y - first.y
  return math.sqrt(dx * dx + dy * dy)
end

local function find_step_out_target(surface, agent, kind)
  -- Find a free, non-belt, non-ghost position at least 3 tiles from any belt.
  -- Used only to choose the walking direction for the step-out; the character
  -- walks there by ordinary walking, never by teleportation.
  local boxes = {}
  if kind == "ghost" then
    local ghosts = surface.find_entities_filtered{
      area = {{x = agent.position.x - 16, y = agent.position.y - 16},
        {x = agent.position.x + 16, y = agent.position.y + 16}},
      type = {"entity-ghost", "tile-ghost"},
    }
    for _, ghost in pairs(ghosts) do
      if ghost.valid then boxes[#boxes + 1] = ghost.bounding_box end
    end
  end
  local belts = surface.find_entities_filtered{
    area = {{x = agent.position.x - 20, y = agent.position.y - 20},
      {x = agent.position.x + 20, y = agent.position.y + 20}},
    type = {"transport-belt", "underground-belt", "splitter"},
  }
  local best, best_score
  for radius = 3.0, 16.0, 0.5 do
    for index = 0, 23 do
      local angle = index * (2 * math.pi / 24)
      local candidate = {
        x = agent.position.x + math.cos(angle) * radius,
        y = agent.position.y + math.sin(angle) * radius,
      }
      local inside = false
      for _, box in ipairs(boxes) do
        if candidate.x > box.left_top.x - 1.0 and candidate.x < box.right_bottom.x + 1.0
          and candidate.y > box.left_top.y - 1.0 and candidate.y < box.right_bottom.y + 1.0 then
          inside = true
          break
        end
      end
      if not inside and not on_belt(surface, candidate) then
        local far_from_belt = true
        for _, belt in pairs(belts) do
          if belt.valid and distance(candidate, belt.position) < 3.0 then
            far_from_belt = false
            break
          end
        end
        if far_from_belt then
          local ok = surface.can_place_entity{name = "character", position = candidate,
            force = agent.force}
          if ok then
            local score = distance(candidate, agent.position)
            if not best_score or score < best_score then
              best, best_score = candidate, score
            end
          end
        end
      end
    end
    if best then break end
  end
  return best
end

local function best_step_direction(surface, agent, goal)
  local vectors = {
    {x = 0, y = -1, direction = 0}, {x = 1, y = -1, direction = 2},
    {x = 1, y = 0, direction = 4}, {x = 1, y = 1, direction = 6},
    {x = 0, y = 1, direction = 8}, {x = -1, y = 1, direction = 10},
    {x = -1, y = 0, direction = 12}, {x = -1, y = -1, direction = 14},
  }
  local best, best_score
  for _, vector in ipairs(vectors) do
    local step = {
      x = agent.position.x + vector.x * 0.8,
      y = agent.position.y + vector.y * 0.8,
    }
    if surface.can_place_entity{name = "character", position = step, force = agent.force}
      and not on_belt(surface, step) then
      local score = goal and distance(step, goal) or 0
      if not best_score or score < best_score then
        best, best_score = vector.direction, score
      end
    end
  end
  return best
end

local function enter_recovery(movement, intent, agent, kind)
  if not agent or not agent.valid then return false end
  if kind == "belt" then
    -- request_path needs a valid start. If the belt carried the character into an
    -- unplaceable overlap, correct only the start position, then pathfind the exit.
    if not character_position_is_free(agent) then
      local free = nearest_free_position(agent.surface, agent.position, 6)
      if not free or distance(free, agent.position) <= 0.1 then
        intent.state, intent.reason = "blocked", "belt_exit_invalid_start"
        intent.finished_tick = game.tick
        return false
      end
      intent.recovery = {
        kind = "position", pending_belt_exit = true,
        original_destination = position_copy(intent.destination),
        original_entity_unit = intent.entity_unit,
        original_tolerance = intent.arrival_tolerance,
        entered_tick = game.tick,
      }
      intent.destination = position_copy(free)
      intent.entity_unit = nil
      intent.arrival_tolerance = 0.2
      intent.step_out_direction = direction_toward(agent.position, free)
      intent.step_out_until = game.tick + 60
      intent.step_out_kind = "position"
      intent.step_out_use_path = false
      intent.path = nil
      intent.waypoint_index = 1
      intent.state, intent.reason = "recovering", "belt_invalid_start"
      bump_stat(movement, "position_recoveries")
      return true
    end

    local exits = find_safe_recovery_positions(agent.surface, agent)
    if #exits == 0 then
      intent.state, intent.reason = "blocked", "no_belt_free_exit"
      intent.finished_tick = game.tick
      stop_walking(agent, movement)
      return false
    end
    intent.recovery = {
      kind = "belt",
      original_destination = position_copy(intent.destination),
      original_entity_unit = intent.entity_unit,
      original_tolerance = intent.arrival_tolerance,
      resume_original = not on_belt(agent.surface, intent.destination, BELT_EXIT_CLEARANCE),
      exit_candidates = exits,
      candidate_index = 0,
      entered_tick = game.tick,
    }
    intent.entity_unit = nil
    intent.arrival_tolerance = 0.25
    intent.step_out_use_path = true
    intent.step_out_kind = "belt"
    intent.path = nil
    intent.waypoint_index = 1
    intent.samples = {}
    intent.last_progress_tick = game.tick
    intent.state, intent.reason = "recovering", "belt_displacement"
    bump_stat(movement, "belt_recoveries")
    return request_next_belt_exit_path(movement, intent, agent)
  end

  local goal = find_step_out_target(agent.surface, agent, kind)
  local direction
  if kind == "position" then
    local free = nearest_free_position(agent.surface, agent.position)
    if free and distance(free, agent.position) > 0.1 then
      direction = direction_toward(agent.position, free)
    end
  end
  if not direction then direction = best_step_direction(agent.surface, agent, goal) end
  if not direction then
    intent.recovery_count = (intent.recovery_count or 0) + 1
    if intent.recovery_count > RECOVERY_LIMIT then
      intent.state, intent.reason = "blocked", "no_recovery_direction"
      intent.finished_tick = game.tick
    else
      intent.state, intent.reason = "waiting", "no_recovery_direction"
      intent.wait_until = game.tick + RECOVERY_WAIT_TICKS
    end
    return false
  end
  intent.recovery = {
    kind = kind,
    original_destination = position_copy(intent.destination),
    original_entity_unit = intent.entity_unit,
    original_tolerance = intent.arrival_tolerance,
    entered_tick = game.tick,
    attempts = (intent.recovery_count or 0) + 1,
  }
  intent.step_out_direction = direction
  intent.step_out_until = game.tick + BELT_STEP_OUT_WINDOW_TICKS
  intent.step_out_kind = kind
  intent.state, intent.reason = "recovering",
    kind == "ghost" and "ghost_obstruction" or "invalid_position"
  intent.last_progress_tick = game.tick
  bump_stat(movement, kind == "ghost" and "ghost_recoveries" or "position_recoveries")
  return true
end

local function finish_recovery(movement, intent, agent)
  local recovery = intent.recovery
  local was_belt = recovery and recovery.kind == "belt"
  local resume_original = not was_belt or recovery.resume_original ~= false
  local safe_position = position_copy(agent and agent.valid and agent.position or intent.destination)
  if recovery then
    intent.destination = resume_original and recovery.original_destination or safe_position
    intent.entity_unit = recovery.original_entity_unit
    intent.arrival_tolerance = recovery.original_tolerance
    intent.recovery = nil
  end
  intent.step_out_until, intent.step_out_direction, intent.step_out_kind = nil, nil, nil
  intent.step_out_use_path = nil
  intent.path = nil
  intent.waypoint_index = 1
  intent.samples = {}
  bump_stat(movement, "recovery_resumes")
  if was_belt and not resume_original then
    intent.state, intent.reason = "arrived", "belt_target_redirected"
    intent.finished_tick = game.tick
    stop_walking(agent, movement)
    bump_stat(movement, "belt_target_redirects")
    return
  end
  intent.state, intent.reason = "idle", "recovery_complete"
end

local function alternate_destination(agent, intent)
  local base = intent.destination
  if not base then return nil end
  for radius = 1.5, 8.0, 0.5 do
    for index = 0, 15 do
      local angle = index * (2 * math.pi / 16)
      local candidate = {
        x = base.x + math.cos(angle) * radius,
        y = base.y + math.sin(angle) * radius,
      }
      if agent.surface.can_place_entity{name = "character", position = candidate,
        force = agent.force}
        and not on_belt(agent.surface, candidate)
        and not other_character_near(agent, candidate, 0.8) then
        return candidate
      end
    end
  end
  return nil
end

local function handle_obstruction(movement, intent, agent)
  -- Walking across a belt is normal. Actual belt displacement is diagnosed by the
  -- progress/heading check in check_stuck; this function deliberately does not
  -- treat every belt tile under the character as a recovery event.
  return false
end

local function waypoint_blocked(agent, waypoint)
  if not agent or not agent.valid or not waypoint then return false end
  -- Construction ghosts do not collide with the character, so can_place_entity is
  -- not a walkability test while ghosts exist. Only a real collider on the next
  -- waypoint invalidates the route.
  local position = waypoint.position
  local entities = agent.surface.find_entities_filtered{
    area = {{x = position.x - 0.35, y = position.y - 0.35},
      {x = position.x + 0.35, y = position.y + 0.35}},
  }
  for _, entity in pairs(entities) do
    if entity.valid then
      local kind = entity.type
      if kind ~= "entity-ghost" and kind ~= "tile-ghost" and kind ~= "resource"
        and kind ~= "item-entity" and kind ~= "fish" and kind ~= "corpse"
        and kind ~= "smoke" and kind ~= "character" then
        local mask = entity.prototype and entity.prototype.collision_mask
        local layers = mask and mask.layers
        -- Belts, poles and other walkable furniture do not collide with the
        -- player layer. Only a real player-colliding entity invalidates a route.
        if layers and layers.player then return true end
      end
    end
  end
  return false
end

-- Resolve the arrival of an intent at its destination. Only a stand intent (a working
-- position or an approach point) cares about the belt under the character: it steps to
-- the nearest free position instead of arriving on the belt. Ordinary travel never
-- steps off, it just arrives.
local function resolve_arrival(movement, intent, agent)
  if intent.stand and not intent.recovery
    and on_belt(agent.surface, agent.position, BELT_EXIT_CLEARANCE) then
    clear_path_request(movement)
    enter_recovery(movement, intent, agent, "belt")
    stop_walking(agent, movement)
    return false
  end
  intent.state, intent.reason = "arrived", "destination_reached"
  intent.finished_tick = game.tick
  stop_walking(agent, movement)
  bump_stat(movement, "arrivals")
  return true
end

local function follow(movement, intent, agent)
  if not intent.path or #intent.path == 0 then
    intent.state = "blocked"
    intent.reason = "empty_path"
    intent.finished_tick = game.tick
    return
  end
  local position = agent.position
  -- Keep issuing the walking direction every tick: a single assignment does not
  -- create a persistent autonomous walk in Factorio.
  intent.walking = intent.walking or false
  local index = intent.waypoint_index or 1
  while index <= #intent.path
    and distance(position, intent.path[index].position) <= WAYPOINT_TOLERANCE do
    index = index + 1
  end
  intent.waypoint_index = index
  if index > #intent.path then
    if not intent.step_out_use_path
      and distance(position, intent.destination) <= math.max(intent.arrival_tolerance, 0.8) then
      if resolve_arrival(movement, intent, agent) == false then return end
    end
    if intent.step_out_use_path then
      intent.state = "recovering"
      intent.path, intent.waypoint_index = nil, 1
      return
    end
    -- The last waypoint is close to the destination but not within tolerance.
    -- Request a fresh route from the actual position instead of walking blind.
    intent.replan_count = (intent.replan_count or 0) + 1
    if intent.replan_count > REPLAN_LIMIT then
      intent.state, intent.reason = "blocked", "destination_not_reached"
      intent.finished_tick = game.tick
      stop_walking(agent, movement)
    else
      intent.state, intent.path = "idle", nil
      intent.waypoint_index = 1
      bump_stat(movement, "replans")
    end
    return
  end
  local waypoint = intent.path[index]
  if waypoint.needs_destroy_to_reach then
    intent.state, intent.reason = "blocked", "needs_destroy"
    intent.finished_tick = game.tick
    stop_walking(agent, movement)
    bump_stat(movement, "needs_destroy")
    return
  end
  if not intent.step_out_use_path
    and distance(position, intent.destination) <= intent.arrival_tolerance then
    if resolve_arrival(movement, intent, agent) == false then return end
  end
  local direction = direction_toward(position, waypoint.position)
  start_walking(agent, movement, direction, intent)
end

local function check_stuck(movement, intent, agent)
  if intent.state ~= "following_path" then return false end
  -- A destination the character is already standing on is not "stuck"; the caller
  -- resolves arrival. Do not replan or pick alternates in that case.
  if not intent.step_out_use_path
    and distance(agent.position, intent.destination) <= intent.arrival_tolerance then
    if resolve_arrival(movement, intent, agent) == false then return true end
  end
  if game.tick - (intent.path_started_tick or game.tick) < STUCK_WINDOW_TICKS then
    return false
  end
  local moved = progress_distance(intent, STUCK_WINDOW_TICKS)
  if moved == nil or moved >= STUCK_MIN_DISTANCE then
    intent.last_progress_tick = game.tick
    return false
  end
  local ghost = inside_ghost(agent.surface, agent.position)
  if ghost then
    if enter_recovery(movement, intent, agent, "ghost") then
      clear_path_request(movement)
      stop_walking(agent, movement)
      bump_stat(movement, "ghost_stuck_recoveries")
      return true
    end
  end
  local character = other_character_near(agent, agent.position, 1.1)
  if character then
    intent.occupied_count = (intent.occupied_count or 0) + 1
    if intent.occupied_count <= OCCUPIED_LIMIT then
      intent.state, intent.reason = "waiting", "other_character"
      intent.wait_until = game.tick + RECOVERY_WAIT_TICKS
      intent.wait_kind = "character"
      stop_walking(agent, movement)
      bump_stat(movement, "waiting_for_character")
      return true
    end
  end
  local alternative = alternate_destination(agent, intent)
  if alternative then
    intent.destination = alternative
    intent.replan_count = (intent.replan_count or 0) + 1
    if intent.replan_count <= REPLAN_LIMIT then
      intent.state, intent.path = "idle", nil
      intent.waypoint_index = 1
      intent.samples = {}
      intent.reason = "occupied_destination_alternative"
      bump_stat(movement, "alternate_destinations")
      return true
    end
  end
  intent.replan_count = (intent.replan_count or 0) + 1
  if intent.replan_count <= REPLAN_LIMIT then
    intent.state, intent.path = "idle", nil
    intent.waypoint_index = 1
    intent.reason = "route_replan_stuck"
    bump_stat(movement, "replans")
    return true
  end
  intent.state, intent.reason = "blocked", "stuck"
  intent.finished_tick = game.tick
  stop_walking(agent, movement)
  bump_stat(movement, "blocked_stuck")
  return true
end

local function begin_route(movement, intent, agent)
  if not intent.destination then
    intent.state, intent.reason = "blocked", "no_destination"
    intent.finished_tick = game.tick
    return
  end
  local character = other_character_near(agent, intent.destination, 1.1)
  if character then
    local alternative = alternate_destination(agent, intent)
    if alternative then
      intent.destination = alternative
      intent.reason = "destination_occupied_alternative"
      bump_stat(movement, "alternate_destinations")
    else
      intent.state, intent.reason = "waiting", "destination_occupied"
      intent.wait_until = game.tick + RECOVERY_WAIT_TICKS
      intent.wait_kind = "destination"
      return
    end
  end
  request_path(movement, intent, agent)
end

local function tick_intent(movement, intent, agent)
  intent.samples = intent.samples or {}
  record_sample(movement, intent, agent)
  if intent.entity_unit and not intent.recovery then
    local target = agent.surface.find_entities_filtered{type = "entity-ghost"}
    local found = false
    for _, entity in pairs(target) do
      if entity.valid and entity.unit_number == intent.entity_unit then found = true break end
    end
    if not found then
      local real = agent.surface.find_entities_filtered{area = {
        {x = intent.destination.x - 8, y = intent.destination.y - 8},
        {x = intent.destination.x + 8, y = intent.destination.y + 8}}}
      for _, entity in pairs(real) do
        if entity.valid and entity.unit_number == intent.entity_unit then found = true break end
      end
    end
    if not found then
      intent.state, intent.reason = "blocked", "target_gone"
      intent.finished_tick = game.tick
      stop_walking(agent, movement)
      return
    end
  end
  if intent.state == "path_pending" then
    if intent.recovery and intent.recovery.kind == "belt"
      and not on_belt(agent.surface, agent.position, BELT_EXIT_CLEARANCE)
      and character_position_is_free(agent) then
      clear_path_request(movement)
      finish_recovery(movement, intent, agent)
      return
    end
    if intent.path_requested_tick
      and game.tick - intent.path_requested_tick > PATH_TIMEOUT_TICKS then
      clear_path_request(movement)
      if intent.recovery and intent.recovery.kind == "belt" then
        bump_stat(movement, "belt_exit_path_timeouts")
        request_next_belt_exit_path(movement, intent, agent)
      else
        intent.state, intent.reason = "blocked", "path_timeout"
        intent.finished_tick = game.tick
        bump_stat(movement, "path_timeouts")
      end
    end
    return
  end
  if intent.state == "waiting" then
    if game.tick < (intent.wait_until or game.tick) then return end
    if intent.recovery and intent.recovery.kind == "belt" then
      if not on_belt(agent.surface, agent.position, BELT_EXIT_CLEARANCE)
        and character_position_is_free(agent) then
        clear_path_request(movement)
        finish_recovery(movement, intent, agent)
        return
      end
      local reason = intent.reason
      intent.wait_kind = nil
      intent.state = "recovering"
      if reason == "pathfinder_busy" or reason == "path_request_failed" then
        request_path(movement, intent, agent)
      else
        request_next_belt_exit_path(movement, intent, agent)
      end
      return
    end
    if intent.wait_kind == "character" or intent.wait_kind == "destination" then
      local alternative = alternate_destination(agent, intent)
      if alternative then intent.destination = alternative end
    end
    intent.state, intent.reason, intent.wait_kind = "idle", nil, nil
    return
  end
  if intent.recovery and intent.recovery.kind == "belt" and intent.step_out_use_path then
    if not on_belt(agent.surface, agent.position, BELT_EXIT_CLEARANCE)
      and character_position_is_free(agent) then
      clear_path_request(movement)
      finish_recovery(movement, intent, agent)
      return
    end
    if intent.state == "blocked" then
      request_next_belt_exit_path(movement, intent, agent)
      return
    end
    if intent.path and #intent.path > 0 then
      follow(movement, intent, agent)
      if intent.state == "arrived" then
        if not on_belt(agent.surface, agent.position, BELT_EXIT_CLEARANCE)
          and character_position_is_free(agent) then
          finish_recovery(movement, intent, agent)
        else
          request_next_belt_exit_path(movement, intent, agent)
        end
      elseif intent.state == "blocked" then
        request_next_belt_exit_path(movement, intent, agent)
      end
      return
    end
    if intent.state == "recovering" or intent.state == "idle" then
      request_path(movement, intent, agent)
      return
    end
    return
  end
  if intent.state == "recovering" then
    local kind = intent.step_out_kind or "step_out"
    local free = character_position_is_free(agent)
  local on
  if kind == "belt" then
    on = not free or on_belt(agent.surface, agent.position)
  elseif kind == "ghost" then
    on = inside_ghost(agent.surface, agent.position)
  else
    on = not character_position_is_free(agent)
  end
    if intent.step_out_until and game.tick < intent.step_out_until then
      if on then
        agent.walking_state = {walking = true, direction = intent.step_out_direction}
      else
        -- Already free: stop early and resume the original destination.
        intent.step_out_until = game.tick
      end
      return
    end
    -- The bounded step-out window has ended.
    if on then
      intent.recovery_count = (intent.recovery_count or 0) + 1
      if intent.recovery_count > RECOVERY_LIMIT then
        intent.state, intent.reason = "blocked", "recovery_failed"
        intent.finished_tick = game.tick
        intent.step_out_until, intent.step_out_direction = nil, nil
        return
      end
      -- Try another bounded step-out with a fresh direction.
      local goal = find_step_out_target(agent.surface, agent, kind)
      local direction = best_step_direction(agent.surface, agent, goal)
      if direction then
        intent.step_out_direction = direction
        intent.step_out_until = game.tick + BELT_STEP_OUT_WINDOW_TICKS
        agent.walking_state = {walking = true, direction = direction}
        return
      end
      intent.state, intent.reason = "blocked", "no_recovery_direction"
      intent.finished_tick = game.tick
      intent.step_out_until, intent.step_out_direction = nil, nil
      return
    end
    -- The character is free: restore the original destination and resume routing.
    local recovery = intent.recovery
    local pending_belt_exit = recovery and recovery.pending_belt_exit
    if recovery then
      intent.destination = recovery.original_destination
      intent.entity_unit = recovery.original_entity_unit
      intent.arrival_tolerance = recovery.original_tolerance
      intent.recovery = nil
    end
    intent.step_out_until, intent.step_out_direction, intent.step_out_kind = nil, nil, nil
    intent.state, intent.reason = "idle", "recovery_complete"
    intent.path = nil
    intent.waypoint_index = 1
    intent.samples = {}
    bump_stat(movement, "recovery_resumes")
    if pending_belt_exit then enter_recovery(movement, intent, agent, "belt") end
    return
  end
  if intent.state == "idle" then
    if not intent.recovery
      and distance(agent.position, intent.destination) <= intent.arrival_tolerance then
      if resolve_arrival(movement, intent, agent) == false then return end
    end
    -- A route that starts from inside a construction ghost is recovered before the
    -- path request. Walking through ghosts during a route is normal and handled by
    -- the progress-based stuck detector instead.
    local ghost = inside_ghost(agent.surface, agent.position)
    if ghost and not intent.recovery and game.tick >= (intent.recovery_blocked_until or 0) then
      if enter_recovery(movement, intent, agent, "ghost") then
        clear_path_request(movement)
        stop_walking(agent, movement)
        return
      end
    end
    begin_route(movement, intent, agent)
    return
  end
  if intent.state == "following_path" then
    if handle_obstruction(movement, intent, agent) then return end
    if check_stuck(movement, intent, agent) then return end
    if game.tick % 10 == 0 and intent.replan_after_change then
      local waypoint = intent.path and intent.path[intent.waypoint_index]
      if waypoint and waypoint_blocked(agent, waypoint) then
        intent.replan_count = (intent.replan_count or 0) + 1
        intent.replan_after_change = false
        if intent.replan_count <= REPLAN_LIMIT then
          intent.state, intent.path = "idle", nil
          intent.waypoint_index = 1
          bump_stat(movement, "world_change_replans")
        end
        return
      end
      intent.replan_after_change = false
    end
    follow(movement, intent, agent)
    return
  end
  if intent.state == "arrived" then
    stop_walking(agent, movement)
  end
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

function M.request(s, spec)
  local movement = state()
  local agent = s.agent
  assert(spec and type(spec) == "table", "movement request spec is required")
  assert(spec.destination and type(spec.destination.x) == "number"
    and type(spec.destination.y) == "number", "movement destination is required")
  if not agent or not agent.valid then return nil, "agent_unavailable" end
  local existing = movement.primary and movement.intents[movement.primary]
  if existing and existing.owner == spec.owner
    and existing.state ~= "cancelled" and existing.state ~= "blocked"
    and existing.state ~= "arrived" and existing.destination
    and distance(existing.destination, spec.destination) < 0.5
    and (existing.entity_unit or nil) == (spec.entity_unit or nil)
    and existing.stand == (spec.stand == true) then
    return existing.id
  end
  if existing then cancel_intent(movement, existing, "replaced") end
  clear_path_request(movement)
  local intent = new_intent(movement, agent, spec, PRIORITY_TASK, "task")
  movement.primary = intent.id
  stop_walking(agent, movement)
  return intent.id
end

function M.emergency(s, spec)
  local movement = state()
  local agent = s.agent
  assert(spec and spec.destination, "emergency destination is required")
  if not agent or not agent.valid then return nil, "agent_unavailable" end
  local existing = movement.emergency and movement.intents[movement.emergency]
  if existing then cancel_intent(movement, existing, "replaced_by_emergency") end
  local primary = movement.primary and movement.intents[movement.primary]
  if primary and primary.state ~= "cancelled" and primary.state ~= "blocked"
    and primary.state ~= "arrived" then
    primary.state, primary.reason = "interrupted", "safety"
    primary.path = nil
    primary.waypoint_index = 1
  end
  clear_path_request(movement)
  local intent = new_intent(movement, agent, spec, PRIORITY_EMERGENCY, "emergency")
  movement.emergency = intent.id
  stop_walking(agent, movement)
  return intent.id
end

function M.release_emergency(s, request_id)
  local movement = state()
  local intent = movement.emergency and movement.intents[movement.emergency]
  if not intent then return false end
  if request_id and intent.id ~= request_id then return false end
  cancel_intent(movement, intent, "released")
  movement.emergency = nil
  clear_path_request(movement)
  return true
end

function M.cancel(s, request_id)
  local movement = state()
  local intent = movement.intents[request_id]
  if not intent then return false end
  cancel_intent(movement, intent, "cancelled")
  if movement.primary == request_id then
    movement.primary = nil
    clear_path_request(movement)
  end
  if movement.emergency == request_id then
    movement.emergency = nil
    clear_path_request(movement)
  end
  if s.agent and s.agent.valid then stop_walking(s.agent, movement) end
  return true
end

function M.cancel_owner(s, owner)
  local movement = state()
  local cancelled = false
  for _, intent in pairs(movement.intents) do
    if intent.owner == owner and intent.state ~= "cancelled" and intent.state ~= "arrived"
      and intent.state ~= "blocked" then
      cancel_intent(movement, intent, "owner_cancelled")
      cancelled = true
      if movement.primary == intent.id then movement.primary = nil end
      if movement.emergency == intent.id then movement.emergency = nil end
    end
  end
  if cancelled then
    clear_path_request(movement)
    if s.agent and s.agent.valid then stop_walking(s.agent, movement) end
  end
  return cancelled
end

function M.stop(s)
  local movement = state()
  for _, intent in pairs(movement.intents) do
    if intent.kind ~= "emergency" and intent.state ~= "cancelled"
      and intent.state ~= "arrived" and intent.state ~= "blocked" then
      cancel_intent(movement, intent, "stopped")
    end
  end
  movement.primary = nil
  clear_path_request(movement)
  if s.agent and s.agent.valid then stop_walking(s.agent, movement) end
end

function M.interrupt_primary(s, reason)
  local movement = state()
  local intent = movement.primary and movement.intents[movement.primary]
  if not intent then return false end
  intent.state, intent.reason = "interrupted", reason or "interrupted"
  intent.path = nil
  intent.waypoint_index = 1
  clear_path_request(movement)
  if s.agent and s.agent.valid then stop_walking(s.agent, movement) end
  return true
end

-- Force a normal-pathfinder recovery for the active movement intent. Used by
-- construction when the character is embedded in a ghost or carried by a belt
-- before any target has been selected.
function M.recover(s, owner, kind)
  local movement = state()
  local agent = s.agent
  if not agent or not agent.valid then return false, "agent_unavailable" end
  local intent = active_intent(movement)
  if not intent or (owner and intent.owner ~= owner) then
    local spec = {
      owner = owner or "recovery", purpose = kind == "belt" and "belt_step_out" or "step_out",
      destination = {x = agent.position.x, y = agent.position.y}, arrival_tolerance = 0.7,
    }
    intent = new_intent(movement, agent, spec, PRIORITY_RECOVERY, "recovery")
    movement.primary = intent.id
  end
  clear_path_request(movement)
  if enter_recovery(movement, intent, agent, kind or "step_out") then
    stop_walking(agent, movement)
    return true, intent.id
  end
  return false, intent.id
end

function M.status(s, request_id)
  local movement = state()
  local intent = request_id and movement.intents[request_id] or active_intent(movement)
  if not intent then
    return {state = "idle", arrived = false, blocked = false, request_id = nil}
  end
  return {
    request_id = intent.id, owner = intent.owner, purpose = intent.purpose,
    state = intent.state, arrived = intent.state == "arrived",
    blocked = intent.state == "blocked", cancelled = intent.state == "cancelled",
    interrupted = intent.state == "interrupted", recovering = intent.state == "recovering",
    waiting = intent.state == "waiting", path_pending = intent.state == "path_pending",
    following = intent.state == "following_path",
    reason = intent.reason, destination = intent.destination,
    waypoint_index = intent.waypoint_index,
    retries = intent.replan_count, recovery_count = intent.recovery_count,
    recovery_kind = intent.recovery and intent.recovery.kind or nil,
    belt_exit_candidate_index = intent.recovery and intent.recovery.candidate_index or nil,
    belt_exit_candidate_count = intent.recovery and #(intent.recovery.exit_candidates or {}) or nil,
    stand = intent.stand,
    arrival_tolerance = intent.arrival_tolerance,
    distance_remaining = intent.destination and s.agent and s.agent.valid
      and distance(s.agent.position, intent.destination) or nil,
  }
end

function M.detail(s)
  local movement = state()
  local intents = {}
  for id, intent in pairs(movement.intents) do
    intents[#intents + 1] = {
      id = id, owner = intent.owner, purpose = intent.purpose, state = intent.state,
      reason = intent.reason, destination = intent.destination,
      original_destination = intent.recovery and intent.recovery.original_destination or nil,
      recovery_kind = intent.recovery and intent.recovery.kind or nil,
      belt_exit_candidate_index = intent.recovery and intent.recovery.candidate_index or nil,
      belt_exit_candidate_count = intent.recovery and #(intent.recovery.exit_candidates or {}) or nil,
      stand = intent.stand,
      entity_unit = intent.entity_unit, waypoint_index = intent.waypoint_index,
      retries = intent.replan_count, recovery_count = intent.recovery_count,
      try_again_count = intent.try_again_count, no_path_count = intent.no_path_count,
      path_requests = intent.path_requests or 0,
      paths_completed = intent.paths_completed or 0,
      distance_travelled = intent.distance_travelled or 0,
      created_tick = intent.created_tick, finished_tick = intent.finished_tick,
    }
  end
  table.sort(intents, function(a, b) return a.id < b.id end)
  return {
    primary = movement.primary, emergency = movement.emergency,
    path_request = movement.path_request and movement.path_request.id or nil,
    world_revision = movement.world_revision,
    stats = movement.stats, intents = intents,
    agent = s.agent and s.agent.valid and s.agent.position or nil,
  }
end

function M.stats(s)
  return state().stats
end

function M.reset_stats(s)
  local movement = state()
  movement.stats = {}
end

function M.path_finished(s, event)
  local movement = state()
  local request = movement.path_request
  if not request or event.id ~= request.id then
    bump_stat(movement, "stale_path_callbacks")
    return
  end
  local intent = movement.intents[request.intent_id]
  if not intent or intent.generation ~= request.generation
    or intent.state ~= "path_pending" then
    clear_path_request(movement)
    bump_stat(movement, "stale_path_callbacks")
    return
  end
  clear_path_request(movement)
  intent.path_request_id = nil
  intent.paths_completed = (intent.paths_completed or 0) + 1
  bump_stat(movement, "path_callbacks")
  if event.try_again_later then
    intent.try_again_count = (intent.try_again_count or 0) + 1
    bump_stat(movement, "try_again_later")
    if intent.try_again_count > TRY_AGAIN_LIMIT then
      intent.state, intent.reason = "blocked", "pathfinder_busy"
      intent.finished_tick = game.tick
    else
      intent.state, intent.reason = "waiting", "pathfinder_busy"
      intent.wait_until = game.tick + TRY_AGAIN_DELAY
      intent.wait_kind = "path"
    end
    return
  end
  local path = event.path
  if not path or #path == 0 then
    local mover = s.agent
    if intent.recovery and intent.recovery.kind == "belt"
      and mover and mover.valid and not character_position_is_free(mover) then
      local previous = intent.recovery
      intent.recovery = nil
      if enter_recovery(movement, intent, mover, "position") then
        intent.recovery.original_destination = previous.original_destination
        intent.recovery.original_entity_unit = previous.original_entity_unit
        intent.recovery.original_tolerance = previous.original_tolerance
        intent.recovery.pending_belt_exit = true
        return
      end
      return
    end
    if intent.recovery and intent.recovery.kind == "belt" and intent.step_out_use_path then
      bump_stat(movement, "belt_exit_no_path")
      request_next_belt_exit_path(movement, intent, mover)
      return
    end
    -- An empty path from a position the engine considers non-placeable is a
    -- recoverable condition, not an unreachable destination: step out and retry
    -- instead of counting the target as unreachable.
    if mover and mover.valid and not character_position_is_free(mover)
      and not (intent.recovery and intent.recovery.kind == "position") then
      bump_stat(movement, "no_path_invalid_position")
      if enter_recovery(movement, intent, mover, "position") then
        clear_path_request(movement)
        stop_walking(mover, movement)
        return
      end
    end
    intent.no_path_count = (intent.no_path_count or 0) + 1
    bump_stat(movement, "no_path")
    if intent.no_path_count > NO_PATH_RETRY_LIMIT then
      intent.state, intent.reason = "blocked", "no_path"
      intent.finished_tick = game.tick
    else
      intent.state, intent.reason = "waiting", "no_path"
      intent.wait_until = game.tick + NO_PATH_RETRY_DELAY
      intent.wait_kind = "path"
    end
    return
  end
  local agent = s.agent
  if not agent or not agent.valid then return end
  if distance(agent.position, path[1].position) > 8 then
    -- The callback belongs to an older position. Re-plan from the actual one.
    intent.state, intent.reason = "idle", "stale_callback_start"
    bump_stat(movement, "stale_callbacks")
    return
  end
  intent.path = path
  intent.waypoint_index = 1
  intent.state = intent.step_out_use_path and "recovering" or "following_path"
  intent.reason = nil
  intent.path_started_tick = game.tick
  intent.last_progress_tick = game.tick
  intent.samples = {{tick = game.tick, x = agent.position.x, y = agent.position.y}}
  bump_stat(movement, "paths_received")
end

function M.world_changed(s, entity)
  local movement = state()
  movement.world_revision = (movement.world_revision or 0) + 1
  local intent = active_intent(movement)
  if not intent or not intent.destination then return end
  if entity and entity.valid and entity.unit_number and intent.entity_unit
    and entity.unit_number == intent.entity_unit then
    intent.state, intent.reason = "blocked", "target_gone"
    intent.finished_tick = game.tick
    return
  end
  if entity and entity.valid and entity.bounding_box then
    local waypoint = intent.path and intent.path[intent.waypoint_index]
    if (waypoint and point_inside_box(waypoint.position, entity.bounding_box, 0.6))
      or point_inside_box(s.agent and s.agent.valid and s.agent.position or {},
        entity.bounding_box, 0.8) then
      intent.replan_after_change = true
    end
  end
end

function M.on_agent_died(s)
  local movement = state()
  for _, intent in pairs(movement.intents) do
    cancel_intent(movement, intent, "agent_died")
  end
  movement.primary, movement.emergency = nil, nil
  clear_path_request(movement)
  movement.walking = false
end

function M.tick(s)
  local movement = state()
  local agent = s.agent
  if loaded_from_save then
    loaded_from_save = false
    movement.path_request = nil
    for _, intent in pairs(movement.intents) do
      if intent.state == "path_pending" or intent.state == "following_path"
        or intent.state == "recovering" or intent.state == "waiting" then
        local recovery = intent.recovery
        if recovery then
          if recovery.kind ~= "belt" or recovery.resume_original ~= false then
            intent.destination = recovery.original_destination
          end
          if recovery.kind == "belt" then
            recovery.exit_candidates = nil
            recovery.candidate_index = 0
          else
            intent.recovery = nil
          end
          intent.entity_unit = recovery.original_entity_unit
          intent.arrival_tolerance = recovery.original_tolerance
        end
        intent.step_out_until, intent.step_out_direction, intent.step_out_kind = nil, nil, nil
        if intent.recovery and intent.recovery.kind == "belt" then
          intent.step_out_use_path = true
        else
          intent.step_out_use_path = nil
        end
        intent.path = nil
        intent.waypoint_index = 1
        intent.samples = {}
        intent.state = "idle"
        intent.reason = "reloaded"
      end
    end
  end
  if not agent or not agent.valid then
    movement.path_request = nil
    return
  end
  local intent = active_intent(movement)
  if not intent then
    if movement.walking then stop_walking(agent, movement) end
    return
  end
  if movement.path_request and movement.path_request.intent_id ~= intent.id then
    -- A superseded request must never overwrite the newer intent when its
    -- callback arrives. The callback itself is ignored by generation checks.
    movement.path_request = nil
  end
  tick_intent(movement, intent, agent)
end

return M
