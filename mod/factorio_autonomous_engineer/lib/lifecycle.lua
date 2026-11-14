local M = {}
local RECOVERY_SLOTS, RESPAWN_DELAY, HOME_DANGER_RADIUS = 200, 180, 48

local function append_event(s, kind, data)
  s.events = s.events or {}
  s.next_event_id = (s.next_event_id or 0) + 1
  s.events[#s.events + 1] = {id = s.next_event_id, type = kind, tick = game.tick, data = data or {}}
  while #s.events > 200 do table.remove(s.events, 1) end
end

local function recovery_bags(s)
  s.recovery = s.recovery or {}
  for _, key in ipairs({"main", "guns", "ammo", "armor"}) do
    if not s.recovery[key] or not s.recovery[key].valid then
      s.recovery[key] = game.create_inventory(RECOVERY_SLOTS)
    end
  end
  return s.recovery
end

local function item_bag(stack)
  local prototype = prototypes.item[stack.name]
  local kind = prototype and prototype.type
  if kind == "gun" then return "guns" end
  if kind == "ammo" then return "ammo" end
  if kind == "armor" then return "armor" end
  return "main"
end

local function put_stack(source_stack, destination)
  if not source_stack.valid_for_read then return 0 end
  local moved = 0
  local ok, transferred = pcall(function() return destination.transfer_from_stack(source_stack) end)
  if ok and type(transferred) == "number" then moved = moved + transferred end
  if source_stack.valid_for_read then
    local inserted = destination.insert({
      name = source_stack.name, count = source_stack.count,
      quality = source_stack.quality and source_stack.quality.name or "normal",
    })
    if inserted > 0 then
      source_stack.count = source_stack.count - inserted
      moved = moved + inserted
    end
  end
  return moved
end

local function store_inventory(source, bags)
  if not source then return 0 end
  local moved = 0
  for index = 1, #source do
    local stack = source[index]
    if stack.valid_for_read then moved = moved + put_stack(stack, bags[item_bag(stack)]) end
  end
  return moved
end

local function capture_dropped_items(s, event)
  local bags, moved = recovery_bags(s), 0
  if event.loot and event.loot.valid then moved = store_inventory(event.loot, bags) end
  -- Only fall back to character inventories if death-loot transfer moved nothing,
  -- avoiding duplicate recovery.
  if moved == 0 and event.entity and event.entity.valid then
    for _, inventory_id in ipairs({
      defines.inventory.character_main, defines.inventory.character_guns,
      defines.inventory.character_ammo, defines.inventory.character_armor,
    }) do
      local ok, inventory = pcall(function() return event.entity.get_inventory(inventory_id) end)
      if ok and inventory then moved = moved + store_inventory(inventory, bags) end
    end
  end
  return moved
end

local function restore_bag(source, destination)
  if not source or not destination then return end
  for index = 1, #source do
    local stack = source[index]
    if stack.valid_for_read then put_stack(stack, destination) end
  end
end

local function restore_inventory(s, character)
  local bags = recovery_bags(s)
  restore_bag(bags.main, character.get_main_inventory())
  restore_bag(bags.guns, character.get_inventory(defines.inventory.character_guns))
  restore_bag(bags.ammo, character.get_inventory(defines.inventory.character_ammo))
  restore_bag(bags.armor, character.get_inventory(defines.inventory.character_armor))
end

local function home_location(s)
  if s.home then
    local surface = game.surfaces[s.home.surface_index]
    if surface then return surface, s.home.position end
  end
  local surface = game.surfaces.nauvis or game.surfaces[1]
  if surface then return surface, game.forces.player.get_spawn_position(surface) end
  return nil, nil
end

local function choose_spawn(s)
  local surface, base = home_location(s)
  if not surface or not base then return nil, nil, "no_spawn_surface" end
  local nearby = surface.find_entities_filtered({
    position = base, radius = HOME_DANGER_RADIUS, force = game.forces.enemy,
    type = {"unit", "unit-spawner", "turret", "ammo-turret", "electric-turret", "fluid-turret"},
  })
  if #nearby > 0 then return nil, nil, "home_under_threat" end
  local position = surface.find_non_colliding_position("character", base, 32, 0.5)
  if not position then return nil, nil, "no_collision_free_spawn" end
  local at_position = surface.find_entities_filtered({
    position = position, radius = 24, force = game.forces.enemy,
    type = {"unit", "unit-spawner", "turret", "ammo-turret", "electric-turret", "fluid-turret"},
  })
  if #at_position > 0 then return nil, nil, "spawn_under_threat" end
  return surface, position, nil
end

local function spawn(s, reason)
  local surface, position, blocked_reason = choose_spawn(s)
  if not surface or not position then
    s.lifecycle = s.lifecycle or {}
    s.lifecycle.respawn_at = game.tick + 60
    s.lifecycle.status = "waiting_for_safe_spawn"
    s.lifecycle.spawn_block_reason = blocked_reason
    return false
  end
  local character = surface.create_entity({name = "character", position = position, force = game.forces.player})
  if not character then
    s.lifecycle.respawn_at = game.tick + 60
    s.lifecycle.status = "waiting_for_safe_spawn"
    s.lifecycle.spawn_block_reason = "character_creation_failed"
    return false
  end
  character.name_tag = "Autonomous Engineer"
  if not s.home then s.home = {surface_index = surface.index, position = position} end
  s.agent, s.agent_unit_number = character, character.unit_number
  -- Respawn completes the emergency lifecycle, but deliberately does not resume the paused task.
  if reason == "death_recovery" and s.safety then
    s.safety.active = false
    s.safety.status = "safe"
    s.safety.reason = "respawned"
    s.safety.path, s.safety.path_request = nil, nil
    s.safety.destination, s.safety.destination_kind = nil, nil
  end
  s.lifecycle = s.lifecycle or {}
  s.lifecycle.status, s.lifecycle.respawn_at = "alive", nil
  s.lifecycle.spawn_block_reason, s.lifecycle.last_spawn_tick = nil, game.tick
  restore_inventory(s, character)
  append_event(s, "agent_respawned", {
    unit_number = character.unit_number, surface = surface.name, position = character.position,
    death_count = s.lifecycle.death_count or 0, reason = reason,
  })
  return true
end

function M.initialize(s)
  s.lifecycle = s.lifecycle or {death_count = 0, status = "uninitialized"}
  recovery_bags(s)
  if s.agent and s.agent.valid then
    s.agent_unit_number, s.lifecycle.status = s.agent.unit_number, "alive"
    return
  end
  if s.lifecycle.status == "dead" or s.lifecycle.status == "respawning"
    or s.lifecycle.status == "waiting_for_safe_spawn" then return end
  spawn(s, "initialization")
end

function M.set_home(s, p)
  assert(type(p.surface) == "string" and game.surfaces[p.surface], "Unknown surface")
  assert(type(p.position) == "table" and type(p.position.x) == "number"
    and type(p.position.y) == "number", "position must contain numeric x and y")
  local surface = game.surfaces[p.surface]
  local position = surface.find_non_colliding_position("character", p.position, 16, 0.5)
  assert(position, "No collision-free character position near requested home")
  local threats = surface.find_entities_filtered({
    position = position, radius = HOME_DANGER_RADIUS, force = game.forces.enemy,
    type = {"unit", "unit-spawner", "turret", "ammo-turret", "electric-turret", "fluid-turret"},
  })
  assert(#threats == 0, "Requested home is within the enemy danger radius")
  s.home = {surface_index = surface.index, position = position}
  return {surface = surface.name, position = position}
end

function M.on_died(s, event)
  local entity = event.entity
  if not entity or not s.agent then return false end
  local is_agent = entity == s.agent
  if not is_agent and s.agent_unit_number then is_agent = entity.unit_number == s.agent_unit_number end
  if not is_agent then return false end
  local moved = capture_dropped_items(s, event)
  s.lifecycle = s.lifecycle or {death_count = 0}
  s.lifecycle.death_count = (s.lifecycle.death_count or 0) + 1
  s.lifecycle.status, s.lifecycle.last_death_tick = "dead", game.tick
  s.lifecycle.respawn_at, s.lifecycle.death_position = game.tick + RESPAWN_DELAY, entity.position
  s.lifecycle.death_surface_index = entity.surface.index
  s.lifecycle.recovered_items = (s.lifecycle.recovered_items or 0) + moved
  s.agent, s.agent_unit_number = nil, nil
  append_event(s, "agent_died", {
    cause = event.cause and event.cause.name or nil,
    damage_type = event.damage_type and event.damage_type.name or nil,
    position = s.lifecycle.death_position, surface_index = s.lifecycle.death_surface_index,
    recovered_items = moved, death_count = s.lifecycle.death_count,
  })
  return true
end

function M.tick(s)
  local lifecycle = s.lifecycle
  if s.agent and s.agent.valid and lifecycle
    and game.tick - (lifecycle.last_recovery_restore_tick or 0) >= 60 then
    lifecycle.last_recovery_restore_tick = game.tick
    restore_inventory(s, s.agent)
  end
  if lifecycle and (lifecycle.status == "dead" or lifecycle.status == "respawning"
    or lifecycle.status == "waiting_for_safe_spawn") and lifecycle.respawn_at
    and game.tick >= lifecycle.respawn_at then
    lifecycle.status = "respawning"
    spawn(s, "death_recovery")
  elseif (not s.agent or not s.agent.valid) and (not lifecycle or lifecycle.status == "uninitialized") then
    M.initialize(s)
  elseif s.agent and not s.agent.valid and lifecycle and lifecycle.status == "alive" then
    s.agent, s.agent_unit_number = nil, nil
    lifecycle.death_count = (lifecycle.death_count or 0) + 1
    lifecycle.status, lifecycle.last_death_tick = "dead", game.tick
    lifecycle.respawn_at, lifecycle.death_position = game.tick + RESPAWN_DELAY, nil
    lifecycle.death_surface_index = nil
    s.safety = s.safety or {}
    s.safety.active, s.safety.status, s.safety.reason = true, "respawning", "agent_lost"
    s.safety.started_tick = s.safety.started_tick or game.tick
    s.safety.destination, s.safety.path, s.safety.path_request = nil, nil, nil
    if s.task and s.task.status == "running" then
      s.task.status, s.task.pause_reason = "paused", "death"
      s.task.phase, s.task.target, s.task.path = "search", nil, nil
    end
    append_event(s, "agent_lost", {reason = "entity_removed_without_death_event"})
  end
end

function M.status(s)
  local agent = s.agent and s.agent.valid and s.agent or nil
  local bags, recovery_count = recovery_bags(s), 0
  for _, bag in pairs(bags) do recovery_count = recovery_count + bag.get_item_count() end
  return {
    status = s.lifecycle and s.lifecycle.status or "uninitialized",
    unit_number = agent and agent.unit_number or nil,
    surface = agent and agent.surface.name or nil,
    position = agent and agent.position or (s.lifecycle and s.lifecycle.death_position) or nil,
    health = agent and agent.health or nil,
    death_count = s.lifecycle and s.lifecycle.death_count or 0,
    respawn_at_tick = s.lifecycle and s.lifecycle.respawn_at or nil,
    spawn_block_reason = s.lifecycle and s.lifecycle.spawn_block_reason or nil,
    recovery_item_count = recovery_count,
  }
end

function M.events(s, limit, after_id)
  local events, out = s.events or {}, {}
  local maximum, cursor = math.max(1, math.min(limit or 20, 100)), math.max(0, after_id or 0)
  for _, event in ipairs(events) do
    if event.id > cursor and #out < maximum then out[#out + 1] = event end
  end
  return {
    events = out, total = #events, latest_id = s.next_event_id or 0,
    has_more = #out == maximum and out[#out].id < (s.next_event_id or 0),
  }
end

return M
