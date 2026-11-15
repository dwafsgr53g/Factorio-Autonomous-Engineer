local M = {}
local ALERT_RADIUS = 32
local HOME_RADIUS = 48
local ESCAPE_DISTANCE = 40
local PATH_RETRY_TICKS = 90
local PATH_TIMEOUT_TICKS = 300
local IDLE_SCAN_INTERVAL = 15
local ACTIVE_SCAN_INTERVAL = 10
local CRITICAL_HEALTH_RATIO = 0.30

local function append_event(s, kind, data)
  s.events = s.events or {}
  s.next_event_id = (s.next_event_id or 0) + 1
  s.events[#s.events + 1] = {id = s.next_event_id, type = kind, tick = game.tick, data = data or {}}
  while #s.events > 200 do table.remove(s.events, 1) end
end

local function enemies_near(agent, radius)
  if not agent or not agent.valid then return {} end
  return agent.surface.find_entities_filtered({
    position = agent.position, radius = radius, force = game.forces.enemy,
    type = {"unit", "unit-spawner", "turret", "ammo-turret", "electric-turret",
      "fluid-turret", "artillery-turret"},
  })
end

local function nearest_enemy(agent, enemies)
  local best, best_distance
  for _, enemy in pairs(enemies) do
    local dx, dy = enemy.position.x - agent.position.x, enemy.position.y - agent.position.y
    local squared = dx * dx + dy * dy
    if not best_distance or squared < best_distance then best, best_distance = enemy, squared end
  end
  return best, best_distance and math.sqrt(best_distance) or nil
end

local function armed(agent)
  local guns = agent.get_inventory(defines.inventory.character_guns)
  local ammo = agent.get_inventory(defines.inventory.character_ammo)
  return guns and ammo and guns.get_item_count() > 0 and ammo.get_item_count() > 0
end

local function stop_ordinary_actions(agent)
  agent.walking_state = {walking = false, direction = defines.direction.north}
  agent.mining_state = {mining = false}
  agent.shooting_state = {state = defines.shooting.not_shooting, position = agent.position}
end

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function position_threat_score(surface, position)
  local threats = surface.find_entities_filtered({
    position = position, radius = HOME_RADIUS, force = game.forces.enemy,
    type = {"unit", "unit-spawner", "turret", "ammo-turret", "electric-turret",
      "fluid-turret", "artillery-turret"},
  })
  local nearest = 999999
  for _, enemy in pairs(threats) do nearest = math.min(nearest, distance(position, enemy.position)) end
  return #threats, nearest
end

local function choose_escape(s, agent, enemy)
  local home = s.home
  if home then
    local surface = game.surfaces[home.surface_index]
    if surface == agent.surface then
      local count = position_threat_score(surface, home.position)
      if count == 0 then
        local position = surface.find_non_colliding_position("character", home.position, 16, 0.5)
        if position then return position, "home" end
      end
    end
  end
  local candidates, away_x, away_y = {}, 1, 0
  if enemy and enemy.valid then
    away_x, away_y = agent.position.x - enemy.position.x, agent.position.y - enemy.position.y
    local length = math.sqrt(away_x * away_x + away_y * away_y)
    if length > 0.01 then away_x, away_y = away_x / length, away_y / length end
  end
  for index = -4, 4 do
    local angle = index * math.pi / 8
    local x = away_x * math.cos(angle) - away_y * math.sin(angle)
    local y = away_x * math.sin(angle) + away_y * math.cos(angle)
    local requested = {x = agent.position.x + x * ESCAPE_DISTANCE,
                       y = agent.position.y + y * ESCAPE_DISTANCE}
    local position = agent.surface.find_non_colliding_position("character", requested, 10, 0.5)
    if position then
      local count, nearest = position_threat_score(agent.surface, position)
      candidates[#candidates + 1] = {position = position, threat_count = count, nearest_threat = nearest}
    end
  end
  table.sort(candidates, function(a, b)
    if a.threat_count ~= b.threat_count then return a.threat_count < b.threat_count end
    return a.nearest_threat > b.nearest_threat
  end)
  if candidates[1] then return candidates[1].position, "local_escape" end
  return nil, "no_safe_position"
end

local function request_escape_path(s, agent, destination)
  local ok, request_id = pcall(function()
    return agent.surface.request_path({
      bounding_box = agent.prototype.collision_box, collision_mask = agent.prototype.collision_mask,
      start = agent.position, goal = destination, force = agent.force, radius = 2,
      entity_to_ignore = agent, pathfind_flags = {prefer_straight_paths = true},
    })
  end)
  if not ok or not request_id then
    s.safety.path, s.safety.path_request = nil, nil
    s.safety.status, s.safety.last_path_failure_tick = "blocked", game.tick
    return false
  end
  s.safety.path_request, s.safety.path = request_id, nil
  s.safety.path_index, s.safety.path_requested_tick, s.safety.status = 1, game.tick, "pathing"
  return true
end

local function follow_escape_path(s, agent)
  local safety = s.safety
  if not safety.path then return end
  local waypoint = safety.path[safety.path_index]
  while waypoint and distance(agent.position, waypoint.position) < 0.65 do
    safety.path_index = safety.path_index + 1
    waypoint = safety.path[safety.path_index]
  end
  if waypoint then
    local dx, dy = waypoint.position.x - agent.position.x, waypoint.position.y - agent.position.y
    local angle = math.atan2(dx, -dy)
    local direction = (math.floor(angle / (math.pi / 4) + 0.5) * 2) % 16
    agent.walking_state = {walking = true, direction = direction}
  else
    agent.walking_state = {walking = false, direction = defines.direction.north}
    if safety.destination and distance(agent.position, safety.destination) > 3 then
      safety.path, safety.status = nil, "replanning"
      safety.last_path_failure_tick = game.tick
    end
  end
end

local function enter_emergency(s, agent, reason, enemy, event)
  if s.safety and s.safety.active then return end
  s.safety = {
    active = true, status = "alert", reason = reason, started_tick = game.tick,
    last_damage_tick = event and game.tick or nil,
    damage_total = event and (event.final_damage_amount or 0) or 0,
    cause = event and event.cause and event.cause.name or (enemy and enemy.name or nil),
    source = event and event.source and event.source.name or nil,
    damage_type = event and event.damage_type and event.damage_type.name or nil,
  }
  if s.task and s.task.status == "running" then
    s.task.status, s.task.pause_reason = "paused", "safety"
    s.task.phase, s.task.path, s.task.path_request, s.task.target = "search", nil, nil, nil
  end
  stop_ordinary_actions(agent)
  append_event(s, "agent_under_attack", {
    reason = reason, health = agent.health, max_health = agent.max_health,
    position = agent.position, cause = s.safety.cause, source = s.safety.source,
    damage_type = s.safety.damage_type,
  })
end

function M.on_damaged(s, event)
  local agent = s.agent
  if not agent or not agent.valid or not event.entity then return end
  local is_agent = event.entity == agent
  if not is_agent and s.agent_unit_number then is_agent = event.entity.unit_number == s.agent_unit_number end
  if not is_agent or (event.final_damage_amount or 0) <= 0 then return end
  if s.safety and s.safety.active then
    s.safety.last_damage_tick = game.tick
    s.safety.damage_total = (s.safety.damage_total or 0) + event.final_damage_amount
    return
  end
  enter_emergency(s, agent, "damage_received", event.cause, event)
end

function M.on_agent_died(s, event)
  s.safety = s.safety or {}
  s.safety.active, s.safety.status, s.safety.reason = true, "respawning", "agent_died"
  s.safety.started_tick = s.safety.started_tick or game.tick
  s.safety.death_tick = game.tick
  s.safety.destination, s.safety.destination_kind = nil, nil
  s.safety.path, s.safety.path_request, s.safety.path_index = nil, nil, nil
  s.safety.path_requested_tick, s.safety.last_replan_tick = nil, nil
end

function M.path_finished(s, event)
  local safety = s.safety
  if not safety or not safety.active or event.id ~= safety.path_request then return end
  if event.path then
    safety.path, safety.path_index, safety.status = event.path, 1, "evacuating"
  else
    safety.path, safety.path_request = nil, nil
    safety.status, safety.last_path_failure_tick = "replanning", game.tick
  end
end

function M.tick(s)
  local agent = s.agent
  if not agent or not agent.valid then
    if s.safety and s.safety.active then s.safety.status = "respawning" end
    return
  end
  local safety = s.safety
  local interval = safety and safety.active and ACTIVE_SCAN_INTERVAL or IDLE_SCAN_INTERVAL
  local should_scan = not s.last_enemy_scan_tick or game.tick - s.last_enemy_scan_tick >= interval
  if should_scan then
    s.last_enemy_scan_tick = game.tick
    local scanned = enemies_near(agent, ALERT_RADIUS)
    if safety and safety.active then
      safety.nearby_enemies, safety.last_enemy_scan_tick = scanned, game.tick
    elseif #scanned > 0 then
      enter_emergency(s, agent, "nearby_hostiles", nearest_enemy(agent, scanned), nil)
      safety, safety.nearby_enemies = s.safety, scanned
      safety.last_enemy_scan_tick = game.tick
    else
      return
    end
  elseif not safety or not safety.active then
    return
  end

  safety = s.safety
  if not safety or not safety.active then return end
  local enemies = {}
  for _, candidate in pairs(safety.nearby_enemies or {}) do
    if candidate and candidate.valid then enemies[#enemies + 1] = candidate end
  end
  local enemy = nearest_enemy(agent, enemies)
  if enemy and armed(agent) and agent.health > agent.max_health * CRITICAL_HEALTH_RATIO then
    agent.shooting_state = {state = defines.shooting.shooting_enemies, position = enemy.position}
  else
    agent.shooting_state = {state = defines.shooting.not_shooting, position = agent.position}
  end

  local no_destination_retry = not safety.destination
    and game.tick - (safety.last_replan_tick or 0) >= PATH_RETRY_TICKS
  local needs_plan = no_destination_retry or safety.status == "replanning"
    or (safety.status == "blocked" and game.tick - (safety.last_replan_tick or 0) >= PATH_RETRY_TICKS)
    or (safety.status == "pathing" and game.tick - (safety.path_requested_tick or game.tick) >= PATH_TIMEOUT_TICKS)
  if needs_plan then
    safety.last_replan_tick = game.tick
    safety.destination, safety.destination_kind = choose_escape(s, agent, enemy)
    if safety.destination then
      request_escape_path(s, agent, safety.destination)
    else
      safety.status, safety.last_path_failure_tick = "blocked", game.tick
    end
  end
  follow_escape_path(s, agent)

  local arrived = safety.destination and distance(agent.position, safety.destination) <= 3
  if arrived and #enemies == 0 then
    safety.active, safety.status = false, "safe"
    stop_ordinary_actions(agent)
    append_event(s, "emergency_resolved", {
      health = agent.health, position = agent.position,
      destination_kind = safety.destination_kind,
      elapsed_ticks = game.tick - (safety.started_tick or game.tick),
    })
    if s.task and s.task.status == "paused" and s.task.pause_reason == "safety" then
      s.task.pause_reason = "awaiting_llm_resume"
    end
  elseif safety.destination and not safety.path and safety.status ~= "pathing"
    and game.tick - (safety.last_path_failure_tick or 0) >= PATH_RETRY_TICKS then
    safety.status = "replanning"
  end
end

function M.is_safe(s)
  return not (s.safety and s.safety.active)
end

function M.status(s)
  local safety = s.safety
  if not safety then return {active = false, status = "normal"} end
  local count = 0
  for _, entity in pairs(safety.nearby_enemies or {}) do
    if entity and entity.valid then count = count + 1 end
  end
  return {
    active = safety.active == true, status = safety.status or "normal",
    reason = safety.reason, started_tick = safety.started_tick,
    last_damage_tick = safety.last_damage_tick, damage_total = safety.damage_total,
    cause = safety.cause, source = safety.source, damage_type = safety.damage_type,
    destination_kind = safety.destination_kind, nearby_enemy_count = count,
  }
end

return M
