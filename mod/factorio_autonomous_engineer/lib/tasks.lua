local construction = require("lib.construction")
local collaboration = require("lib.collaboration")
local clearing = require("lib.clearing")
local layout_planner = require("lib.layout_planner")
local logistics = require("lib.logistics")

local M = {}

-- Whole-task budget for gathering: fixed travel/retry allowance plus per-unit mining
-- time, so the bounded failure still fires but a normal-sized gathering goal can finish.
local TASK_BASE_TICKS = 60 * 120
local TASK_TICKS_PER_UNIT = 60 * 3
local CONSTRUCTION_BASE_TICKS = 60 * 60 * 5
local CONSTRUCTION_TICKS_PER_GHOST = 60 * 30
local PLAYER_WAIT_LIMIT = 60 * 15
local SETTLE_TICKS = 10
local PATH_TIMEOUT_TICKS = 60 * 20
local MOVE_TIMEOUT_TICKS = 60 * 180
local LOGISTICS_DEADLINE_TICKS = 60 * 60 * 30
local LOGISTICS_CONSTRUCTION_RETRIES = 2
local LOGISTICS_SETTLE_TICKS = 60 * 5
local LOGISTICS_MONITOR_TICKS = 60 * 180
local LOGISTICS_MULTI_MONITOR_TICKS = 60 * 300

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function position_key(position)
  return tostring(position.x) .. "," .. tostring(position.y)
end

local function entity_key(entity)
  if entity.unit_number then return tostring(entity.unit_number) end
  return entity.name .. ":" .. tostring(entity.position.x) .. ":" .. tostring(entity.position.y)
end

local function stop_character(agent)
  if not agent or not agent.valid then return end
  agent.walking_state = {walking = false, direction = defines.direction.north}
  agent.mining_state = {mining = false}
end

local function inventory_count(agent, item)
  return agent.get_main_inventory().get_item_count(item)
end

local function request_path(agent, goal)
  if not agent or not agent.valid or not goal then return nil end
  local ok, request_id = pcall(function()
    return agent.surface.request_path{
      bounding_box = agent.prototype.collision_box,
      collision_mask = agent.prototype.collision_mask,
      start = agent.position, goal = goal, force = agent.force, radius = 1,
      entity_to_ignore = agent, pathfind_flags = {prefer_straight_paths = true},
    }
  end)
  if ok then return request_id end
  return nil
end

local function follow_path(agent, task)
  local waypoint = task.path and task.path[task.path_index]
  if not waypoint then return true end
  if distance(agent.position, waypoint.position) < 0.45 then
    task.path_index = task.path_index + 1
    waypoint = task.path[task.path_index]
  end
  if not waypoint then return true end
  local angle = math.atan2(waypoint.position.x - agent.position.x,
    agent.position.y - waypoint.position.y)
  local direction = (math.floor(angle / (math.pi / 4) + 0.5) * 2) % 16
  agent.walking_state = {walking = true, direction = direction}
  return false
end

local function clear_target(task)
  task.target_kind, task.target_entry = nil, nil
  task.target_ghost, task.target_obstacle, task.target_chest = nil, nil, nil
  task.missing_for_target = nil
  task.approach, task.path, task.path_index, task.path_request = nil, nil, nil, nil
  task.belt_walk_until, task.belt_walk_direction = nil, nil
  task.escape_until, task.escape_direction = nil, nil
  task.escape_kind, task.escape_attempts = nil, nil
  task.phase, task.phase_started_tick = "search", game.tick
end

----------------------------------------------------------------------------
-- Gathering
----------------------------------------------------------------------------

local function finish_gather(s, status, reason)
  local task = s.task
  if not task then return end
  stop_character(s.agent)
  task.status, task.reason, task.finished_tick = status, reason, game.tick
  task.result = {
    success = status == "succeeded", status = status,
    task_id = task.id, resource = task.resource, requested = task.amount,
    collected = task.collected or 0, deposits_used = task.deposits_used or 0, reason = reason,
  }
end

local function search_target(s, task)
  local agent = s.agent
  if not agent or not agent.valid then return false end
  local surface = game.surfaces[task.surface]
  if not surface then finish_gather(s, "failed", "unknown_surface") return false end
  local resources = surface.find_entities_filtered({type = "resource", name = task.resource})
  table.sort(resources, function(a, b)
    return distance(a.position, agent.position) < distance(b.position, agent.position)
  end)
  for _, resource in pairs(resources) do
    local key = entity_key(resource)
    if resource.valid and resource.amount > 0 and not task.visited[key]
      and distance(resource.position, agent.position) <= task.search_radius then
      local approach = surface.find_non_colliding_position("character", resource.position, 5, 0.5)
      if approach then
        task.target, task.approach = resource, approach
        task.phase, task.phase_started_tick = "pathing", game.tick
        local request_id = request_path(agent, approach)
        if request_id then task.path_request = request_id return true end
      end
      task.visited[key] = true
      task.target, task.approach = nil, nil
    end
  end
  finish_gather(s, "failed", task.collected > 0 and "insufficient_reachable_resource"
    or "no_reachable_deposits")
  return false
end

local function tick_gather(s, task, agent)
  local current_count = inventory_count(agent, task.resource)
  local total = current_count - task.start_count
  if total > task.collected then
    task.collected, task.last_progress_tick = total, game.tick
  end
  if task.collected >= task.amount then finish_gather(s, "succeeded", "requested_amount_collected") return end
  if game.tick - task.started_tick > (task.deadline_ticks or TASK_BASE_TICKS) then
    finish_gather(s, "failed", "task_deadline_exceeded")
    return
  end
  if task.phase == "pathing" and game.tick - (task.phase_started_tick or game.tick) > PATH_TIMEOUT_TICKS then
    if task.target and task.target.valid then task.visited[entity_key(task.target)] = true end
    task.target, task.path, task.path_request = nil, nil, nil
    task.phase, task.phase_started_tick = "search", game.tick
    return
  end
  if task.phase == "moving" and game.tick - (task.phase_started_tick or game.tick) > MOVE_TIMEOUT_TICKS then
    if task.target and task.target.valid then task.visited[entity_key(task.target)] = true end
    stop_character(agent)
    task.target, task.path, task.path_request = nil, nil, nil
    task.phase, task.phase_started_tick = "search", game.tick
    return
  end
  if game.tick - task.last_progress_tick > 60 * 45 and task.phase == "mining" then
    if task.target and task.target.valid then task.visited[entity_key(task.target)] = true end
    stop_character(agent)
    task.target, task.phase = nil, "search"
    task.phase_started_tick = game.tick
  end
  if task.phase == "search" then
    search_target(s, task)
  elseif task.phase == "moving" then
    if not task.target or not task.target.valid then task.phase, task.target = "search", nil return end
    local arrived = follow_path(agent, task)
    local arrival_tolerance = task.type == "build_logistics" and 0.55 or 1.5
    if arrived or distance(agent.position, task.approach) <= arrival_tolerance then
      stop_character(agent)
      if agent.can_reach_entity(task.target) then
        task.deposits_used = task.deposits_used + 1
        task.phase, task.phase_started_tick = "mining", game.tick
        agent.selected = task.target
        agent.mining_state = {mining = true, position = task.target.position}
      else
        task.visited[entity_key(task.target)] = true
        task.target, task.phase = nil, "search"
      end
    end
  elseif task.phase == "mining" then
    if not task.target or not task.target.valid or task.target.amount <= 0 then
      stop_character(agent)
      task.target, task.phase = nil, "search"
      task.phase_started_tick = game.tick
    elseif agent.can_reach_entity(task.target) then
      agent.selected = task.target
      agent.mining_state = {mining = true, position = task.target.position}
    else
      task.visited[entity_key(task.target)] = true
      stop_character(agent)
      task.target, task.phase = nil, "search"
      task.phase_started_tick = game.tick
    end
  end
end

----------------------------------------------------------------------------
-- Construction assistance
----------------------------------------------------------------------------

local function finish_logistics(s, task, status, reason)
  stop_character(s.agent)
  local summary = collaboration.summary(task)
  local verification = task.last_verification
  if not verification and task.logistics_plan_id then
    local ok, result = pcall(function()
      return logistics.verify(s, {logistics_plan_id = task.logistics_plan_id})
    end)
    if ok then verification = result end
  end
  local observation = verification and verification.observation or {}
  local connection_counts = {}
  local connection_total = 0
  local route_list = verification and verification.routes
  if route_list then
    for _, record in ipairs(route_list) do
      local state = record.connected and "connected" or (record.status or "blocked")
      connection_counts[state] = (connection_counts[state] or 0) + 1
      connection_total = connection_total + 1
    end
  else
    for _, record in ipairs(verification and verification.connection_statuses or {}) do
      connection_counts[record.status] = (connection_counts[record.status] or 0) + 1
      connection_total = connection_total + 1
    end
  end
  local physical = task.logistics_plan_id and logistics.status(s, task.logistics_plan_id)
  local required_items = physical and physical.physical and physical.physical.required_items or {}
  local consumers = verification and verification.consumers or nil
  local consumer_connected = 0
  local consumer_total = 0
  if consumers then
    for _, group in pairs(consumers) do
      for _, supplied in pairs(group) do
        consumer_total = consumer_total + 1
        if supplied == true then consumer_connected = consumer_connected + 1 end
      end
    end
  end
  task.status, task.reason, task.finished_tick = status, reason, game.tick
  task.result = {
    success = status == "succeeded", status = status, task_id = task.id,
    task = "build_logistics", reason = reason, goal_item = task.goal_item,
    layout_plan_id = task.layout_plan_id,
    logistics_plan_id = task.logistics_plan_id,
    logistics_status = physical and physical.physical and physical.physical.status or nil,
    mode = task.mode or "linear_chain",
    connections = connection_counts, connection_total = connection_total,
    routes_connected = connection_counts.connected or 0,
    routes_blocked = (connection_counts.blocked or 0),
    consumers = consumers,
    consumers_connected = consumer_connected,
    consumers_total = consumer_total,
    consumers_receiving = verification and verification.consumers_supplied and consumer_connected or 0,
    production_active = verification and verification.production_active == true or false,
    output_verified = verification and verification.output_verified == true or false,
    power_status = verification and (verification.power and "connected" or "missing_power_source")
      or "missing_power_source",
    fuel_status = verification and (verification.fuel and "delivered" or "missing_fuel_source")
      or "missing_fuel_source",
    production = {
      produced = observation.gear_produced == true,
      gear_wheels = observation.output_gears or 0,
      ore_seen = observation.ore_seen == true,
      coal_seen = observation.coal_seen == true,
      plate_seen = observation.plate_seen == true,
      recipe_ok = observation.gear_recipe_ok == true,
      plates_by_furnace = observation.plate_produced_by or {},
      gears_by_assembler = observation.gear_produced_by or {},
      coal_remaining = observation.coal_remaining or 0,
    },
    further_work_possible = status ~= "succeeded" and summary.missing_material_total == 0,
    required_items = required_items,
    ghosts_total = summary.ghosts_total,
    built_by_agent = summary.built_by_agent,
    already_built = summary.already_built,
    remaining = summary.remaining,
    cancelled = summary.cancelled,
    unsupported = summary.unsupported,
    blocked = summary.blocked,
    unreachable = summary.unreachable,
    missing_materials = summary.missing_materials,
    missing_material_total = summary.missing_material_total,
    obstacles = summary.obstacles,
    obstacles_cleared = summary.obstacles_cleared,
    player_interference = summary.player_interference,
    inventory_full = summary.inventory_full,
    items_transferred = summary.items_transferred,
    acquisition_trips = task.acquisition_trips or 0,
    step_out_count = task.step_out_count or 0,
    step_out_teleports = task.step_out_teleports or 0,
    belt_step_offs = task.belt_step_offs or 0,
  }
end

local function finish_construction(s, task, status, reason)
  stop_character(s.agent)
  local summary = collaboration.summary(task)
  if task.type == "build_logistics" then
    local remaining_ghosts = summary.remaining > 0
    local retryable = remaining_ghosts
      and summary.missing_material_total == 0
      and summary.unsupported == 0
      and summary.inventory_full ~= true
      and (task.construction_retries or 0) < LOGISTICS_CONSTRUCTION_RETRIES
    if retryable and status ~= "cancelled" then
      task.construction_retries = (task.construction_retries or 0) + 1
      for _, entry in pairs(task.entries or {}) do
        if entry.ghost and entry.ghost.valid and entry.status ~= "built"
          and entry.status ~= "already_built" and entry.status ~= "cancelled" then
          entry.status, entry.reason, entry.path_failures = "pending", nil, 0
        end
      end
      task.status, task.reason = "running", nil
      task.phase = "search"
      task.scan_dirty = true
      task.settle_started_tick, task.player_wait_started_tick = nil, nil
      task.started_tick = game.tick
      task.deadline_ticks = LOGISTICS_DEADLINE_TICKS
      return
    end
    if status == "succeeded" and not remaining_ghosts then
      task.status, task.reason = "running", nil
      task.phase = "verifying"
      task.verify_started_tick = game.tick
      task.monitor_started_tick = nil
      return
    end
    if status == "partial" and not remaining_ghosts and summary.missing_material_total == 0
      and summary.unsupported == 0 then
      task.status, task.reason = "running", nil
      task.phase = "verifying"
      task.verify_started_tick = game.tick
      task.monitor_started_tick = nil
      return
    end
    local final_status = status
    if status == "partial" then final_status = "blocked" end
    finish_logistics(s, task, final_status, reason or status)
    return
  end
  task.status, task.reason, task.finished_tick = status, reason, game.tick
  task.result = {
    success = status == "succeeded", status = status, task_id = task.id,
    task = "assist_construction", reason = reason,
    work_area_available = summary.work_area_available,
    ghosts_total = summary.ghosts_total,
    built_by_agent = summary.built_by_agent,
    already_built = summary.already_built,
    remaining = summary.remaining,
    cancelled = summary.cancelled,
    unsupported = summary.unsupported,
    blocked = summary.blocked,
    unreachable = summary.unreachable,
    missing_materials = summary.missing_materials,
    missing_material_total = summary.missing_material_total,
    obstacles = summary.obstacles,
    obstacles_cleared = summary.obstacles_cleared,
    failure_reasons = summary.failure_reasons,
    configuration_errors = summary.configuration_errors,
    configuration_failure_reasons = summary.configuration_failure_reasons,
    player_interference = summary.player_interference,
    inventory_full = summary.inventory_full,
    items_transferred = summary.items_transferred,
    step_out_count = task.step_out_count or 0,
    step_out_teleports = task.step_out_teleports or 0,
    belt_step_offs = task.belt_step_offs or 0,
  }
end

local function current_summary(task)
  return collaboration.summary(task)
end

local function pending_entries(task, agent)
  local result = {}
  for _, entry in pairs(task.entries or {}) do
    if entry.status == "pending" and entry.ghost and entry.ghost.valid then
      result[#result + 1] = entry
    end
  end
  if task.type == "build_logistics" then
    -- Build the large module ghosts first, while the area is still open. Building belts
    -- and inserters around the character first can enclose a later 2x2/3x3 module ghost
    -- and leave no approach. After the modules, build the far end of the logistics chain
    -- first so the remaining 1x1 ghosts cannot form a pocket around the character.
    table.sort(result, function(a, b)
      local a_module = a.ghost and a.ghost.tags and a.ghost.tags.ae_plan_id ~= nil
      local b_module = b.ghost and b.ghost.tags and b.ghost.tags.ae_plan_id ~= nil
      if a_module ~= b_module then return a_module end
      local da = distance(agent.position, a.position)
      local db = distance(agent.position, b.position)
      if math.abs(da - db) > 1e-9 then return da > db end
      return position_key(a.position) < position_key(b.position)
    end)
  else
    table.sort(result, function(a, b)
      return distance(agent.position, a.position) < distance(agent.position, b.position)
    end)
  end
  return result
end

-- Aggregate the exact cost of every ghost that is still expected to be built. This is
-- used by the composite logistics task to fetch the whole material shortfall in one chest
-- trip. Payment and revival remain per ghost in the existing paid executor.
local function aggregate_pending_requirements(task)
  local map, list = {}, {}
  for _, entry in pairs(task.entries or {}) do
    local buildable = entry.status == "pending" or entry.status == "building"
      or entry.status == "acquiring" or entry.status == "clearing"
    if buildable and entry.ghost and entry.ghost.valid then
      local requirements = construction.requirements(entry.ghost)
      if requirements then
        for _, requirement in ipairs(requirements) do
          local quality = requirement.quality or "normal"
          local key = requirement.name .. ":" .. quality
          local existing = map[key]
          if existing then
            existing.count = existing.count + requirement.count
          else
            local record = {name = requirement.name, count = requirement.count,
              quality = quality}
            map[key] = record
            list[#list + 1] = record
          end
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.quality < b.quality
  end)
  return list
end

local function set_entry_status(task, key, status, reason, missing)
  local entry = task.entries and task.entries[key]
  if not entry then return end
  entry.status, entry.reason = status, reason
  entry.missing = missing
end

local function defer_entry(task, entry)
  entry.status, entry.reason = "deferred_player", "player_working_nearby"
  task.player_interference = true
end

local function reset_inflight_entries(task)
  for _, entry in pairs(task.entries or {}) do
    if entry.status == "building" or entry.status == "clearing"
      or entry.status == "acquiring" then
      entry.status, entry.reason = "pending", nil
    end
  end
end

local function begin_path(task, agent, goal, kind)
  local request_id = request_path(agent, goal)
  if not request_id then return false end
  task.approach = goal
  task.path, task.path_index, task.path_request = nil, 1, request_id
  task.phase, task.phase_started_tick = "pathing", game.tick
  task.target_kind = kind
  return true
end

local function position_inside_box(position, box, margin)
  margin = margin or 0
  return position.x > box.left_top.x - margin and position.x < box.right_bottom.x + margin
    and position.y > box.left_top.y - margin and position.y < box.right_bottom.y + margin
end

local function position_inside_ghost_box(position, ghost, margin)
  if not ghost or not ghost.valid then return false end
  local box = ghost.bounding_box
  margin = margin or 0.2
  return position.x > box.left_top.x - margin and position.x < box.right_bottom.x + margin
    and position.y > box.left_top.y - margin and position.y < box.right_bottom.y + margin
end

local function position_inside_pending_ghost(task, position)
  for _, entry in pairs(task.entries or {}) do
    local ghost = entry.ghost
    if ghost and ghost.valid and entry.status ~= "built"
      and entry.status ~= "already_built" and entry.status ~= "cancelled"
      and entry.status ~= "unsupported" then
      if position_inside_ghost_box(position, ghost, 0.4) then return true end
    end
  end
  return false
end

local function inside_pending_ghost(task, agent)
  return position_inside_pending_ghost(task, agent.position)
end

local WALK_VECTORS = {
  {x = 0, y = -1, direction = 0}, {x = 1, y = -1, direction = 2},
  {x = 1, y = 0, direction = 4}, {x = 1, y = 1, direction = 6},
  {x = 0, y = 1, direction = 8}, {x = -1, y = 1, direction = 10},
  {x = -1, y = 0, direction = 12}, {x = -1, y = -1, direction = 14},
}

-- Choose the best immediate 8-way walking direction toward a safe goal. The first step
-- must be free of real colliders and belts, and must not enter another pending ghost.
local function best_walk_direction(surface, task, agent, goal)
  local best, best_score = nil, nil
  for _, vector in ipairs(WALK_VECTORS) do
    local step = {
      x = agent.position.x + vector.x * 0.8,
      y = agent.position.y + vector.y * 0.8,
    }
    if surface.can_place_entity{
      name = "character", position = step, force = agent.force}
      and not construction.on_belt(surface, step) then
      -- The first step may still be inside the same large ghost; that is fine because
      -- ghosts do not collide. Only real colliders and belts are explicit rejections.
      local score = distance(step, goal)
      if not best_score or score < best_score then
        best, best_score = vector.direction, score
      end
    end
  end
  return best
end

-- Find a walkable position outside every still-pending ghost footprint. The position
-- search is bounded and deterministic; it is used only to unstick the character, not
-- for normal target approach.
local function find_step_out_position(surface, task, agent)
  local boxes = {}
  for _, entry in pairs(task.entries or {}) do
    local ghost = entry.ghost
    if ghost and ghost.valid and entry.status ~= "built"
      and entry.status ~= "already_built" and entry.status ~= "cancelled"
      and entry.status ~= "unsupported" then
      boxes[#boxes + 1] = ghost.bounding_box
    end
  end
  local candidates = {}
  for radius = 1.0, 16.0, 0.5 do
    for index = 0, 23 do
      local angle = index * (2 * math.pi / 24)
      local candidate = {
        x = agent.position.x + math.cos(angle) * radius,
        y = agent.position.y + math.sin(angle) * radius,
      }
      local inside = false
      for _, box in ipairs(boxes) do
        if candidate.x > box.left_top.x - 1.0
          and candidate.x < box.right_bottom.x + 1.0
          and candidate.y > box.left_top.y - 1.0
          and candidate.y < box.right_bottom.y + 1.0 then
          inside = true
          break
        end
      end
      if not inside and surface.can_place_entity{
        name = "character", position = candidate, force = agent.force}
        and not construction.on_belt(surface, candidate) then
        candidates[#candidates + 1] = candidate
      end
    end
    if #candidates > 0 then break end
  end
  table.sort(candidates, function(a, b)
    local da, db = distance(agent.position, a), distance(agent.position, b)
    if math.abs(da - db) > 0.25 then return da < db end
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)
  return candidates[1]
end


local function target_position(task)
  if task.target_kind == "step_out" then return task.approach end
  if task.target_kind == "ghost" then
    return task.target_ghost and task.target_ghost.valid and task.target_ghost.position or nil
  elseif task.target_kind == "obstacle" then
    return task.target_obstacle and task.target_obstacle.valid and task.target_obstacle.position or nil
  elseif task.target_kind == "chest" then
    return task.target_chest and task.target_chest.valid and task.target_chest.position or nil
  end
  return nil
end

local function target_valid(task)
  if task.target_kind == "step_out" then return task.approach ~= nil end
  if task.target_kind == "ghost" then return task.target_ghost and task.target_ghost.valid end
  if task.target_kind == "obstacle" then return task.target_obstacle and task.target_obstacle.valid end
  if task.target_kind == "chest" then return task.target_chest and task.target_chest.valid end
  return false
end

local function abort_target(task, status, reason, missing)
  local entry = task.entries and task.entries[task.target_entry]
  if entry and entry.status ~= "built" and entry.status ~= "already_built"
    and entry.status ~= "cancelled" then
    set_entry_status(task, task.target_entry, status, reason, missing)
  end
  task.scan_dirty = true
  clear_target(task)
end

local function construction_path_failed(task, reason)
  local entry = task.entries and task.entries[task.target_entry]
  if entry and entry.status ~= "built" and entry.status ~= "already_built"
    and entry.status ~= "cancelled" then
    entry.path_failures = (entry.path_failures or 0) + 1
    if entry.path_failures >= 3 then
      entry.status, entry.reason = "unreachable", reason or "path_failed"
    else
      entry.status, entry.reason = "pending", nil
    end
  end
  task.scan_dirty = true
  clear_target(task)
end

local function try_start_obstacle(s, task, agent, entry, surface, ghost, obstacles)
  local nearest, nearest_distance
  for _, obstacle in pairs(obstacles) do
    local current = distance(agent.position, obstacle.position)
    if not nearest_distance or current < nearest_distance then
      nearest, nearest_distance = obstacle, current
    end
  end
  if not nearest then return false end
  local approach = construction.approach_for_entity(surface, nearest, agent)
  if not approach then
    set_entry_status(task, entry.key, "blocked", "obstacle_no_approach")
    return false
  end
  entry.status = "clearing"
  task.target_entry, task.target_ghost, task.target_obstacle = entry.key, ghost, nearest
  task.missing_for_target = nil
  if not begin_path(task, agent, approach, "obstacle") then
    set_entry_status(task, entry.key, "unreachable", "obstacle_path_failed")
    clear_target(task)
    return false
  end
  return true
end

local function choose_target(s, task, agent)
  local context = collaboration.context(s, agent)
  if not context then return false end
  local candidates = pending_entries(task, agent)
  for _, entry in pairs(candidates) do
    local ghost = entry.ghost
    if ghost and ghost.valid then
      if collaboration.player_near(agent, ghost.position) then
        defer_entry(task, entry)
      else
        local requirements, requirement_reason = construction.requirements(ghost)
        if not requirements then
          set_entry_status(task, entry.key, "unsupported", requirement_reason)
        else
          local built = construction.find_real_entity(context.surface, entry.name, entry.position)
          if built then
            set_entry_status(task, entry.key, "already_built", "built_by_player")
            entry.built_unit = built.unit_number
          else
            local can_place = context.surface.can_place_entity{
              name = ghost.ghost_name, position = ghost.position, direction = ghost.direction,
              force = agent.force, build_check_type = defines.build_check_type.ghost_revive,
            }
            local clearable, blocking, players = construction.obstacles(ghost, agent)
            if #players > 0 then
              defer_entry(task, entry)
            elseif not can_place and #blocking > 0 then
              for _, blocker in pairs(blocking) do
                task.obstacles_seen[blocker.name] = (task.obstacles_seen[blocker.name] or 0) + 1
              end
              set_entry_status(task, entry.key, "blocked", "blocked_by_existing_entity")
            elseif not can_place and #clearable > 0 then
              if try_start_obstacle(s, task, agent, entry, context.surface, ghost, clearable) then
                return true
              end
            elseif not can_place
              and position_inside_box(agent.position, ghost.bounding_box, 0.4) then
              -- The character is standing inside the target footprint. Walk to a
              -- position outside it before deciding that the ghost is blocked.
              local approach = construction.approach_for_entity(
                context.surface, ghost, agent)
              if approach then
                entry.status = "building"
                task.target_entry, task.target_ghost = entry.key, ghost
                if begin_path(task, agent, approach, "ghost") then return true end
                clear_target(task)
              end
              set_entry_status(task, entry.key, "pending", "stepping_out")
            elseif not can_place then
              set_entry_status(task, entry.key, "blocked", "blocked_terrain")
            else
              local missing = construction.missing(agent, requirements)
              if #missing > 0 then
                local acquisition_missing = missing
                if task.type == "build_logistics" then
                  local batch = aggregate_pending_requirements(task)
                  local batch_missing = construction.missing(agent, batch)
                  if #batch_missing > 0 then acquisition_missing = batch_missing end
                end
                if not construction.can_carry_any(agent, acquisition_missing) then
                  task.inventory_full = true
                  set_entry_status(task, entry.key, "blocked", "inventory_full")
                else
                  local chest = construction.chest_with_items(
                    context.surface, context.area, acquisition_missing, agent)
                  if chest then
                    local approach = construction.approach_for_entity(context.surface, chest, agent)
                    if approach then
                      entry.status = "acquiring"
                      task.target_entry, task.target_ghost, task.target_chest = entry.key, ghost, chest
                      task.missing_for_target = acquisition_missing
                      if begin_path(task, agent, approach, "chest") then return true end
                      set_entry_status(task, entry.key, "blocked", "chest_path_failed")
                      clear_target(task)
                    else
                      set_entry_status(task, entry.key, "blocked", "chest_no_approach")
                    end
                  else
                    set_entry_status(task, entry.key, "missing_materials", "missing_materials",
                      missing)
                  end
                end
              else
                local approach = construction.approach_for_entity(context.surface, ghost, agent)
                if approach then
                  entry.status = "building"
                  task.target_entry, task.target_ghost = entry.key, ghost
                  if begin_path(task, agent, approach, "ghost") then return true end
                  set_entry_status(task, entry.key, "unreachable", "ghost_path_failed")
                  clear_target(task)
                else
                  set_entry_status(task, entry.key, "unreachable", "ghost_no_approach")
                end
              end
            end
          end
        end
      end
    end
  end
  return false
end

local function finish_if_done(s, task, agent)
  local summary = current_summary(task)
  local pending = false
  for _, entry in pairs(task.entries or {}) do
    if entry.ghost and entry.ghost.valid and entry.status ~= "built"
      and entry.status ~= "already_built" and entry.status ~= "cancelled"
      and entry.status ~= "missing_materials" and entry.status ~= "unsupported"
      and entry.status ~= "blocked" and entry.status ~= "unreachable"
      and entry.status ~= "deferred_player" then
      pending = true
      break
    end
  end
  if pending then return false end
  local deferred = collaboration.count_status(task, "deferred_player")
  if deferred > 0 then
    task.player_interference = true
    if not task.player_wait_started_tick then
      task.player_wait_started_tick = game.tick
      task.phase = "waiting_player"
      return false
    end
    if game.tick - task.player_wait_started_tick < PLAYER_WAIT_LIMIT then
      task.phase = "waiting_player"
      return false
    end
    finish_construction(s, task, summary.built_by_agent > 0 and "partial" or "blocked",
      "player_interference")
    return true
  end
  task.player_wait_started_tick = nil
  -- Give a player's near-simultaneous cancel/place sequence a short settle window.
  -- Without it a blueprint change could land one tick after the agent declared the
  -- area complete. The window is bounded and re-scans before the terminal result.
  if not task.settle_started_tick then
    task.settle_started_tick = game.tick
    task.phase = "settling"
    return false
  end
  if game.tick - task.settle_started_tick < SETTLE_TICKS then
    task.phase = "settling"
    return false
  end
  collaboration.refresh(s, task, agent)
  summary = current_summary(task)
  for _, entry in pairs(task.entries or {}) do
    if entry.status == "pending" and entry.ghost and entry.ghost.valid then
      task.settle_started_tick = nil
      task.phase = "search"
      return false
    end
  end
  local errors = summary.has_missing_materials or summary.blocked > 0
    or summary.unsupported > 0 or summary.unreachable > 0 or summary.inventory_full
  if errors then
    local reason = summary.has_missing_materials and "missing_materials"
      or (summary.inventory_full and "inventory_full")
      or (summary.unsupported > 0 and "unsupported_construction")
      or (summary.blocked > 0 and "blocked_by_existing_entity")
      or "unreachable_construction"
    local status = summary.built_by_agent > 0 and "partial"
      or (summary.has_missing_materials and "missing_materials" or "blocked")
    finish_construction(s, task, status, reason)
  else
    finish_construction(s, task, "succeeded", "no_pending_construction")
  end
  return true
end

local function try_build_target(s, task, agent)
  local ghost = task.target_ghost
  local entry = task.entries and task.entries[task.target_entry]
  if not ghost or not ghost.valid or not entry then
    abort_target(task, "cancelled", "ghost_removed_by_player")
    return
  end
  if collaboration.player_near(agent, ghost.position) then
    defer_entry(task, entry)
    clear_target(task)
    return
  end
  if position_inside_box(agent.position, ghost.bounding_box) then
    -- A 2x2/3x3 ghost can contain the character if it stopped just short of its
    -- approach point. Walk out first; do not misreport the character as a blocker.
    entry.status, entry.reason = "pending", "agent_inside_ghost"
    stop_character(agent)
    clear_target(task)
    return
  end
  local ok, reason, entity, proxy = construction.build(agent, ghost)
  if ok then
    entry.status, entry.reason = "built", nil
    if reason then entry.configuration_error = reason end
    entry.built_unit = entity and entity.unit_number
    if proxy then entry.item_request_proxy = true end
    task.scan_dirty = true
    stop_character(agent)
    clear_target(task)
    return
  end
  if reason == "missing_material" then
    entry.status = "pending"
  elseif reason == "blocked" then
    entry.status = "pending"
  elseif reason == "out_of_reach" then
    set_entry_status(task, task.target_entry, "unreachable", reason)
  elseif reason == "revive_inconsistent" then
    set_entry_status(task, task.target_entry, "blocked", reason)
    task.last_error = reason
  else
    set_entry_status(task, task.target_entry, "blocked", reason or "build_failed")
  end
  stop_character(agent)
  clear_target(task)
end

local function try_clear_target(s, task, agent)
  local obstacle = task.target_obstacle
  if not obstacle or not obstacle.valid then
    abort_target(task, "cancelled", "obstacle_removed")
    return
  end
  local entry = task.entries and task.entries[task.target_entry]
  if not entry then abort_target(task, "cancelled", "missing_entry") return end
  if collaboration.player_near(agent, obstacle.position) then
    defer_entry(task, entry)
    clear_target(task)
    return
  end
  local obstacle_name = obstacle.name
  local ok, reason = clearing.mine(agent, obstacle)
  if ok then
    task.obstacles_cleared[obstacle_name] = (task.obstacles_cleared[obstacle_name] or 0) + 1
    entry.status = "pending"
    task.scan_dirty = true
    stop_character(agent)
    clear_target(task)
    return
  end
  if reason == "out_of_reach" then
    set_entry_status(task, task.target_entry, "unreachable", reason)
  elseif reason == "inventory_full_or_not_minable" or reason == "inventory_full" then
    task.inventory_full = true
    set_entry_status(task, task.target_entry, "blocked", reason)
  else
    set_entry_status(task, task.target_entry, "blocked", reason or "clearing_failed")
  end
  stop_character(agent)
  clear_target(task)
end

local function try_take_from_chest(s, task, agent)
  local chest = task.target_chest
  local entry = task.entries and task.entries[task.target_entry]
  if not entry then abort_target(task, "cancelled", "missing_entry") return end
  if not chest or not chest.valid then
    set_entry_status(task, task.target_entry, "pending")
    clear_target(task)
    return
  end
  if collaboration.player_near(agent, chest.position) then
    defer_entry(task, entry)
    clear_target(task)
    return
  end
  local ghost = task.target_ghost
  if not ghost or not ghost.valid then
    abort_target(task, "cancelled", "ghost_removed_by_player")
    return
  end
  local requirements, reason = construction.requirements(ghost)
  if not requirements then
    set_entry_status(task, task.target_entry, "unsupported", reason)
    clear_target(task)
    return
  end
  local missing
  if task.type == "build_logistics" and task.missing_for_target then
    missing = task.missing_for_target
  else
    missing = construction.missing(agent, requirements)
  end
  if #missing == 0 then
    entry.status = "pending"
    clear_target(task)
    return
  end
  local transferred, transfer_reason = construction.take_from_chest(agent, chest, missing)
  local moved = 0
  for _, item in pairs(transferred) do
    task.items_transferred = (task.items_transferred or 0) + item.count
    moved = moved + item.count
  end
  if moved > 0 then
    task.acquisition_trips = (task.acquisition_trips or 0) + 1
  end
  if transfer_reason == "inventory_full" or transfer_reason == "item_transfer_incomplete" then
    task.inventory_full = true
    set_entry_status(task, task.target_entry, "blocked", transfer_reason,
      construction.missing(agent, requirements))
  elseif transfer_reason == "chest_unavailable" or transfer_reason == "inventory_unavailable" then
    entry.status = "pending"
  elseif transfer_reason == "chest_changed_during_transfer" then
    entry.status = "pending"
  else
    entry.status = "pending"
  end
  task.scan_dirty = true
  stop_character(agent)
  clear_target(task)
end

local function tick_construction(s, task, agent)
  if game.tick - task.started_tick > (task.deadline_ticks or CONSTRUCTION_BASE_TICKS) then
    local summary = current_summary(task)
    finish_construction(s, task, summary.built_by_agent > 0 and "partial" or "failed",
      "task_deadline_exceeded")
    return
  end
  local on_belt = construction.on_belt(agent.surface, agent.position)
  local inside_ghost = inside_pending_ghost(task, agent)
  -- Native walking out of a ghost or off a working belt. Ghosts do not collide with the
  -- character and direct walking is more reliable than a path request from a moving or
  -- embedded start. A successful walk is counted; if the route is genuinely blocked,
  -- a bounded teleport fallback is used after several attempts.
  if task.escape_until then
    if not on_belt and not inside_ghost then
      stop_character(agent)
      if task.escape_kind == "belt" then
        task.belt_step_offs = (task.belt_step_offs or 0) + 1
      else
        task.step_out_count = (task.step_out_count or 0) + 1
      end
      task.escape_until, task.escape_direction = nil, nil
      task.escape_kind, task.escape_attempts = nil, nil
      reset_inflight_entries(task)
      task.scan_dirty = true
      return
    elseif game.tick < task.escape_until then
      agent.walking_state = {walking = true, direction = task.escape_direction}
      return
    else
      task.escape_until, task.escape_direction = nil, nil
      task.escape_attempts = (task.escape_attempts or 0) + 1
    end
  end
  if task.phase == "search" and (on_belt or inside_ghost) then
    local goal = find_step_out_position(agent.surface, task, agent)
    if goal then
      if (task.escape_attempts or 0) > 3 then
        agent.teleport(goal)
        task.step_out_teleports = (task.step_out_teleports or 0) + 1
        task.escape_attempts = 0
        if on_belt then
          task.belt_step_offs = (task.belt_step_offs or 0) + 1
        else
          task.step_out_count = (task.step_out_count or 0) + 1
        end
        reset_inflight_entries(task)
        clear_target(task)
        task.scan_dirty = true
        return
      end
      local direction = best_walk_direction(agent.surface, task, agent, goal)
      if direction then
        task.escape_direction = direction
        task.escape_until = game.tick + 90
        task.escape_kind = on_belt and "belt" or "ghost"
        task.escape_attempts = (task.escape_attempts or 0) + 1
        agent.walking_state = {walking = true, direction = direction}
        return
      end
      task.escape_attempts = (task.escape_attempts or 0) + 1
      return
    end
    return
  end
  if task.phase == "search" then
    if task.scan_dirty or collaboration.needs_scan(task) or not task.last_scan_tick then
      collaboration.refresh(s, task, agent)
      task.scan_dirty = false
    end
    if choose_target(s, task, agent) then
      task.settle_started_tick = nil
      return
    end
    finish_if_done(s, task, agent)
    return
  end
  if task.phase == "pathing" then
    if game.tick - (task.phase_started_tick or game.tick) > PATH_TIMEOUT_TICKS then
      construction_path_failed(task, "path_timeout")
      return
    end
    if not target_valid(task) then
      abort_target(task, "cancelled", "target_removed")
    end
    return
  end
  if task.phase == "moving" then
    local position = target_position(task)
    if not position then
      stop_character(agent)
      abort_target(task, "cancelled", "target_removed")
      return
    end
    if collaboration.player_near(agent, position) then
      local entry = task.entries and task.entries[task.target_entry]
      if entry then defer_entry(task, entry) end
      clear_target(task)
      return
    end
    if game.tick - (task.phase_started_tick or game.tick) > MOVE_TIMEOUT_TICKS then
      abort_target(task, "unreachable", "movement_timeout")
      return
    end
    local arrived = follow_path(agent, task)
    local arrival_tolerance = task.type == "build_logistics" and 0.55 or 1.5
    if arrived or distance(agent.position, task.approach) <= arrival_tolerance then
      stop_character(agent)
      if construction.on_belt(agent.surface, agent.position) then
        task.phase, task.phase_started_tick = "search", game.tick
        return
      end
      if task.target_kind == "ghost" then
        try_build_target(s, task, agent)
      elseif task.target_kind == "obstacle" then
        try_clear_target(s, task, agent)
      elseif task.target_kind == "chest" then
        try_take_from_chest(s, task, agent)
      elseif task.target_kind == "step_out" then
        if inside_pending_ghost(task, agent)
          or construction.on_belt(agent.surface, agent.position) then
          task.step_out_attempts = (task.step_out_attempts or 0) + 1
          local safe = find_step_out_position(agent.surface, task, agent)
          if safe then
            if task.step_out_attempts > 4 then
              agent.teleport(safe)
              task.step_out_teleports = (task.step_out_teleports or 0) + 1
              task.step_out_attempts = 0
              task.step_out_count = (task.step_out_count or 0) + 1
              reset_inflight_entries(task)
              clear_target(task)
              task.scan_dirty = true
              return
            end
            task.step_out_reason = construction.on_belt(
              agent.surface, agent.position) and "belt" or "ghost"
            if begin_path(task, agent, safe, "step_out") then return end
          end
          return
        end
        task.step_out_count = (task.step_out_count or 0) + 1
        if task.step_out_reason == "belt" then
          task.belt_step_offs = (task.belt_step_offs or 0) + 1
        end
        task.step_out_attempts = 0
        task.step_out_reason = nil
        reset_inflight_entries(task)
        clear_target(task)
        task.scan_dirty = true
      else
        clear_target(task)
      end
    end
    return
  end
  if task.phase == "settling" then
    task.phase = "search"
    return
  end
  if task.phase == "waiting_player" then
    if task.player_wait_started_tick
      and game.tick - task.player_wait_started_tick >= PLAYER_WAIT_LIMIT then
      local summary = current_summary(task)
      finish_construction(s, task, summary.built_by_agent > 0 and "partial" or "blocked",
        "player_interference")
    else
      task.phase = "search"
    end
    return
  end
  task.phase = "search"
end

local function start_construction(s, p)
  assert(type(p.plan) == "nil", "Construction assistance chooses the work area internally")
  local agent = s.agent
  s.next_task_id = (s.next_task_id or 0) + 1
  s.task = {
    id = tostring(s.next_task_id), type = "assist_construction", status = "running",
    phase = "search", entries = {}, obstacles_seen = {}, obstacles_cleared = {},
    started_tick = game.tick, last_progress_tick = game.tick,
    deadline_ticks = CONSTRUCTION_BASE_TICKS + 4 * CONSTRUCTION_TICKS_PER_GHOST,
    built_by_agent = 0, already_built = 0, cancelled = 0, items_transferred = 0,
    acquisition_trips = 0, step_out_count = 0, step_out_teleports = 0,
    belt_step_offs = 0,
    work_area = {available = true, radius = collaboration.work_radius(),
      center = agent.position},
  }
  return {task_id = s.task.id, status = s.task.status}
end

----------------------------------------------------------------------------
-- Physical logistics (Stage 6 composite task)
----------------------------------------------------------------------------

local function start_logistics(s, p)
  local goal = p.goal_item or "iron-gear-wheel"
  assert(type(goal) == "string" and goal ~= "", "goal_item must be a non-empty string")
  local mode = p.mode == "multi_consumer" and "multi_consumer" or "linear_chain"
  s.next_task_id = (s.next_task_id or 0) + 1
  s.task = {
    id = tostring(s.next_task_id), type = "build_logistics", status = "running",
    phase = "planning", goal_item = goal, mode = mode,
    requested_plan_id = p.plan_id,
    requested_logistics_plan_id = p.logistics_plan_id,
    layout_plan_id = nil, logistics_plan_id = nil,
    entries = {}, obstacles_seen = {}, obstacles_cleared = {},
    started_tick = game.tick, last_progress_tick = game.tick,
    deadline_ticks = LOGISTICS_DEADLINE_TICKS,
    construction_retries = 0, items_transferred = 0, acquisition_trips = 0,
    step_out_count = 0, step_out_teleports = 0, belt_step_offs = 0,
    work_area = {available = true, radius = collaboration.work_radius(),
      center = s.agent.position},
  }
  return {task_id = s.task.id, status = s.task.status, task = "build_logistics",
    goal_item = goal}
end

local function tick_logistics_planning(s, task, agent)
  if not task.layout_plan_id then
    if task.requested_plan_id then
      local plan = s.layout_plans and s.layout_plans.by_id
        and s.layout_plans.by_id[task.requested_plan_id]
      if not plan then
        finish_logistics(s, task, "blocked", "unknown_layout_plan")
        return
      end
      if (task.mode == "multi_consumer") ~= (plan.logistics
        and plan.logistics.mode == "multi_consumer") then
        finish_logistics(s, task, "blocked", "layout_plan_mode_mismatch")
        return
      end
      task.layout_plan_id = plan.id
    else
      local multi = task.mode == "multi_consumer"
      local request = {goal_item = task.goal_item}
      if multi then
        request.multi_consumer = true
      else
        request.logistics_chain = true
      end
      local result = layout_planner.create(s, request)
      if not result.ok then
        finish_logistics(s, task, "blocked", "layout_unavailable:" .. tostring(result.reason))
        return
      end
      task.layout_plan_id = result.plan.id
      return
    end
  end
  if not task.logistics_plan_id then
    if task.requested_logistics_plan_id then
      local physical = s.logistics and s.logistics.by_id
        and s.logistics.by_id[task.requested_logistics_plan_id]
      if not physical then
        finish_logistics(s, task, "blocked", "unknown_logistics_plan")
        return
      end
      if physical.layout_plan_id ~= task.layout_plan_id then
        finish_logistics(s, task, "blocked", "logistics_plan_layout_mismatch")
        return
      end
      task.logistics_plan_id = physical.id
    else
      local result = task.mode == "multi_consumer"
        and logistics.plan_expansion(s, {layout_plan_id = task.layout_plan_id})
        or logistics.plan(s, {layout_plan_id = task.layout_plan_id})
      if not result.ok then
        task.last_logistics_failure = result.reason or result.status or "blocked_route"
        if result.physical then task.logistics_plan_id = result.physical.id end
        finish_logistics(s, task, "blocked", task.last_logistics_failure)
        return
      end
      task.logistics_plan_id = result.physical.id
    end
  end
  local layout_plan = s.layout_plans and s.layout_plans.by_id
    and s.layout_plans.by_id[task.layout_plan_id]
  local already_applied = layout_plan and layout_plan.application
    and (layout_plan.application.status == "applied"
      or layout_plan.application.status == "already_applied")
  if not already_applied then
    local applied = layout_planner.apply(s, {plan_id = task.layout_plan_id})
    if not applied.ok then
      task.last_logistics_failure = applied.status or "layout_apply_failed"
      finish_logistics(s, task, "blocked", task.last_logistics_failure)
      return
    end
  end
  local placed = logistics.place_ghosts(s, {logistics_plan_id = task.logistics_plan_id})
  if not placed.ok then
    task.last_logistics_failure = placed.status or "logistics_ghosts_failed"
    finish_logistics(s, task, "blocked", task.last_logistics_failure)
    return
  end
  task.ghost_filter = {
    layout_plan_id = task.layout_plan_id,
    logistics_plan_id = task.logistics_plan_id,
  }
  task.entries, task.obstacles_seen, task.obstacles_cleared = {}, {}, {}
  task.items_transferred = 0
  task.scan_dirty, task.last_scan_tick = true, nil
  task.settle_started_tick, task.player_wait_started_tick = nil, nil
  task.phase, task.phase_started_tick = "search", game.tick
  task.started_tick = game.tick
  task.deadline_ticks = LOGISTICS_DEADLINE_TICKS
end

local function tick_logistics_verification(s, task, agent)
  if not task.verify_started_tick then task.verify_started_tick = game.tick end
  if game.tick - task.verify_started_tick < LOGISTICS_SETTLE_TICKS then return end
  local ok, verification = pcall(function()
    return logistics.verify(s, {logistics_plan_id = task.logistics_plan_id})
  end)
  if not ok then
    finish_logistics(s, task, "failed", "verification_error:" .. tostring(verification))
    return
  end
  task.last_verification = verification
  task.last_progress_tick = game.tick
  if task.mode == "multi_consumer" then
    if not verification.entities then
      if game.tick - task.verify_started_tick > LOGISTICS_SETTLE_TICKS + 60 * 30 then
        finish_logistics(s, task, "blocked", "physical_entities_missing")
      end
      return
    end
    if not verification.power then
      finish_logistics(s, task, "blocked", "missing_power_source")
      return
    end
    if not verification.routes_connected then
      task.route_invalid_since = task.route_invalid_since or game.tick
      task.route_invalid_attempts = (task.route_invalid_attempts or 0) + 1
      if task.route_invalid_attempts >= 3
        and game.tick - task.route_invalid_since > 60 * 10 then
        local first = nil
        for _, route in ipairs(verification.routes or {}) do
          if not route.connected then
            first = tostring(route.id) .. ":" .. tostring(route.reason)
            break
          end
        end
        finish_logistics(s, task, "blocked",
          "route_not_connected:" .. tostring(first or "unknown"))
        return
      end
    else
      task.route_invalid_since = nil
      task.route_invalid_attempts = 0
    end
    if not verification.fuel then
      local depleted = (verification.observation.coal_remaining or 0) <= 0
      finish_logistics(s, task, "blocked",
        depleted and "missing_fuel_source:fuel_depleted"
        or "missing_fuel_source:fuel_not_delivered")
      return
    end
    if verification.ok then
      finish_logistics(s, task, "succeeded", "multi_consumer_production_observed")
      return
    end
    task.monitor_started_tick = task.monitor_started_tick or game.tick
    if game.tick - task.monitor_started_tick > LOGISTICS_MULTI_MONITOR_TICKS then
      local reason = verification.consumers_supplied and "production_not_observed"
        or "consumers_not_supplied"
      finish_logistics(s, task, "failed", reason)
    end
    return
  end
  if not verification.entities then
    if game.tick - task.verify_started_tick > LOGISTICS_SETTLE_TICKS + 60 * 30 then
      finish_logistics(s, task, "blocked", "physical_entities_missing")
    end
    return
  end
  if not verification.power then
    finish_logistics(s, task, "blocked", "missing_power_source")
    return
  end
  if not verification.fuel then
    finish_logistics(s, task, "blocked",
      verification.observation.coal_seen and "missing_fuel_source:fuel_depleted"
      or "missing_fuel_source:fuel_not_delivered")
    return
  end
  if verification.produced then
    finish_logistics(s, task, "succeeded", "production_observed")
    return
  end
  task.monitor_started_tick = task.monitor_started_tick or game.tick
  if game.tick - task.monitor_started_tick > LOGISTICS_MONITOR_TICKS then
    finish_logistics(s, task, "failed", "production_not_observed")
  end
end

local function tick_logistics(s, task, agent)
  if game.tick - task.started_tick > (task.deadline_ticks or LOGISTICS_DEADLINE_TICKS) then
    finish_logistics(s, task, "failed", "task_deadline_exceeded")
    return
  end
  if task.phase == "planning" then
    tick_logistics_planning(s, task, agent)
    return
  end
  if task.phase == "verifying" then
    tick_logistics_verification(s, task, agent)
    return
  end
  if task.phase == "search" then reset_inflight_entries(task) end
  tick_construction(s, task, agent)
end

----------------------------------------------------------------------------
-- Public task interface
----------------------------------------------------------------------------

function M.start(s, p)
  assert(not s.task or s.task.status == "succeeded" or s.task.status == "failed"
    or s.task.status == "cancelled" or s.task.status == "partial"
    or s.task.status == "missing_materials" or s.task.status == "blocked",
    "Another foreground task is already active")
  assert(s.agent and s.agent.valid, "Agent is not alive")
  assert(not (s.safety and s.safety.active), "Safety controller is active")
  if p.task == "assist_construction" then
    return start_construction(s, p)
  end
  if p.task == "build_logistics" then
    return start_logistics(s, p)
  end
  assert(p.task == "gather_resource", "Unsupported task")
  assert(type(p.resource) == "string" and prototypes.item[p.resource], "Unknown resource item prototype")
  assert(type(p.amount) == "number" and p.amount > 0 and p.amount % 1 == 0,
    "amount must be a positive integer")
  local surface_name = p.surface or s.agent.surface.name
  assert(game.surfaces[surface_name], "Unknown surface")
  s.next_task_id = (s.next_task_id or 0) + 1
  s.task = {
    id = tostring(s.next_task_id), type = p.task, resource = p.resource,
    amount = p.amount, surface = surface_name, search_radius = math.min(p.search_radius or 128, 2048),
    collected = 0, start_count = inventory_count(s.agent, p.resource),
    visited = {}, deposits_used = 0, status = "running", phase = "search",
    started_tick = game.tick, last_progress_tick = game.tick,
    deadline_ticks = TASK_BASE_TICKS + p.amount * TASK_TICKS_PER_UNIT,
  }
  search_target(s, s.task)
  return {task_id = s.task.id, status = s.task.status}
end

function M.path_finished(s, event)
  local task = s.task
  if not task or task.status ~= "running" or task.phase ~= "pathing"
    or event.id ~= task.path_request then return end
  if task.type == "assist_construction" then
    if event.path and #event.path > 0 then
      task.path, task.path_index = event.path, 1
      task.phase, task.phase_started_tick = "moving", game.tick
    else
      construction_path_failed(task, "path_failed")
    end
    return
  end
  if event.path and #event.path > 0 then
    task.path, task.path_index = event.path, 1
    task.phase, task.phase_started_tick = "moving", game.tick
  else
    if task.target and task.target.valid then task.visited[entity_key(task.target)] = true end
    task.target, task.path, task.path_request = nil, nil, nil
    task.phase, task.phase_started_tick = "search", game.tick
  end
end

function M.tick(s)
  local task, agent = s.task, s.agent
  if not task or task.status ~= "running" or not agent or not agent.valid then return end
  if s.safety and s.safety.active then
    task.status, task.pause_reason = "paused", "safety"
    stop_character(agent)
    return
  end
  if task.type == "assist_construction" then
    tick_construction(s, task, agent)
  elseif task.type == "build_logistics" then
    tick_logistics(s, task, agent)
  else
    tick_gather(s, task, agent)
  end
end

function M.status(s, task_id)
  local task = s.task
  if not task or (task_id and task.id ~= task_id) then return {status = "unknown"} end
  if task.result then return task.result end
  local safety = s.safety or {}
  local emergency = {active = safety.active == true, status = safety.status or "normal",
    reason = safety.reason, destination_kind = safety.destination_kind}
  if task.type == "build_logistics" then
    local summary = current_summary(task)
    local verification = task.last_verification or {}
    local observation = verification.observation or {}
    return {
      task_id = task.id, type = task.type, status = task.status, phase = task.phase,
      reason = task.pause_reason, mode = task.mode or "linear_chain",
      goal_item = task.goal_item, layout_plan_id = task.layout_plan_id,
      logistics_plan_id = task.logistics_plan_id,
      routes_connected = verification.routes_connected,
      routes = verification.routes,
      consumers = verification.consumers,
      consumers_supplied = verification.consumers_supplied,
      production_active = verification.production_active,
      output_verified = verification.output_verified,
      ghosts_total = summary.ghosts_total,
      built_by_agent = summary.built_by_agent,
      already_built = summary.already_built,
      remaining = summary.remaining,
      cancelled = summary.cancelled,
      unsupported = summary.unsupported,
      blocked = summary.blocked,
      unreachable = summary.unreachable,
      missing_materials = summary.missing_materials,
      missing_material_total = summary.missing_material_total,
      obstacles = summary.obstacles,
      obstacles_cleared = summary.obstacles_cleared,
      player_interference = summary.player_interference,
      inventory_full = summary.inventory_full,
      items_transferred = summary.items_transferred,
      acquisition_trips = task.acquisition_trips or 0,
      step_out_count = task.step_out_count or 0,
      step_out_teleports = task.step_out_teleports or 0,
      belt_step_offs = task.belt_step_offs or 0,
      logistics_status = logistics.status(s, task.logistics_plan_id or "").physical
        and logistics.status(s, task.logistics_plan_id or "").physical.status or nil,
      power_status = verification.power and "connected" or nil,
      fuel_status = verification.fuel and "delivered" or nil,
      produced = observation.gear_produced == true,
      gear_wheels = observation.output_gears,
      emergency = emergency,
    }
  end
  if task.type == "assist_construction" then
    local summary = current_summary(task)
    return {
      task_id = task.id, type = task.type, status = task.status, phase = task.phase,
      reason = task.pause_reason,
      work_area_available = summary.work_area_available,
      ghosts_total = summary.ghosts_total,
      built_by_agent = summary.built_by_agent,
      already_built = summary.already_built,
      remaining = summary.remaining,
      cancelled = summary.cancelled,
      unsupported = summary.unsupported,
      blocked = summary.blocked,
      unreachable = summary.unreachable,
      missing_materials = summary.missing_materials,
      missing_material_total = summary.missing_material_total,
      obstacles = summary.obstacles,
      obstacles_cleared = summary.obstacles_cleared,
      failure_reasons = summary.failure_reasons,
      configuration_errors = summary.configuration_errors,
      configuration_failure_reasons = summary.configuration_failure_reasons,
      player_interference = summary.player_interference,
      inventory_full = summary.inventory_full,
      items_transferred = summary.items_transferred,
      step_out_count = task.step_out_count or 0,
      step_out_teleports = task.step_out_teleports or 0,
      belt_step_offs = task.belt_step_offs or 0,
      emergency = emergency,
    }
  end
  return {
    task_id = task.id, type = task.type, status = task.status, phase = task.phase,
    resource = task.resource, requested = task.amount, collected = task.collected,
    deposits_used = task.deposits_used, reason = task.pause_reason,
    emergency = emergency,
  }
end

function M.cancel(s, task_id, reason)
  local task = s.task
  assert(task and (not task_id or task.id == task_id), "Unknown task ID")
  if task.status == "running" or task.status == "paused" then
    if task.type == "build_logistics" then
      finish_logistics(s, task, "cancelled", reason or "cancelled")
    elseif task.type == "assist_construction" then
      finish_construction(s, task, "cancelled", reason or "cancelled")
    else
      finish_gather(s, "cancelled", reason or "cancelled")
    end
  end
  return M.status(s, task.id)
end

function M.resume(s, task_id)
  local task = s.task
  assert(task and task.id == task_id, "Unknown task ID")
  assert(task.status == "paused", "Task is not paused")
  assert(s.agent and s.agent.valid, "Agent is not alive")
  assert(not (s.safety and s.safety.active), "Safety controller is still active")
  task.status, task.pause_reason = "running", nil
  if task.type == "build_logistics" then
    reset_inflight_entries(task)
    clear_target(task)
    task.started_tick, task.last_progress_tick = game.tick, game.tick
    task.player_wait_started_tick, task.settle_started_tick = nil, nil
    task.deadline_ticks = LOGISTICS_DEADLINE_TICKS
    if task.phase == "verifying" then
      task.verify_started_tick = game.tick
      task.monitor_started_tick = nil
    elseif task.phase ~= "planning" then
      task.phase = "search"
    end
  elseif task.type == "assist_construction" then
    reset_inflight_entries(task)
    clear_target(task)
    task.started_tick, task.last_progress_tick = game.tick, game.tick
    task.player_wait_started_tick, task.settle_started_tick = nil, nil
    task.deadline_ticks = CONSTRUCTION_BASE_TICKS + 4 * CONSTRUCTION_TICKS_PER_GHOST
  else
    task.phase, task.target, task.path, task.path_request = "search", nil, nil, nil
    task.start_count = inventory_count(s.agent, task.resource) - (task.collected or 0)
    task.started_tick, task.last_progress_tick = game.tick, game.tick
  end
  return {task_id = task.id, status = task.status}
end

function M.on_agent_died(s)
  local task, agent = s.task, s.agent
  if task and task.status == "running" then
    if task.type == "assist_construction" or task.type == "build_logistics" then
      task.status, task.pause_reason = "paused", "death"
      reset_inflight_entries(task)
      clear_target(task)
      return
    end
    if agent and agent.valid then
      local current = inventory_count(agent, task.resource)
      task.collected = math.max(task.collected or 0, current - (task.start_count or current))
    end
    task.status, task.pause_reason = "paused", "death"
    task.phase, task.target, task.path, task.path_request = "search", nil, nil, nil
  end
end

return M
