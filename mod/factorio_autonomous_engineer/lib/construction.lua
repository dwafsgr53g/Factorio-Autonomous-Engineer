-- Construction through ordinary Factorio ghost entities.
--
-- The agent is a LuaEntity character, not a LuaPlayer, so LuaControl.build_from_cursor
-- does not exist for it. A ghost is revived with LuaEntity.revive(), which is a script
-- operation and does not charge the normal construction cost. This module therefore
-- computes the exact material cost, removes only those items from the character's main
-- inventory, verifies every removal, and only then revives the ghost. A failed revival
-- refunds the exact removed stacks. No surface.create_entity call is used for a real
-- building.
local clearing = require("lib.clearing")

local M = {}

local BUILD_RANGE = 9.0
local APPROACH_STEP = 0.5

local TEST_PLANS = {
  test_basic = {
    {name = "stone-furnace", offset = {x = 8, y = 0}},
    {name = "wooden-chest", offset = {x = 10, y = 0}},
    {name = "transport-belt", offset = {x = 12, y = 0}, direction = defines.direction.east},
  },
  single_furnace = {
    {name = "stone-furnace", offset = {x = 8, y = 0}},
  },
}

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function quality_name(entity)
  return entity.quality and entity.quality.name or "normal"
end

local function requirement_key(name, quality)
  return name .. ":" .. tostring(quality or "normal")
end

local function add_requirement(map, list, name, count, quality)
  if type(name) ~= "string" or type(count) ~= "number" or count <= 0 then return end
  local key = requirement_key(name, quality)
  local existing = map[key]
  if existing then
    existing.count = existing.count + count
  else
    local requirement = {name = name, count = count, quality = quality or "normal"}
    map[key] = requirement
    list[#list + 1] = requirement
  end
end

-- Return the exact items the ghost will request, or a reason why this ghost type is
-- unsupported. Player blueprint ghosts normally expose item_requests. Script-created
-- ghosts have an empty item_requests list, so their prototype build cost is used.
function M.requirements(ghost)
  if not ghost or not ghost.valid then return nil, "invalid_ghost" end
  if ghost.type ~= "entity-ghost" then return nil, "not_an_entity_ghost" end
  if ghost.ghost_type == "tile" or ghost.type == "tile-ghost" then
    return nil, "unsupported_tile_ghost"
  end
  if ghost.insert_plan and #ghost.insert_plan > 0 then
    -- Modules, equipment and ammunition requests need an item-request proxy; the
    -- first construction version deliberately refuses them instead of dropping them.
    return nil, "unsupported_ghost_insert_plan"
  end
  local map, list = {}, {}
  local prototype = prototypes.entity[ghost.ghost_name]
  if not prototype then return nil, "unknown_entity" end
  local base_items = prototype.items_to_place_this
  if not base_items or #base_items == 0 then return nil, "no_placeable_item" end
  local base_counts = {}
  for _, item in pairs(base_items) do
    base_counts[item.name] = (base_counts[item.name] or 0) + item.count
  end
  local requested = ghost.item_requests
  if requested and #requested > 0 then
    local requested_counts = {}
    for _, request in pairs(requested) do
      if not prototypes.item[request.name] then return nil, "unknown_item" end
      requested_counts[request.name] = (requested_counts[request.name] or 0) + request.count
      add_requirement(map, list, request.name, request.count,
        request.quality or quality_name(ghost))
    end
    -- Modules, equipment and other extra requests are not revived by this version, so
    -- refuse them instead of charging for items that would be left in a proxy request.
    for name, count in pairs(requested_counts) do
      if (base_counts[name] or 0) ~= count then
        return nil, "unsupported_extra_item_requests"
      end
    end
    for name, count in pairs(base_counts) do
      if (requested_counts[name] or 0) ~= count then
        return nil, "unsupported_extra_item_requests"
      end
    end
  else
    for _, item in pairs(base_items) do
      if not prototypes.item[item.name] then return nil, "unknown_item" end
      add_requirement(map, list, item.name, item.count, quality_name(ghost))
    end
  end
  if #list == 0 then return nil, "no_requirements" end
  for _, item in pairs(list) do
    if type(item.name) ~= "string" or type(item.count) ~= "number" or item.count <= 0 then
      return nil, "invalid_requirement"
    end
  end
  table.sort(list, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.quality < b.quality
  end)
  return list
end

function M.count_item(inventory, item)
  if not inventory then return 0 end
  return inventory.get_item_count{name = item.name, quality = item.quality}
end

function M.missing(agent, requirements)
  local inventory = agent and agent.get_main_inventory()
  local result = {}
  if not inventory then return result end
  for _, requirement in pairs(requirements or {}) do
    local have = M.count_item(inventory, requirement)
    if have < requirement.count then
      result[#result + 1] = {
        name = requirement.name, count = requirement.count - have,
        quality = requirement.quality,
      }
    end
  end
  return result
end

function M.can_carry_any(agent, items)
  local inventory = agent and agent.get_main_inventory()
  if not inventory then return false end
  for _, item in pairs(items or {}) do
    if inventory.can_insert{name = item.name, count = 1, quality = item.quality} then
      return true
    end
  end
  return false
end

local function refund(agent, removed)
  local inventory = agent and agent.get_main_inventory()
  if not inventory then return false end
  local complete = true
  for _, item in pairs(removed or {}) do
    local inserted = inventory.insert{
      name = item.name, count = item.count, quality = item.quality,
    }
    if inserted ~= item.count then complete = false end
  end
  return complete
end

-- Consume exactly the required stacks. If any individual removal is short, all
-- already removed stacks are returned and the build is aborted.
function M.consume(agent, requirements)
  local inventory = agent and agent.get_main_inventory()
  if not inventory then return false, "agent_has_no_main_inventory" end
  if #M.missing(agent, requirements) > 0 then return false, "missing_material" end
  local removed = {}
  for _, requirement in pairs(requirements) do
    local count = inventory.remove{
      name = requirement.name, count = requirement.count, quality = requirement.quality,
    }
    if count ~= requirement.count then
      if count > 0 then
        removed[#removed + 1] = {
          name = requirement.name, count = count, quality = requirement.quality,
        }
      end
      refund(agent, removed)
      return false, "material_removal_race"
    end
    removed[#removed + 1] = {
      name = requirement.name, count = count, quality = requirement.quality,
    }
  end
  return true, removed
end

function M.refund(agent, removed)
  return refund(agent, removed)
end

-- Move only the still-missing items from an ordinary chest. The caller has already
-- walked the character into interaction range. Items are removed from the chest and
-- inserted into the character inventory in one tick; a failed insertion is returned to
-- the chest immediately.
function M.take_from_chest(agent, chest, missing)
  local transferred, reason = {}, nil
  if not chest or not chest.valid then return transferred, "chest_unavailable" end
  local chest_inventory = chest.get_inventory(defines.inventory.chest)
  local main = agent and agent.get_main_inventory()
  if not chest_inventory or not main then return transferred, "inventory_unavailable" end
  for _, item in pairs(missing or {}) do
    local available = chest_inventory.get_item_count{
      name = item.name, quality = item.quality,
    }
    if available > 0 then
      local wanted = math.min(available, item.count)
      if not main.can_insert{name = item.name, count = 1, quality = item.quality} then
        reason = "inventory_full"
      else
        local removed = chest_inventory.remove{
          name = item.name, count = wanted, quality = item.quality,
        }
        if removed > 0 then
          local inserted = main.insert{
            name = item.name, count = removed, quality = item.quality,
          }
          if inserted < removed then
            local returned = chest_inventory.insert{
              name = item.name, count = removed - inserted, quality = item.quality,
            }
            if returned < removed - inserted then reason = "item_transfer_incomplete" end
          end
          if inserted > 0 then
            transferred[#transferred + 1] = {
              name = item.name, count = inserted, quality = item.quality,
            }
          end
          if inserted < removed and not reason then reason = "inventory_full" end
        elseif removed == 0 then
          reason = "chest_changed_during_transfer"
        end
      end
    end
  end
  return transferred, reason
end

function M.find_chest_inventory(chest)
  if not chest or not chest.valid then return nil end
  local ok, inventory = pcall(function() return chest.get_inventory(defines.inventory.chest) end)
  if ok then return inventory end
  return nil
end

function M.chest_with_items(surface, area, missing, agent)
  local chests = surface.find_entities_filtered{
    area = area, type = {"container", "logistic-container"},
  }
  local best, best_distance
  for _, chest in pairs(chests) do
    if chest.valid and chest.name ~= "infinity-chest" then
      local inventory = M.find_chest_inventory(chest)
      if inventory then
        local has_any = false
        for _, item in pairs(missing or {}) do
          if inventory.get_item_count{name = item.name, quality = item.quality} > 0 then
            has_any = true
            break
          end
        end
        if has_any then
          local current = distance(agent.position, chest.position)
          if not best_distance or current < best_distance then
            best, best_distance = chest, current
          end
        end
      end
    end
  end
  return best
end

function M.request_path(agent, goal)
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

-- Find a walkable position on a ring around the target. The character must not stand on
-- the ghost tile, because a character collision would make the real placement fail.
function M.approach(surface, position, padding, agent)
  if not surface or not position or not agent then return nil end
  local candidates = {}
  for radius = padding, padding + 4, APPROACH_STEP do
    local steps = 24
    for index = 0, steps - 1 do
      local angle = index * (2 * math.pi / steps)
      local candidate = {
        x = position.x + math.cos(angle) * radius,
        y = position.y + math.sin(angle) * radius,
      }
      if surface.can_place_entity{
        name = "character", position = candidate, force = agent.force,
      } then
        candidates[#candidates + 1] = candidate
      end
    end
  end
  table.sort(candidates, function(a, b)
    local da, db = distance(a, position), distance(b, position)
    if math.abs(da - db) > 0.25 then return da < db end
    return distance(agent.position, a) < distance(agent.position, b)
  end)
  return candidates[1]
end

function M.approach_for_entity(surface, entity, agent)
  if not entity or not entity.valid then return nil end
  local box = entity.bounding_box
  local half = math.max(
    math.abs(box.left_top.x - entity.position.x),
    math.abs(box.right_bottom.x - entity.position.x),
    math.abs(box.left_top.y - entity.position.y),
    math.abs(box.right_bottom.y - entity.position.y)
  )
  return M.approach(surface, entity.position, math.max(2.0, half + 1.0), agent)
end

function M.build(agent, ghost)
  if not ghost or not ghost.valid then return false, "ghost_gone" end
  if not agent or not agent.valid then return false, "agent_unavailable" end
  if distance(agent.position, ghost.position) > BUILD_RANGE then return false, "out_of_reach" end
  local requirements, reason = M.requirements(ghost)
  if not requirements then return false, reason end
  if not ghost.surface.can_place_entity{
    name = ghost.ghost_name, position = ghost.position, direction = ghost.direction,
    force = agent.force, build_check_type = defines.build_check_type.ghost_revive,
  } then
    return false, "blocked"
  end
  local paid, payment = M.consume(agent, requirements)
  if not paid then return false, payment or "missing_material" end
  local surface, ghost_name, ghost_position = ghost.surface, ghost.ghost_name, ghost.position
  local ok, _collided, entity, proxy = pcall(function() return ghost.revive() end)
  if not ok or not entity or not entity.valid then
    -- A script error after the engine created the real entity must not result in both a
    -- refund and a free building. Detect the entity before refunding the payment.
    local built = M.find_real_entity(surface, ghost_name, ghost_position)
    if built then return true, "revive_raised_but_built", built end
    M.refund(agent, payment)
    return false, "revive_failed"
  end
  if ghost.valid then
    -- This should not occur in Factorio 2.1.24. The real entity and the ghost both exist,
    -- so the paid materials are not refunded; the caller records an explicit
    -- inconsistent state for the next strategic decision instead of silently duplicating.
    return true, "revive_inconsistent", entity, proxy
  end
  return true, nil, entity, proxy
end

function M.obstacles(ghost, agent)
  local clearable, blocking, players = {}, {}, {}
  if not ghost or not ghost.valid then return clearable, blocking, players end
  local box = ghost.bounding_box
  local entities = ghost.surface.find_entities_filtered{
    area = {
      {x = box.left_top.x, y = box.left_top.y},
      {x = box.right_bottom.x, y = box.right_bottom.y},
    },
  }
  for _, entity in pairs(entities) do
    if entity.valid and entity ~= ghost then
      local is_agent = agent and entity.unit_number and agent.unit_number
        and entity.unit_number == agent.unit_number
      if not is_agent then
        if entity.type == "resource" or entity.type == "item-entity"
          or entity.type == "corpse" or entity.type == "smoke"
          or entity.type == "entity-ghost" or entity.type == "tile-ghost"
          or entity.type == "fish" then
          -- Resources and loose items do not block placement. Other ghosts are separate
          -- work and are reconciled by the collaboration scanner.
        elseif entity.type == "character" then
          players[#players + 1] = entity
        elseif clearing.is_clearable(entity) then
          clearable[#clearable + 1] = entity
        else
          blocking[#blocking + 1] = entity
        end
      end
    end
  end
  return clearable, blocking, players
end

function M.find_real_entity(surface, name, position)
  local entities = surface.find_entities_filtered{
    area = {
      {x = position.x - 2, y = position.y - 2},
      {x = position.x + 2, y = position.y + 2},
    },
    name = name,
  }
  local best, best_distance
  for _, entity in pairs(entities) do
    if entity.valid and entity.type ~= "entity-ghost" then
      local current = distance(entity.position, position)
      if current <= 1.5 and (not best_distance or current < best_distance) then
        best, best_distance = entity, current
      end
    end
  end
  return best
end

local function find_plan_position(surface, force, object, desired)
  for _, offset in pairs({
    {x = 0, y = 0}, {x = 0, y = 2}, {x = 2, y = 0}, {x = -2, y = 0}, {x = 0, y = -2},
    {x = 2, y = 2}, {x = -2, y = 2}, {x = 2, y = -2}, {x = -2, y = -2},
    {x = 4, y = 0}, {x = 0, y = 4}, {x = -4, y = 0}, {x = 0, y = -4},
  }) do
    local position = {x = desired.x + offset.x, y = desired.y + offset.y}
    if surface.can_place_entity{
      name = object.name, position = position, direction = object.direction or defines.direction.north,
      force = force,
    } then
      return position
    end
  end
  return nil
end

-- Place a named, code-owned test plan. No real entity is created and no item is spent.
function M.place_plan(s, plan_name)
  local agent = s.agent
  assert(agent and agent.valid, "Agent is not alive")
  local plan = TEST_PLANS[plan_name]
  assert(plan, "Unknown construction plan")
  local surface = agent.surface
  local center = agent.position
  if s.home and s.home.surface_index == surface.index then center = s.home.position end
  local placed, failures = {}, {}
  for _, object in pairs(plan) do
    local desired = {
      x = center.x + (object.offset and object.offset.x or 0),
      y = center.y + (object.offset and object.offset.y or 0),
    }
    local position = find_plan_position(surface, agent.force, object, desired)
    if position then
      local ok, ghost = pcall(function()
        return surface.create_entity{
          name = "entity-ghost", inner_name = object.name, position = position,
          direction = object.direction or defines.direction.north, force = agent.force,
          quality = "normal",
        }
      end)
      if ok and ghost and ghost.valid then
        placed[#placed + 1] = {
          unit_number = ghost.unit_number, name = object.name, position = position,
        }
      else
        failures[#failures + 1] = {name = object.name, reason = "ghost_create_failed"}
      end
    else
      failures[#failures + 1] = {name = object.name, reason = "no_free_position"}
    end
  end
  return {
    success = #failures == 0 and #placed == #plan,
    plan = plan_name, ghosts_placed = #placed, expected = #plan,
    failures = failures,
  }
end

function M.plans()
  local names = {}
  for name in pairs(TEST_PLANS) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function M.build_range()
  return BUILD_RANGE
end

return M
