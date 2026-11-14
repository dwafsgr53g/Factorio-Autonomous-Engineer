-- Deterministic world profiling. The LLM receives the conclusion, not raw map data.
local M = {}

local function tech(force, name)
  local value = force.technologies[name]
  return value ~= nil and value.researched == true
end

local function count_near(surface, name, position, radius, force)
  if not prototypes.entity[name] then return 0 end
  return surface.count_entities_filtered({
    name = name, position = position, radius = radius, force = force,
  })
end

local function choose_stage(force, platform_count)
  local evidence = {
    automation = tech(force, "automation"),
    logistic_science = tech(force, "logistic-science-pack"),
    oil_processing = tech(force, "oil-processing"),
    chemical_science = tech(force, "chemical-science-pack"),
    production_science = tech(force, "production-science-pack"),
    utility_science = tech(force, "utility-science-pack"),
    space_science = tech(force, "space-science-pack"),
    promethium_science = tech(force, "promethium-science-pack"),
  }
  if evidence.promethium_science or evidence.space_science or platform_count > 0 then
    return "space_age", evidence
  end
  if evidence.production_science or evidence.utility_science then return "advanced_industry", evidence end
  if evidence.oil_processing or evidence.chemical_science then return "oil_processing", evidence end
  if evidence.logistic_science then return "automation", evidence end
  if evidence.automation then return "automation_bootstrap", evidence end
  return "early_game", evidence
end

local function available_planets(force)
  local result = {}
  for name in pairs(game.planets) do
    local discovered = name == "nauvis" or tech(force, "planet-discovery-" .. name)
    if discovered then result[#result + 1] = name end
  end
  table.sort(result)
  return result
end

function M.context(s)
  local agent = s.agent and s.agent.valid and s.agent or nil
  local surface = agent and agent.surface or game.surfaces.nauvis or game.surfaces[1]
  assert(surface, "No active Factorio surface is available")
  local force = (agent and agent.force) or game.forces.player
  local planet = surface.planet
  local domain = surface.platform and "space_platform" or (planet and "planet" or "surface")
  local planet_name = planet and planet.name or (surface.platform and "space" or surface.name)
  local reference = agent and agent.position or force.get_spawn_position(surface)
  if s.home and s.home.surface_index == surface.index then reference = s.home.position end

  local platforms = 0
  for _, known_planet in pairs(game.planets) do
    local ok, values = pcall(function() return known_planet.get_space_platforms(force) end)
    if ok and values then platforms = platforms + #values end
  end

  local stage, evidence = choose_stage(force, platforms)
  local base_entities = {
    assemblers = count_near(surface, "assembling-machine-1", reference, 128, force)
      + count_near(surface, "assembling-machine-2", reference, 128, force)
      + count_near(surface, "assembling-machine-3", reference, 128, force),
    drills = count_near(surface, "burner-mining-drill", reference, 128, force)
      + count_near(surface, "electric-mining-drill", reference, 128, force),
    furnaces = count_near(surface, "stone-furnace", reference, 128, force)
      + count_near(surface, "steel-furnace", reference, 128, force)
      + count_near(surface, "electric-furnace", reference, 128, force),
    labs = count_near(surface, "lab", reference, 128, force),
    rocket_silos = count_near(surface, "rocket-silo", reference, 128, force),
  }
  local has_base = base_entities.assemblers + base_entities.drills + base_entities.furnaces > 0
  local has_automation = evidence.automation or base_entities.assemblers > 0

  local skills = {"core_strategy", "stage_" .. stage}
  local planet_skill = string.gsub(string.lower(planet_name), "[^%w%-]", "-")
  skills[#skills + 1] = "planet_" .. planet_skill

  local capabilities = {"get_briefing", "get_agent_status", "get_pending_events"}
  if not surface.platform and (planet_name == "nauvis" or surface.name == "nauvis")
    and (stage == "early_game" or stage == "automation_bootstrap")
    and not (s.starting_site and s.starting_site.confirmed) then
    capabilities[#capabilities + 1] = "select_starting_site"
  end
  if not surface.platform then capabilities[#capabilities + 1] = "gather_resource" end

  return {
    planet = {name = planet_name, domain = domain, surface = surface.name},
    stage = {id = stage, evidence = evidence},
    progression = {
      discovered_planets = available_planets(force),
      space_platforms = platforms,
      base_established = has_base,
      automation_present = has_automation,
      nearby_base_entities = base_entities,
    },
    agent = {
      lifecycle = s.lifecycle and s.lifecycle.status or "uninitialized",
      alive = agent ~= nil,
      health_ratio = agent and agent.health / agent.prototype.max_health or nil,
    },
    skills = skills,
    available_capabilities = capabilities,
    policy = {
      coordinates_exposed_to_model = false,
      low_level_game_actions_exposed = false,
      movement_and_inventory_owned_by_executor = true,
    },
  }
end

return M
