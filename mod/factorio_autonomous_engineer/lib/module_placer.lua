-- Deterministic module instantiation. Validated module definitions are turned into
-- ordinary entity-ghost objects only. No real entity is created, no item is spent and the
-- Stage-3 construction executor remains the only paid build path.
local construction = require("lib.construction")
local clearing = require("lib.clearing")
local format = require("lib.module_format")
local modules = require("lib.modules")

local M = {}

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

local function absolute_bounds(anchor, footprint)
  return {
    {x = anchor.x, y = anchor.y},
    {x = anchor.x + footprint.width, y = anchor.y + footprint.height},
  }
end

local function absolute_area(anchor, area)
  return {
    {x = anchor.x + area.x, y = anchor.y + area.y},
    {x = anchor.x + area.x + area.width, y = anchor.y + area.y + area.height},
  }
end

local function entity_absolute(anchor, entity)
  return {x = anchor.x + entity.position.x, y = anchor.y + entity.position.y}
end

local function port_absolute(anchor, port)
  return {x = anchor.x + port.position.x, y = anchor.y + port.position.y}
end

-- Return the hard blockers and clearable obstacles inside an area. Resources, loose
-- items, corpses, smoke and ghosts do not block ghost placement. Trees and rocks are
-- reported separately because the existing executor can clear them.
local function scan_obstacles(surface, area, agent)
  local clearable, blocking = {}, {}
  local entities = surface.find_entities_filtered{area = area}
  for _, entity in pairs(entities) do
    if entity.valid then
      local is_agent = agent and entity.unit_number and agent.unit_number
        and entity.unit_number == agent.unit_number
      if not is_agent then
        if entity.type == "resource" or entity.type == "item-entity"
          or entity.type == "corpse" or entity.type == "smoke"
          or entity.type == "entity-ghost" or entity.type == "tile-ghost"
          or entity.type == "fish" then
          -- Not a hard blocker for a ghost.
        elseif entity.type == "character" then
          blocking[#blocking + 1] = entity
        elseif clearing.is_clearable(entity) then
          clearable[#clearable + 1] = entity
        else
          blocking[#blocking + 1] = entity
        end
      end
    end
  end
  return clearable, blocking
end

local function constraint_failure(code, message, details)
  return {code = code, message = message, details = details}
end

local function check_placement_constraints(def, context, request)
  local failures = {}
  local bounds = request.absolute_bounds
  local area = {bounds[1], bounds[2]}
  for _, constraint in ipairs(def.placement.constraints or {}) do
    if constraint.type == "resource_patch" then
      local resources = context.surface.find_entities_filtered{
        area = area, name = constraint.resource, type = "resource",
      }
      local amount, count = 0, 0
      for _, resource in pairs(resources) do
        if resource.valid and resource.amount > 0 then
          amount = amount + resource.amount
          count = count + 1
        end
      end
      local minimum_amount = constraint.minimum_amount or 1
      local minimum_entities = constraint.minimum_entities or 1
      if amount < minimum_amount or count < minimum_entities then
        failures[#failures + 1] = constraint_failure("resource_patch_missing",
          "module requires " .. constraint.resource .. " inside its footprint",
          {amount = amount, entities = count, required_amount = minimum_amount,
            required_entities = minimum_entities})
      end
    elseif constraint.type == "near_water" then
      local max_distance = constraint.max_distance or 32
      local expanded = {
        {x = bounds[1].x - max_distance, y = bounds[1].y - max_distance},
        {x = bounds[2].x + max_distance, y = bounds[2].y + max_distance},
      }
      local water = context.surface.find_tiles_filtered{
        area = expanded, name = {"water", "deepwater"},
      }
      if #water == 0 then
        failures[#failures + 1] = constraint_failure("water_missing",
          "module requires water within " .. max_distance .. " tiles")
      end
    elseif constraint.type == "avoid_entities" then
      local found = {}
      if constraint.types then
        for _, entity in pairs(context.surface.find_entities_filtered{
          area = area, type = constraint.types}) do
          if entity.valid and entity.type ~= "entity-ghost" then
            found[entity.name] = (found[entity.name] or 0) + 1
          end
        end
      end
      if constraint.names then
        for _, entity in pairs(context.surface.find_entities_filtered{
          area = area, name = constraint.names}) do
          if entity.valid and entity.type ~= "entity-ghost" then
            found[entity.name] = (found[entity.name] or 0) + 1
          end
        end
      end
      if next(found) then
        failures[#failures + 1] = constraint_failure("avoid_entities_violated",
          "module footprint contains entities it must avoid", found)
      end
    elseif constraint.type == "avoid_tiles" then
      local tiles = context.surface.find_tiles_filtered{
        area = area, name = constraint.names,
      }
      if #tiles > 0 then
        local found = {}
        for _, tile in pairs(tiles) do found[tile.name] = (found[tile.name] or 0) + 1 end
        failures[#failures + 1] = constraint_failure("avoid_tiles_violated",
          "module footprint contains tiles it must avoid", found)
      end
    elseif constraint.type == "electric_network" then
      local max_distance = constraint.max_distance or 16
      local expanded = {
        {x = bounds[1].x - max_distance, y = bounds[1].y - max_distance},
        {x = bounds[2].x + max_distance, y = bounds[2].y + max_distance},
      }
      local poles = context.surface.find_entities_filtered{
        area = expanded, type = "electric-pole",
      }
      local connected = 0
      for _, pole in pairs(poles) do
        if pole.valid and pole.electric_network_id then connected = connected + 1 end
      end
      if connected == 0 then
        failures[#failures + 1] = constraint_failure("electric_network_missing",
          "module requires an existing electric network within " .. max_distance .. " tiles")
      end
    elseif constraint.type == "clear_footprint" then
      -- The universal hard-blocker scan below enforces this constraint.
    end
  end
  return failures
end

-- Entity ghosts do not have the get-by-unit-number prototype flag, so they cannot be
-- looked up through game.get_entity_by_unit_number in 2.1.24. Search the local area and
-- match the stable unit number instead.
local function find_live_entity(surface, unit_number, position)
  if not surface or not unit_number then return nil end
  local direct = game.get_entity_by_unit_number(unit_number)
  if direct and direct.valid then return direct end
  local entities = surface.find_entities_filtered{
    area = {{position.x - 2, position.y - 2}, {position.x + 2, position.y + 2}},
  }
  for _, entity in pairs(entities) do
    if entity.valid and entity.unit_number == unit_number then return entity end
  end
  return nil
end

local function ghost_records(surface, area, ignore_plan_id)
  local ghosts = {}
  for _, entity in pairs(surface.find_entities_filtered{
    area = area, type = "entity-ghost"}) do
    if entity.valid then
      local plan_tag = entity.tags and entity.tags.ae_plan_id or nil
      if not (ignore_plan_id and plan_tag == ignore_plan_id) then
        ghosts[#ghosts + 1] = {name = entity.ghost_name, position = entity.position,
          unit_number = entity.unit_number, plan_id = plan_tag}
      end
    end
  end
  return ghosts
end

local function overlaps_live_instance(s, surface, anchor, footprint, ignore_instance_keys)
  for _, existing in pairs(s.modules and s.modules.instances or {}) do
    local existing_surface = game.surfaces[existing.surface_index]
    if not (ignore_instance_keys and ignore_instance_keys[existing.key])
      and existing_surface == surface then
      local ex_left = existing.anchor.x - 0.5
      local ex_top = existing.anchor.y - 0.5
      local ex_right = existing.anchor.x + existing.footprint.width + 0.5
      local ex_bottom = existing.anchor.y + existing.footprint.height + 0.5
      if anchor.x < ex_right and ex_left < anchor.x + footprint.width
        and anchor.y < ex_bottom and ex_top < anchor.y + footprint.height then
        -- Only live instances with at least one ghost or real entity block the area.
        for _, entity in ipairs(existing.entities) do
          local live = find_live_entity(existing_surface, entity.unit_number, entity.position)
          if (live and live.valid and live.type == "entity-ghost")
            or construction.find_real_entity(existing_surface, entity.name,
              entity.position) then
            return true
          end
        end
      end
    end
  end
  return false
end

local function instance_status(s, instance)
  local surface = game.surfaces[instance.surface_index]
  local entities, counts = {}, {pending = 0, built = 0, missing = 0,
    configuration_mismatch = 0, geometry_mismatch = 0}
  if not surface then
    return {key = instance.key, module_id = instance.module_id, status = "surface_missing",
      entities = {}, counts = counts}
  end
  for _, entity in ipairs(instance.entities) do
    local live = find_live_entity(surface, entity.unit_number, entity.position)
    local status, recipe = nil, nil
    if live and live.valid and live.type == "entity-ghost" then
      status = "pending"
    else
      local real = construction.find_real_entity(surface, entity.name, entity.position)
      if real then
        status = "built"
        if real.direction ~= entity.direction then
          status = "geometry_mismatch"
        end
        if entity.recipe and real.type == "assembling-machine" then
          local ok, value = pcall(function() return real.get_recipe() end)
          recipe = ok and value and value.name or nil
          if recipe ~= entity.recipe then
            status = "configuration_mismatch"
          end
        end
      else
        status = "missing"
      end
    end
    counts[status] = (counts[status] or 0) + 1
    entities[#entities + 1] = {
      id = entity.id, name = entity.name, status = status,
      recipe = recipe, expected_recipe = entity.recipe,
      unit_number = entity.unit_number,
    }
  end
  local status = "pending"
  if counts.configuration_mismatch > 0 then
    status = "configuration_mismatch"
  elseif counts.geometry_mismatch > 0 then
    status = "geometry_mismatch"
  elseif counts.missing > 0 and counts.built == 0 and counts.pending == 0 then
    status = "missing"
  elseif counts.built + counts.configuration_mismatch + counts.geometry_mismatch
    == #instance.entities then
    status = "built"
  elseif counts.pending > 0 and counts.built > 0 then
    status = "partially_built"
  elseif counts.pending > 0 then
    status = "pending"
  end
  return {
    key = instance.key, module_id = instance.module_id,
    module_version = instance.module_version, status = status,
    anchor = instance.anchor, orientation = instance.orientation,
    parameters = instance.parameters, footprint = instance.footprint,
    entities = entities, counts = counts,
  }
end

function M.resolve(s, p)
  local agent = s.agent
  if not agent or not agent.valid then return nil, "agent_unavailable" end
  local surface = agent.surface
  if p.surface and p.surface ~= surface.name then
    return nil, "module_instances_use_agent_surface"
  end
  local entry, errors
  if p.definition then
    -- Internal planning path: the catalog was already loaded and validated once. No
    -- second definition source exists; this only avoids re-running the catalog scan for
    -- every bounded placement candidate.
    entry = {definition = p.definition, availability = {available = true},
      availability_reasons = {}}
  else
    local env = {
      prototypes = prototypes, force = agent.force, surface = surface,
      stage = p.stage,
    }
    entry, errors = modules.resolve(env, p.module_id)
    if not entry then return nil, "module_not_found", errors end
    if not entry.availability.available then
      return nil, "module_unavailable", entry.availability.reasons
    end
  end
  if type(p.anchor) ~= "table" or type(p.anchor.x) ~= "number"
    or type(p.anchor.y) ~= "number" then
    return nil, "invalid_anchor"
  end
  if p.anchor.x % 1 ~= 0 or p.anchor.y % 1 ~= 0 then
    return nil, "anchor_must_be_on_a_tile_corner"
  end
  local orientation = p.orientation or 0
  local expanded, expand_errors = format.expand(entry.definition, p.parameters or {}, orientation)
  if not expanded then return nil, "invalid_parameters", expand_errors end
  local anchor = {x = p.anchor.x, y = p.anchor.y}
  local entities, ports, reserved = {}, {}, {}
  for _, entity in ipairs(expanded.entities) do
    entities[#entities + 1] = {
      id = entity.id, name = entity.name, position = entity_absolute(anchor, entity),
      direction = entity.direction, quality = entity.quality, recipe = entity.recipe,
    }
  end
  for _, port in ipairs(expanded.ports) do
    ports[#ports + 1] = {
      id = port.id, type = port.type, role = port.role,
      position = port_absolute(anchor, port), direction = port.direction,
      item = port.item, fluid = port.fluid, connector = port.connector,
    }
  end
  for _, area in ipairs(expanded.reserved) do
    reserved[#reserved + 1] = {id = area.id, area = absolute_area(anchor, area.area),
      reason = area.reason}
  end
  return {
    module = format.summary(entry.definition),
    definition = entry.definition,
    parameters = expanded.parameters,
    orientation = orientation,
    anchor = anchor,
    footprint = expanded.footprint,
    absolute_bounds = absolute_bounds(anchor, expanded.footprint),
    entities = entities, ports = ports, reserved = reserved,
    cost_estimate = format.cost_estimate(entry.definition, p.parameters or {}, orientation),
  }
end

-- Pure, non-mutating world validation for a module placement. The Layout Planner uses
-- this for bounded candidate evaluation; it creates no ghost and changes no state.
function M.evaluate(s, p)
  local resolved, reason, details = M.resolve(s, p)
  if not resolved then
    return {ok = false, reason = reason, details = details}
  end
  local agent = s.agent
  local surface = agent.surface
  local bounds = resolved.absolute_bounds
  local clearable, blocking = scan_obstacles(surface, {bounds[1], bounds[2]}, agent)
  local players, hard_blocking = {}, {}
  local function classify(entity)
    if entity.type == "character" then
      players[#players + 1] = entity
    else
      hard_blocking[#hard_blocking + 1] = entity
    end
  end
  for _, entity in ipairs(blocking) do classify(entity) end
  for _, area in ipairs(resolved.reserved) do
    local found_clearable, found_blocking = scan_obstacles(surface, area.area, agent)
    for _, entity in ipairs(found_clearable) do clearable[#clearable + 1] = entity end
    for _, entity in ipairs(found_blocking) do classify(entity) end
  end
  local ghost_conflicts = ghost_records(surface, {bounds[1], bounds[2]}, p.ignore_plan_id)
  for _, area in ipairs(resolved.reserved) do
    for _, ghost in ipairs(ghost_records(surface, area.area, p.ignore_plan_id)) do
      ghost_conflicts[#ghost_conflicts + 1] = ghost
    end
  end
  local failures = check_placement_constraints(resolved.definition, {
    surface = surface, anchor = resolved.anchor, absolute_bounds = bounds,
  }, {absolute_bounds = bounds})
  local terrain_failures = {}
  for _, entity in ipairs(resolved.entities) do
    local can_place = surface.can_place_entity{
      name = entity.name, position = entity.position, direction = entity.direction,
      force = agent.force, build_check_type = defines.build_check_type.script_ghost,
    }
    if not can_place then terrain_failures[#terrain_failures + 1] = entity.name end
  end
  local overlap = overlaps_live_instance(s, surface, resolved.anchor, resolved.footprint,
    p.ignore_instance_keys)
  local ok = #hard_blocking == 0 and #ghost_conflicts == 0 and #players == 0
    and #failures == 0 and not overlap
    and not (#terrain_failures > 0 and #clearable == 0)
  local first_reason = nil
  if overlap then first_reason = "module_instance_overlap"
  elseif #hard_blocking > 0 then first_reason = "blocked_by_existing_entity"
  elseif #ghost_conflicts > 0 then first_reason = "existing_ghost"
  elseif #players > 0 then first_reason = "player_in_footprint"
  elseif #failures > 0 then first_reason = "constraint_failed"
  elseif #terrain_failures > 0 and #clearable == 0 then first_reason = "blocked_terrain" end
  return {
    ok = ok, reason = first_reason, resolved = resolved,
    clearable = clearable, blocking = hard_blocking, players = players,
    ghosts = ghost_conflicts, constraint_failures = failures,
    terrain_failures = terrain_failures, module_instance_overlap = overlap,
    needs_clearing = #clearable > 0,
  }
end

function M.instantiate(s, p)
  local agent = s.agent
  if not agent or not agent.valid then return nil, "agent_unavailable" end
  local surface = agent.surface
  if p.surface and p.surface ~= surface.name then
    return nil, "module_instances_use_agent_surface"
  end
  if type(p.instance_key) ~= "nil" then
    if type(p.instance_key) ~= "string" or p.instance_key == ""
      or string.find(p.instance_key, "[^%w_%.:%-]") then
      return nil, "invalid_instance_key"
    end
  end
  local env = {
    prototypes = prototypes, force = agent.force, surface = surface, stage = p.stage,
  }
  local entry, resolve_errors = modules.resolve(env, p.module_id)
  if not entry then return nil, "module_not_found", resolve_errors end
  if not entry.availability.available then
    return nil, "module_unavailable", entry.availability.reasons
  end
  if type(p.anchor) ~= "table" or type(p.anchor.x) ~= "number"
    or type(p.anchor.y) ~= "number" then
    return nil, "invalid_anchor"
  end
  if p.anchor.x % 1 ~= 0 or p.anchor.y % 1 ~= 0 then
    return nil, "anchor_must_be_on_a_tile_corner"
  end
  local anchor = {x = p.anchor.x, y = p.anchor.y}
  local orientation = p.orientation or 0
  local expanded, expand_errors = format.expand(entry.definition, p.parameters or {}, orientation)
  if not expanded then return nil, "invalid_parameters", expand_errors end

  s.modules = s.modules or {instances = {}, by_key = {}, next_instance_id = 0}
  local fingerprint = entry.definition.id .. "|" .. tostring(anchor.x) .. ","
    .. tostring(anchor.y) .. "|" .. tostring(orientation) .. "|"
    .. sorted_parameter_string(expanded.parameters)
  -- A stale persisted instance whose ghosts and real entities are both gone must not
  -- suppress a fresh ghost creation. This matters after a save was made from a world
  -- where a test fixture removed its ghosts, and after a player cancels a module.
  local function forget_instance(existing)
    s.modules.by_key[existing.key] = nil
    for index = #s.modules.instances, 1, -1 do
      if s.modules.instances[index] == existing then
        table.remove(s.modules.instances, index)
        break
      end
    end
  end
  if p.instance_key then
    local existing = s.modules.by_key[p.instance_key]
    if existing then
      if existing.fingerprint ~= fingerprint then
        return nil, "instance_key_conflict"
      end
      local status = instance_status(s, existing)
      if status.status ~= "missing" then
        return {deduplicated = true, instance = status, fingerprints = fingerprint}
      end
      forget_instance(existing)
    end
  end
  for _, existing in pairs(s.modules.instances) do
    if existing.fingerprint == fingerprint then
      local status = instance_status(s, existing)
      if status.status ~= "missing" then
        return {deduplicated = true, instance = status, fingerprints = fingerprint}
      end
      forget_instance(existing)
      break
    end
  end

  local bounds = absolute_bounds(anchor, expanded.footprint)
  local clearable, blocking = scan_obstacles(surface, bounds, agent)
  if #blocking > 0 then
    local names = {}
    for _, entity in pairs(blocking) do
      names[entity.name] = (names[entity.name] or 0) + 1
    end
    return nil, "blocked_by_existing_entity", names
  end
  for _, area in ipairs(expanded.reserved) do
    local reserved_clearable, reserved_blocking = scan_obstacles(
      surface, absolute_area(anchor, area.area), agent)
    for _, entity in pairs(reserved_clearable) do clearable[#clearable + 1] = entity end
    if #reserved_blocking > 0 then
      local names = {}
      for _, entity in pairs(reserved_blocking) do
        names[entity.name] = (names[entity.name] or 0) + 1
      end
      return nil, "reserved_area_blocked", names
    end
  end
  local failures = check_placement_constraints(entry.definition, {
    surface = surface, anchor = anchor, absolute_bounds = bounds,
  }, {absolute_bounds = bounds})
  if #failures > 0 then return nil, "constraint_failed", failures end

  local entity_records = {}
  for _, entity in ipairs(expanded.entities) do
    local position = entity_absolute(anchor, entity)
    local can_place = surface.can_place_entity{
      name = entity.name, position = position, direction = entity.direction,
      force = agent.force, build_check_type = defines.build_check_type.script_ghost,
    }
    if not can_place and #clearable == 0 then
      return nil, "blocked_terrain", {entity = entity.name}
    end
    entity_records[#entity_records + 1] = {
      id = entity.id, name = entity.name, position = position,
      direction = entity.direction, quality = entity.quality or "normal",
      recipe = entity.recipe,
    }
  end

  -- Reject overlapping module instances even though other ghosts are ignored by the
  -- generic obstacle scan. This prevents two independent instances sharing a site.
  if overlaps_live_instance(s, surface, anchor, expanded.footprint) then
    return nil, "module_instance_overlap"
  end

  s.modules.next_instance_id = (s.modules.next_instance_id or 0) + 1
  local key = p.instance_key or ("module_" .. tostring(s.modules.next_instance_id))
  local created = {}
  for _, entity in ipairs(entity_records) do
    local tags = {
      ae_module_id = entry.definition.id,
      ae_module_version = tostring(entry.definition.module_version),
      ae_instance_key = key,
      ae_entity_id = entity.id,
    }
    if p.plan_id then tags.ae_plan_id = p.plan_id end
    if entity.recipe then tags.ae_recipe = entity.recipe end
    local ok, ghost = pcall(function()
      return surface.create_entity{
        name = "entity-ghost", inner_name = entity.name, position = entity.position,
        direction = entity.direction, force = agent.force, quality = entity.quality,
        tags = tags,
      }
    end)
    if not ok or not ghost or not ghost.valid then
      for _, created_ghost in pairs(created) do
        if created_ghost.valid then created_ghost.destroy() end
      end
      return nil, "ghost_create_failed", {entity = entity.name, error = tostring(ghost)}
    end
    created[#created + 1] = ghost
    entity.unit_number = ghost.unit_number
    entity.ghost_name = ghost.ghost_name
  end

  local instance = {
    key = key,
    module_id = entry.definition.id,
    module_version = entry.definition.module_version,
    schema_version = entry.definition.schema_version,
    fingerprint = fingerprint,
    anchor = anchor,
    orientation = orientation,
    parameters = expanded.parameters,
    footprint = expanded.footprint,
    surface_index = surface.index,
    surface_name = surface.name,
    created_tick = game.tick,
    entities = entity_records,
    ports = expanded.ports,
    reserved = expanded.reserved,
    cost_estimate = format.cost_estimate(entry.definition, p.parameters or {}, orientation),
    clearable_obstacles = #clearable,
  }
  table.insert(s.modules.instances, instance)
  s.modules.by_key[key] = instance
  return {deduplicated = false, instance = instance_status(s, instance)}
end

function M.instance_status(s, key)
  if not key then return nil, "missing_instance_key" end
  local instance = s.modules and s.modules.by_key and s.modules.by_key[key]
  if not instance then return nil, "unknown_module_instance" end
  return instance_status(s, instance)
end

function M.instances(s)
  s.modules = s.modules or {instances = {}, by_key = {}, next_instance_id = 0}
  local result = {}
  for _, instance in pairs(s.modules.instances) do
    result[#result + 1] = instance_status(s, instance)
  end
  table.sort(result, function(a, b) return a.key < b.key end)
  return result
end

function M.tagged_ghosts(s, instance_key)
  local result = {}
  for _, instance in pairs(s.modules and s.modules.instances or {}) do
    if not instance_key or instance.key == instance_key then
      local surface = game.surfaces[instance.surface_index]
      for _, entity in ipairs(instance.entities) do
        local live = find_live_entity(surface, entity.unit_number, entity.position)
        if live and live.valid and live.type == "entity-ghost" then
          result[#result + 1] = live
        end
      end
    end
  end
  return result
end

return M
