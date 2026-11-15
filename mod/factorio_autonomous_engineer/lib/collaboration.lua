-- Shared-world reconciliation: find ghosts in the configured work area, keep a stable
-- identity per ghost, notice player builds/cancellations/modifications, and detect a
-- player working close to a construction site.
local construction = require("lib.construction")

local M = {}

local WORK_RADIUS = 64
local PLAYER_WORK_RADIUS = 8
local SCAN_INTERVAL = 5

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function ghost_key(ghost)
  if ghost.unit_number then return tostring(ghost.unit_number) end
  return ghost.ghost_name .. ":" .. tostring(ghost.position.x) .. ":" .. tostring(ghost.position.y)
end

function M.context(s, agent)
  local surface = agent and agent.valid and agent.surface or nil
  if not surface then return nil end
  local center = agent.position
  if s.home and s.home.surface_index == surface.index then center = s.home.position end
  return {
    surface = surface, center = center, radius = WORK_RADIUS,
    area = {
      {x = center.x - WORK_RADIUS, y = center.y - WORK_RADIUS},
      {x = center.x + WORK_RADIUS, y = center.y + WORK_RADIUS},
    },
  }
end

function M.players_near(agent, position, radius)
  local result = {}
  if not agent or not agent.valid or not position then return result end
  local characters = agent.surface.find_entities_filtered{
    position = position, radius = radius or PLAYER_WORK_RADIUS, type = "character",
  }
  for _, character in pairs(characters) do
    if character.valid and character.unit_number ~= agent.unit_number then
      result[#result + 1] = character
    end
  end
  return result
end

function M.player_near(agent, position)
  return M.players_near(agent, position, PLAYER_WORK_RADIUS)[1]
end

function M.needs_scan(task)
  return not task.last_scan_tick or game.tick - task.last_scan_tick >= SCAN_INTERVAL
end

-- Reconcile task.entries with the live world. A ghost that vanished is never recreated:
-- if a real entity now occupies its place it is counted as built by someone else, otherwise
-- it is treated as cancelled by a player.
function M.refresh(s, task, agent)
  local context = M.context(s, agent)
  if not context then return {} end
  task.entries = task.entries or {}
  task.obstacles_seen = task.obstacles_seen or {}
  local ghosts = context.surface.find_entities_filtered{
    area = context.area, type = "entity-ghost",
  }
  local current = {}
  for _, ghost in pairs(ghosts) do
    if ghost.valid and ghost.ghost_type ~= "tile" then
      local key = ghost_key(ghost)
      current[key] = ghost
      local entry = task.entries[key]
      if not entry then
        entry = {
          key = key, unit_number = ghost.unit_number, name = ghost.ghost_name,
          position = {x = ghost.position.x, y = ghost.position.y}, status = "pending",
          first_seen_tick = game.tick,
        }
        task.entries[key] = entry
      end
      entry.ghost = ghost
      entry.name = ghost.ghost_name
      entry.position = {x = ghost.position.x, y = ghost.position.y}
      entry.direction = ghost.direction
      entry.quality = ghost.quality and ghost.quality.name or "normal"
      local requirements, reason = construction.requirements(ghost)
      entry.required = requirements
      if not requirements then
        entry.status, entry.reason = "unsupported", reason
      elseif entry.status == "unsupported" then
        entry.status, entry.reason = "pending", nil
      end
      if entry.status == "deferred_player" and not M.player_near(agent, ghost.position) then
        entry.status = "pending"
      end
    end
  end
  for key, entry in pairs(task.entries) do
    if not current[key] then
      entry.ghost = nil
      if entry.status ~= "built" and entry.status ~= "already_built"
        and entry.status ~= "cancelled" then
        local built = construction.find_real_entity(
          context.surface, entry.name, entry.position)
        if built then
          entry.status, entry.reason = "already_built", "built_by_player"
          entry.built_unit = built.unit_number
        else
          entry.status, entry.reason = "cancelled", "ghost_removed_by_player"
        end
      end
    end
  end
  task.last_scan_tick = game.tick
  task.work_area = {
    available = true, radius = WORK_RADIUS, center = context.center,
    ghost_count = #ghosts,
  }
  return current
end

local function aggregate_missing(entries)
  local result = {}
  for _, entry in pairs(entries) do
    if entry.status == "missing_materials" and entry.missing then
      for _, item in pairs(entry.missing) do
        local quality = item.quality or "normal"
        local key = quality == "normal" and item.name or (item.name .. ":" .. quality)
        result[key] = (result[key] or 0) + item.count
      end
    end
  end
  return result
end

local function count_status(entries, status)
  local count = 0
  for _, entry in pairs(entries) do
    if entry.status == status then count = count + 1 end
  end
  return count
end

function M.summary(task)
  local entries = task.entries or {}
  local summary = {
    work_area_available = task.work_area and task.work_area.available == true or false,
    work_radius = task.work_area and task.work_area.radius or WORK_RADIUS,
    ghosts_total = 0, built_by_agent = 0, already_built = 0, remaining = 0,
    cancelled = 0, unsupported = 0, blocked = 0, unreachable = 0,
    missing_materials = aggregate_missing(entries),
    obstacles = task.obstacles_seen or {},
    obstacles_cleared = task.obstacles_cleared or {},
    failure_reasons = {},
    configuration_errors = 0,
    configuration_failure_reasons = {},
    player_interference = task.player_interference == true,
    inventory_full = task.inventory_full == true,
    items_transferred = task.items_transferred or 0,
  }
  for _, entry in pairs(entries) do
    summary.ghosts_total = summary.ghosts_total + 1
    if entry.reason then
      summary.failure_reasons[entry.reason] = (summary.failure_reasons[entry.reason] or 0) + 1
    end
    if entry.status == "built" then
      summary.built_by_agent = summary.built_by_agent + 1
      if entry.configuration_error then
        summary.configuration_errors = (summary.configuration_errors or 0) + 1
        summary.configuration_failure_reasons[entry.configuration_error] =
          (summary.configuration_failure_reasons[entry.configuration_error] or 0) + 1
      end
    elseif entry.status == "already_built" then
      summary.already_built = summary.already_built + 1
    elseif entry.status == "cancelled" then
      summary.cancelled = summary.cancelled + 1
    elseif entry.status == "unsupported" then
      summary.unsupported = summary.unsupported + 1
    elseif entry.status == "blocked" then
      summary.blocked = summary.blocked + 1
    elseif entry.status == "unreachable" then
      summary.unreachable = summary.unreachable + 1
    end
    if entry.ghost and entry.ghost.valid and entry.status ~= "built"
      and entry.status ~= "already_built" and entry.status ~= "cancelled" then
      summary.remaining = summary.remaining + 1
    end
  end
  summary.missing_material_total = 0
  for _, count in pairs(summary.missing_materials) do
    summary.missing_material_total = summary.missing_material_total + count
  end
  summary.has_missing_materials = summary.missing_material_total > 0
  summary.blocking_reasons = {}
  if summary.unsupported > 0 then summary.blocking_reasons[#summary.blocking_reasons + 1] = "unsupported" end
  if summary.blocked > 0 then summary.blocking_reasons[#summary.blocking_reasons + 1] = "blocked" end
  if summary.unreachable > 0 then summary.blocking_reasons[#summary.blocking_reasons + 1] = "unreachable" end
  if summary.has_missing_materials then
    summary.blocking_reasons[#summary.blocking_reasons + 1] = "missing_materials"
  end
  if summary.inventory_full then
    summary.blocking_reasons[#summary.blocking_reasons + 1] = "inventory_full"
  end
  if summary.player_interference then
    summary.blocking_reasons[#summary.blocking_reasons + 1] = "player_interference"
  end
  return summary
end

function M.entries_with_status(task, status)
  local result = {}
  for _, entry in pairs(task.entries or {}) do
    if entry.status == status then result[#result + 1] = entry end
  end
  return result
end

function M.count_status(task, status)
  return count_status(task.entries or {}, status)
end

function M.work_radius()
  return WORK_RADIUS
end

function M.player_work_radius()
  return PLAYER_WORK_RADIUS
end

function M.distance(a, b)
  return distance(a, b)
end

return M
