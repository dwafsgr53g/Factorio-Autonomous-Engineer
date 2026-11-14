local M = {}

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

local function finish(s, status, reason)
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

local function inventory_count(agent, item)
  return agent.get_main_inventory().get_item_count(item)
end

local function search_target(s, task)
  local agent = s.agent
  if not agent or not agent.valid then return false end
  local surface = game.surfaces[task.surface]
  if not surface then finish(s, "failed", "unknown_surface") return false end
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
        local ok, request_id = pcall(function()
          return surface.request_path({
            bounding_box = agent.prototype.collision_box,
            collision_mask = agent.prototype.collision_mask,
            start = agent.position, goal = approach, force = agent.force,
            radius = 1, entity_to_ignore = agent,
            pathfind_flags = {prefer_straight_paths = true},
          })
        end)
        if ok and request_id then task.path_request = request_id return true end
      end
      task.visited[key] = true
      task.target, task.approach = nil, nil
    end
  end
  finish(s, "failed", task.collected > 0 and "insufficient_reachable_resource" or "no_reachable_deposits")
  return false
end

local function follow_path(agent, task)
  local waypoint = task.path and task.path[task.path_index]
  if not waypoint then return true end
  if distance(agent.position, waypoint.position) < 0.45 then
    task.path_index = task.path_index + 1
    waypoint = task.path[task.path_index]
  end
  if not waypoint then return true end
  local angle = math.atan2(waypoint.position.x - agent.position.x, agent.position.y - waypoint.position.y)
  local direction = (math.floor(angle / (math.pi / 4) + 0.5) * 2) % 16
  agent.walking_state = {walking = true, direction = direction}
  return false
end

function M.start(s, p)
  assert(not s.task or s.task.status == "succeeded" or s.task.status == "failed"
    or s.task.status == "cancelled", "Another foreground task is already active")
  assert(s.agent and s.agent.valid, "Agent is not alive")
  assert(not (s.safety and s.safety.active), "Safety controller is active")
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
  }
  search_target(s, s.task)
  return {task_id = s.task.id, status = s.task.status}
end

function M.path_finished(s, event)
  local task = s.task
  if not task or task.status ~= "running" or task.phase ~= "pathing"
    or event.id ~= task.path_request then return end
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
  local current_count = inventory_count(agent, task.resource)
  local total = current_count - task.start_count
  if total > task.collected then
    task.collected, task.last_progress_tick = total, game.tick
  end
  if task.collected >= task.amount then finish(s, "succeeded", "requested_amount_collected") return end
  if game.tick - task.started_tick > 60 * 30 then finish(s, "failed", "task_deadline_exceeded") return end
  if task.phase == "pathing" and game.tick - (task.phase_started_tick or game.tick) > 60 * 20 then
    if task.target and task.target.valid then task.visited[entity_key(task.target)] = true end
    task.target, task.path, task.path_request = nil, nil, nil
    task.phase, task.phase_started_tick = "search", game.tick
    return
  end
  if task.phase == "moving" and game.tick - (task.phase_started_tick or game.tick) > 60 * 180 then
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

function M.status(s, task_id)
  local task = s.task
  if not task or (task_id and task.id ~= task_id) then return {status = "unknown"} end
  if task.result then return task.result end
  local safety = s.safety or {}
  return {
    task_id = task.id, type = task.type, status = task.status, phase = task.phase,
    resource = task.resource, requested = task.amount, collected = task.collected,
    deposits_used = task.deposits_used, reason = task.pause_reason,
    emergency = {active = safety.active == true, status = safety.status or "normal",
      reason = safety.reason, destination_kind = safety.destination_kind},
  }
end

function M.cancel(s, task_id, reason)
  local task = s.task
  assert(task and (not task_id or task.id == task_id), "Unknown task ID")
  if task.status == "running" or task.status == "paused" then finish(s, "cancelled", reason or "cancelled") end
  return M.status(s, task.id)
end

function M.resume(s, task_id)
  local task = s.task
  assert(task and task.id == task_id, "Unknown task ID")
  assert(task.status == "paused", "Task is not paused")
  assert(s.agent and s.agent.valid, "Agent is not alive")
  assert(not (s.safety and s.safety.active), "Safety controller is still active")
  task.status, task.pause_reason = "running", nil
  task.phase, task.target, task.path, task.path_request = "search", nil, nil, nil
  task.start_count = inventory_count(s.agent, task.resource) - (task.collected or 0)
  task.started_tick, task.last_progress_tick = game.tick, game.tick
  return {task_id = task.id, status = task.status}
end

function M.on_agent_died(s)
  local task, agent = s.task, s.agent
  if task and task.status == "running" then
    if agent and agent.valid then
      local current = inventory_count(agent, task.resource)
      task.collected = math.max(task.collected or 0, current - (task.start_count or current))
    end
    task.status, task.pause_reason = "paused", "death"
    task.phase, task.target, task.path, task.path_request = "search", nil, nil, nil
  end
end

return M
