-- Deterministic Nauvis bootstrap site selector. Coordinates remain inside the executor.
local M = {}
local RESOURCE_WEIGHTS = {["iron-ore"] = 0.34, ["copper-ore"] = 0.29, coal = 0.22, stone = 0.15}
local SEARCH_RADIUS, GRID_STEP, ENEMY_EXCLUSION_RADIUS = 192, 24, 64
local WATER_TARGET_DISTANCE = 42

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function generated(surface, position)
  return surface.is_chunk_generated({x = math.floor(position.x / 32), y = math.floor(position.y / 32)})
end

local function known_chunk_ratio(surface, position)
  local known, total = 0, 0
  local cx, cy = math.floor(position.x / 32), math.floor(position.y / 32)
  for dx = -1, 1 do
    for dy = -1, 1 do
      total = total + 1
      if surface.is_chunk_generated({x = cx + dx, y = cy + dy}) then known = known + 1 end
    end
  end
  return known / total
end

local function gather_resources(surface, origin)
  local area = {{origin.x - SEARCH_RADIUS, origin.y - SEARCH_RADIUS},
                {origin.x + SEARCH_RADIUS, origin.y + SEARCH_RADIUS}}
  local grouped = {}
  for name in pairs(RESOURCE_WEIGHTS) do grouped[name] = {} end
  for _, entity in pairs(surface.find_entities_filtered({type = "resource", area = area})) do
    if grouped[entity.name] and entity.valid and entity.amount > 0 then
      grouped[entity.name][#grouped[entity.name] + 1] = entity.position
    end
  end
  return grouped
end

local function nearest_resource_distance(position, grouped, name)
  local best
  for _, resource_position in pairs(grouped[name] or {}) do
    local current = distance(position, resource_position)
    if not best or current < best then best = current end
  end
  return best
end

local function nearest_water_distance(surface, position, origin)
  local best
  for radius = 0, 128, 8 do
    local samples = radius == 0 and 1 or 16
    for index = 0, samples - 1 do
      local angle = index * (2 * math.pi / samples)
      local sample = {x = math.floor(position.x + math.cos(angle) * radius),
                      y = math.floor(position.y + math.sin(angle) * radius)}
      if distance(sample, origin) <= SEARCH_RADIUS and generated(surface, sample) then
        local tile = surface.get_tile(sample.x, sample.y)
        if string.lower(tile.name):find("water", 1, true) then
          local current = distance(position, sample)
          if not best or current < best then best = current end
        end
      end
    end
    if best and best <= radius then break end
  end
  return best
end

local function enemy_count(surface, position)
  return surface.count_entities_filtered({
    position = position, radius = ENEMY_EXCLUSION_RADIUS, force = game.forces.enemy,
    type = {"unit", "unit-spawner", "turret", "ammo-turret", "electric-turret", "fluid-turret"},
  })
end

local function score_candidate(surface, force, candidate, grouped, origin)
  if not generated(surface, candidate) then return nil end
  local position = surface.find_non_colliding_position("character", candidate, 6, 1, true)
  if not position then return nil end
  if not surface.can_place_entity({name = "stone-furnace", position = position, force = force}) then return nil end
  if enemy_count(surface, position) > 0 then return nil end

  local resource_score, resource_distances, resource_count = 0, {}, 0
  for name, weight in pairs(RESOURCE_WEIGHTS) do
    local d = nearest_resource_distance(position, grouped, name)
    resource_distances[name] = d
    if d then
      resource_score = resource_score + math.min(d, SEARCH_RADIUS) * weight
      resource_count = resource_count + 1
    else
      resource_score = resource_score + SEARCH_RADIUS * weight
    end
  end
  if resource_count < 3 then return nil end

  local water_distance = nearest_water_distance(surface, position, origin)
  if not water_distance then return nil end
  local water_penalty = math.abs(water_distance - WATER_TARGET_DISTANCE) * 0.35
  local known_ratio = known_chunk_ratio(surface, position)
  if known_ratio < 0.55 then return nil end
  return {
    position = position,
    score = resource_score + water_penalty + (1 - known_ratio) * 96,
    resource_distances = resource_distances,
    water_distance = water_distance,
    known_ratio = known_ratio,
  }
end

function M.select(s)
  if s.starting_site and s.starting_site.confirmed then
    local surface = game.surfaces[s.starting_site.surface_index]
    return {success = true, site_id = "starting-site-1", already_selected = true,
      surface = surface and surface.name or nil, registered_as_home = true}
  end
  assert(s.agent and s.agent.valid, "Agent must be alive to select a starting site")
  local agent, surface = s.agent, s.agent.surface
  assert(not surface.platform and (surface.name == "nauvis" or
    (surface.planet and surface.planet.name == "nauvis")),
    "The initial site selector is validated for Nauvis only")
  local force = agent.force
  local origin = force.get_spawn_position(surface)
  if not origin or not generated(surface, origin) then origin = agent.position end
  local grouped, candidates = gather_resources(surface, origin), {}
  for dx = -SEARCH_RADIUS, SEARCH_RADIUS, GRID_STEP do
    for dy = -SEARCH_RADIUS, SEARCH_RADIUS, GRID_STEP do
      local scored = score_candidate(surface, force, {x = origin.x + dx, y = origin.y + dy}, grouped, origin)
      if scored then candidates[#candidates + 1] = scored end
    end
  end
  table.sort(candidates, function(a, b) return a.score < b.score end)
  local best = candidates[1]
  assert(best, "No suitable base site found in generated search area; explore and retry")
  s.home = {surface_index = surface.index, position = best.position}
  s.starting_site = {
    confirmed = true, surface_index = surface.index, position = best.position,
    score = best.score, selected_tick = game.tick,
    resource_distances = best.resource_distances, water_distance = best.water_distance,
    known_ratio = best.known_ratio,
  }
  return {
    success = true, site_id = "starting-site-1", surface = surface.name,
    suitability = best.score < 85 and "excellent" or (best.score < 125 and "good" or "acceptable"),
    resource_access = {
      iron_ore = best.resource_distances["iron-ore"] and "nearby" or "not_found",
      copper_ore = best.resource_distances["copper-ore"] and "nearby" or "not_found",
      coal = best.resource_distances.coal and "nearby" or "not_found",
      stone = best.resource_distances.stone and "nearby" or "not_found",
    },
    water_access = best.water_distance <= 64 and "nearby" or "distant",
    local_enemy_scan = "no_hostile_entities_inside_exclusion_radius",
    terrain_confidence = best.known_ratio >= 0.9 and "high" or "partial_generated_chunks_only",
    registered_as_home = true,
  }
end

function M.status(s)
  if not s.starting_site then return {selected = false} end
  local site = s.starting_site
  return {selected = site.confirmed == true, surface_index = site.surface_index,
    resource_distances = site.resource_distances, water_distance = site.water_distance,
    terrain_confidence = site.known_ratio}
end

return M
