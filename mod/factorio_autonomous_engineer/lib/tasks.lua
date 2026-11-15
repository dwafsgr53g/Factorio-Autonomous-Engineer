local construction = require("lib.construction")
local collaboration = require("lib.collaboration")
local clearing = require("lib.clearing")

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

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
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
    if arrived or distance(agent.position, task.approach) <= 1.5 then
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

local function finish_construction(s, task, status, reason)
  stop_character(s.agent)
  local summary = collaboration.summary(task)
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
    player_interference = summary.player_interference,
    inventory_full = summary.inventory_full,
    items_transferred = summary.items_transferred,
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
  table.sort(result, function(a, b)
    return distance(agent.position, a.position) < distance(agent.position, b.position)
  end)
  return result
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

local function target_position(task)
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
            elseif not can_place then
              set_entry_status(task, entry.key, "blocked", "blocked_terrain")
            else
              local missing = construction.missing(agent, requirements)
              if #missing > 0 then
                if not construction.can_carry_any(agent, missing) then
                  task.inventory_full = true
                  set_entry_status(task, entry.key, "blocked", "inventory_full")
                else
                  local chest = construction.chest_with_items(
                    context.surface, context.area, missing, agent)
                  if chest then
                    local approach = construction.approach_for_entity(context.surface, chest, agent)
                    if approach then
                      entry.status = "acquiring"
                      task.target_entry, task.target_ghost, task.target_chest = entry.key, ghost, chest
                      task.missing_for_target = missing
                      if begin_path(task, agent, approach, "chest") then return true end
                      set_entry_status(task, entry.key, "blocked", "chest_path_failed")
                      clear_target(task)
                    else
                      set_entry_status(task, entry.key, "blocked", "chest_no_approach")
                    end
                  else
                    set_entry_status(task, entry.key, "missing_materials", "missing_materials", missing)
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
  local ok, reason, entity, proxy = construction.build(agent, ghost)
  if ok then
    entry.status, entry.reason = "built", nil
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
  local missing = construction.missing(agent, requirements)
  if #missing == 0 then
    entry.status = "pending"
    clear_target(task)
    return
  end
  local transferred, transfer_reason = construction.take_from_chest(agent, chest, missing)
  for _, item in pairs(transferred) do
    task.items_transferred = (task.items_transferred or 0) + item.count
  end
  if transfer_reason == "inventory_full" or transfer_reason == "item_transfer_incomplete" then
    task.inventory_full = true
    set_entry_status(task, task.target_entry, "blocked", transfer_reason, missing)
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
    if arrived or distance(agent.position, task.approach) <= 1.5 then
      stop_character(agent)
      if task.target_kind == "ghost" then
        try_build_target(s, task, agent)
      elseif task.target_kind == "obstacle" then
        try_clear_target(s, task, agent)
      elseif task.target_kind == "chest" then
        try_take_from_chest(s, task, agent)
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
    work_area = {available = true, radius = collaboration.work_radius(),
      center = agent.position},
  }
  return {task_id = s.task.id, status = s.task.status}
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
      player_interference = summary.player_interference,
      inventory_full = summary.inventory_full,
      items_transferred = summary.items_transferred,
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
    if task.type == "assist_construction" then
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
  if task.type == "assist_construction" then
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
    if task.type == "assist_construction" then
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
