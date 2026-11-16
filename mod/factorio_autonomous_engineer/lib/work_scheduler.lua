-- Reach-aware construction work scheduler.
--
-- This module divides construction work into overlapping spatial zones derived
-- from the character's actual ``build_distance``, selects a floating working
-- position per zone, and exposes the ghosts that are actually reachable from
-- that position. It performs no movement and never writes ``walking_state``;
-- the movement controller owns every route.
--
-- Two layers exist on purpose:
--
--   * ``M.choose`` is a stateless, read-only planner used by the internal RCON
--     diagnostics surface. It answers "where would a good working position be?"
--     without touching task state.
--   * ``M.sync`` / ``M.select`` keep a persistent plan on the task so a
--     construction run visits zones sequentially and never revisits one.
local movement = require("lib.movement")

local M = {}

local ZONE_MARGIN = 4.0
local CANDIDATE_RING_RADII = {0.0, 1.0, 2.0, 3.0, 4.0, 5.0}
local CANDIDATE_DIRECTIONS = 16
local MAX_CANDIDATES = 24
local MAX_EVALUATED = 16
local MAX_COVER_GHOSTS = 256
local AREA_CENTER_SETTLE_TICKS = 12
local ZONE_SAFETY = 0.95
local MIN_ZONE_SIZE = 4

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function position_copy(position)
  if not position then return nil end
  return {x = position.x, y = position.y}
end

local function point_inside_box(position, box, margin)
  margin = margin or 0
  if not position or not box then return false end
  return position.x >= box.left_top.x - margin and position.x <= box.right_bottom.x + margin
    and position.y >= box.left_top.y - margin and position.y <= box.right_bottom.y + margin
end

local function key(position)
  return tostring(position.x) .. "," .. tostring(position.y)
end

local function build_distance(agent)
  if not agent or not agent.valid then return nil end
  local ok, value = pcall(function() return agent.build_distance end)
  if ok and type(value) == "number" and value > 0 then return value end
  return nil
end

function M.build_distance(agent)
  return build_distance(agent)
end

-- Conservative zone size. A square zone of side S has half-diagonal S/sqrt(2),
-- so the largest S whose corners are still inside the live build reach is
-- reach*sqrt(2). A 5 % margin absorbs entity footprints and non-square
-- prototypes. The value is never hard-coded: it is always derived from the
-- character's current build_distance.
function M.zone_size(agent)
  local reach = build_distance(agent)
  if not reach then return nil end
  local size = math.floor(reach * math.sqrt(2) * ZONE_SAFETY)
  if size < MIN_ZONE_SIZE then size = MIN_ZONE_SIZE end
  return size
end

function M.grid_size(agent)
  return M.zone_size(agent)
end

function M.zone_overlap(agent)
  local size = M.zone_size(agent)
  if not size then return nil end
  return math.min(ZONE_MARGIN, math.floor(size / 4))
end

local function ghost_entry(entry)
  if not entry or entry.status == "built" or entry.status == "already_built"
    or entry.status == "cancelled" or entry.status == "unsupported" then
    return false
  end
  return entry.ghost ~= nil and entry.ghost.valid
end

local function is_open_entry(entry)
  if not entry or not entry.ghost or not entry.ghost.valid then return false end
  local status = entry.status
  return status == "pending" or status == "building" or status == "acquiring"
    or status == "clearing"
end

local function make_zone(scheduler, gx, gy, grid_size)
  local overlap = scheduler.overlap or 0
  local zone = {
    id = string.format("z:%d,%d", gx, gy),
    gx = gx, gy = gy,
    bounds = {
      left_top = {x = gx * grid_size - overlap, y = gy * grid_size - overlap},
      right_bottom = {x = (gx + 1) * grid_size + overlap,
        y = (gy + 1) * grid_size + overlap},
    },
    entries = {},
    entry_objects = {},
    work_position = nil,
    work_position_tick = nil,
    selected_tick = nil,
    completed = false,
    attempts = 0,
    evaluation = nil,
  }
  scheduler.zones[zone.id] = zone
  return zone
end

local function assign(scheduler, agent, entries, grid_size)
  local reach = build_distance(agent)
  if not reach or not entries then return {} end
  local zones = {}
  local count = 0
  for _, entry in pairs(entries) do
    if count < MAX_COVER_GHOSTS and ghost_entry(entry) then
      count = count + 1
      local gx = math.floor(entry.position.x / grid_size)
      local gy = math.floor(entry.position.y / grid_size)
      local id = string.format("z:%d,%d", gx, gy)
      local zone = scheduler.zones[id]
      if not zone then zone = make_zone(scheduler, gx, gy, grid_size) end
      zone.entries[entry.key] = true
      zone.entry_objects[#zone.entry_objects + 1] = entry
      zones[#zones + 1] = zone
    end
  end
  return zones
end

local function reachable_ghost(ghost, agent, reach)
  local dx = ghost.position.x - agent.position.x
  local dy = ghost.position.y - agent.position.y
  if dx * dx + dy * dy > reach * reach then return false end
  local prototype = prototypes.entity[ghost.ghost_name]
  if not prototype then return false end
  local ok, result = pcall(function()
    return agent.can_place_entity{
      name = ghost.ghost_name,
      position = ghost.position,
      direction = ghost.direction,
      force = agent.force,
      build_check_type = defines.build_check_type.ghost_revive,
    }
  end)
  return ok and result == true
end

local function occupancy(agent, position)
  if not agent or not agent.valid or not position then return true end
  local surface = agent.surface
  if not surface.can_place_entity{name = "character", position = position,
    force = agent.force} then
    return true
  end
  local belts = surface.find_entities_filtered{
    area = {{x = position.x - 0.35, y = position.y - 0.35},
      {x = position.x + 0.35, y = position.y + 0.35}},
    type = {"transport-belt", "underground-belt", "splitter"},
  }
  if #belts > 0 then return true end
  local characters = surface.find_entities_filtered{
    position = position, radius = 0.7, type = "character",
  }
  for _, character in pairs(characters) do
    if character.valid and character.unit_number ~= agent.unit_number then
      return true
    end
  end
  local ghosts = surface.find_entities_filtered{
    area = {{x = position.x - 1.2, y = position.y - 1.2},
      {x = position.x + 1.2, y = position.y + 1.2}},
    type = {"entity-ghost", "tile-ghost"},
  }
  for _, ghost in pairs(ghosts) do
    if ghost.valid and point_inside_box(position, ghost.bounding_box, 0.1) then
      return true
    end
  end
  return false
end

local function candidate_positions(agent, zone, reach, area_center, count)
  if not agent or not agent.valid then return {} end
  local width = zone.bounds.right_bottom.x - zone.bounds.left_top.x
  local height = zone.bounds.right_bottom.y - zone.bounds.left_top.y
  local candidates = {}
  local seen = {}
  local function consider(position)
    if not position then return end
    local k = key(position)
    if seen[k] then return end
    seen[k] = true
    candidates[#candidates + 1] = position_copy(position)
  end
  if area_center then consider(area_center) end
  local center = {x = (zone.bounds.left_top.x + zone.bounds.right_bottom.x) / 2,
    y = (zone.bounds.left_top.y + zone.bounds.right_bottom.y) / 2}
  for _, ring in ipairs(CANDIDATE_RING_RADII) do
    local steps = math.max(1, math.floor(2 * math.pi * math.max(ring, 0.5)
      * CANDIDATE_DIRECTIONS / 8))
    for index = 0, steps - 1 do
      local angle = index * (2 * math.pi / steps)
      consider({x = center.x + math.cos(angle) * ring,
        y = center.y + math.sin(angle) * ring})
    end
  end
  local width_samples = math.max(2, math.floor(width / 2))
  local height_samples = math.max(2, math.floor(height / 2))
  for ix = 0, width_samples - 1 do
    for iy = 0, height_samples - 1 do
      consider({x = zone.bounds.left_top.x + (ix + 0.5) * width / width_samples,
        y = zone.bounds.left_top.y + (iy + 0.5) * height / height_samples})
    end
  end
  local best = {}
  for index = 1, math.min(#candidates, math.max(count, 1)) do
    best[#best + 1] = candidates[index]
  end
  return best
end

local function score_position(agent, zone, position, entries, reach)
  local covered = 0
  for _, entry in pairs(entries or {}) do
    if type(entry) == "table" then
      local ghost = entry.ghost
      if ghost and ghost.valid and reachable_ghost(ghost, agent, reach) then
        covered = covered + 1
      end
    end
  end
  return {
    covered = covered,
    obstructed = 0,
    player_near = 0,
    distance_from_agent = distance(agent.position, position),
    tie = key(position),
  }
end

-- Stateless planner used by the internal diagnostics surface.
function M.choose(s, options)
  options = options or {}
  local agent = s.agent
  if not agent or not agent.valid then return nil, "agent_unavailable", nil end
  local reach = build_distance(agent)
  if not reach then return nil, "build_distance_unavailable", nil end
  local grid_size = M.grid_size(agent)
  local entries = options.entries or {}
  local scheduler = {
    zones = {},
    build_distance = reach,
    grid_size = grid_size,
    overlap = M.zone_overlap(agent),
  }
  local zones = assign(scheduler, agent, entries, grid_size)
  if #zones == 0 then
    return nil, "no_pending_ghosts", {zones = {}, reach = reach, grid_size = grid_size}
  end
  local area_center = nil
  local minx, miny, maxx, maxy
  for _, zone in pairs(zones) do
    minx = math.min(minx or zone.bounds.left_top.x, zone.bounds.left_top.x)
    miny = math.min(miny or zone.bounds.left_top.y, zone.bounds.left_top.y)
    maxx = math.max(maxx or zone.bounds.right_bottom.x, zone.bounds.right_bottom.x)
    maxy = math.max(maxy or zone.bounds.right_bottom.y, zone.bounds.right_bottom.y)
  end
  area_center = {x = (minx + maxx) / 2, y = (miny + maxy) / 2}
  local zone_order = {}
  for _, zone in pairs(zones) do zone_order[#zone_order + 1] = zone end
  table.sort(zone_order, function(a, b)
    if a.gy ~= b.gy then return a.gy < b.gy end
    return a.gx < b.gx
  end)
  local evaluated = {}
  for index = 1, math.min(#zone_order, MAX_EVALUATED) do
    local zone = zone_order[index]
    local candidates = candidate_positions(agent, zone, reach, area_center, MAX_CANDIDATES)
    local best
    local evaluated_count = 0
    for _, candidate in ipairs(candidates) do
      if evaluated_count < MAX_EVALUATED then
        local occupied = occupancy(agent, candidate)
        local score = score_position(agent, zone, candidate, zone.entry_objects, reach)
        score.occupied = occupied
        score.zone_id = zone.id
        score.position = candidate
        if not best or (not occupied and best.score.occupied)
          or (occupied == best.score.occupied and score.covered > best.score.covered)
          or (occupied == best.score.occupied and score.covered == best.score.covered
            and score.distance_from_agent < best.score.distance_from_agent) then
          best = {score = score, position = candidate, zone = zone}
        end
        evaluated_count = evaluated_count + 1
      end
    end
    if best then
      best.zone.work_position = best.position
      best.zone.evaluation = best.score
      evaluated[#evaluated + 1] = best
    end
  end
  table.sort(evaluated, function(a, b)
    if a.score.occupied ~= b.score.occupied then return not a.score.occupied end
    if a.score.covered ~= b.score.covered then return a.score.covered > b.score.covered end
    if math.abs(a.score.distance_from_agent - b.score.distance_from_agent) > 1e-9 then
      return a.score.distance_from_agent < b.score.distance_from_agent
    end
    return a.zone.id < b.zone.id
  end)
  local best = evaluated[1]
  if not best then
    return nil, "no_usable_work_position",
      {zones = zone_order, reach = reach, grid_size = grid_size}
  end
  local selected = {
    zone = best.zone,
    position = best.position,
    reach = reach,
    grid_size = grid_size,
    zones = zone_order,
    evaluation = best.score,
  }
  return selected.zone.id, nil, selected
end

function M.assign_entries(scheduler, agent, entries)
  if not scheduler then return {} end
  return assign(scheduler, agent, entries, scheduler.grid_size)
end

function M.summarize(scheduler)
  local zones = {}
  if scheduler and scheduler.zones then
    for _, zone in pairs(scheduler.zones) do
      zones[#zones + 1] = {
        id = zone.id, gx = zone.gx, gy = zone.gy,
        bounds = zone.bounds,
        pending = zone.pending_count, work_position = zone.work_position,
        evaluation = zone.evaluation,
        attempts = zone.attempts,
        completed = zone.completed,
      }
    end
    table.sort(zones, function(a, b) return a.id < b.id end)
  end
  return zones
end

function M.reachable_count(agent, entries)
  local reach = build_distance(agent)
  if not agent or not agent.valid or not reach then return 0 end
  local count = 0
  for _, entry in pairs(entries or {}) do
    if ghost_entry(entry) and reachable_ghost(entry.ghost, agent, reach) then
      count = count + 1
    end
  end
  return count
end

function M.constants()
  return {
    zone_margin = ZONE_MARGIN,
    zone_safety = ZONE_SAFETY,
    min_zone_size = MIN_ZONE_SIZE,
    candidate_rings = CANDIDATE_RING_RADII,
    candidate_directions = CANDIDATE_DIRECTIONS,
    max_candidates = MAX_CANDIDATES,
    max_evaluated = MAX_EVALUATED,
    area_center_settle_ticks = AREA_CENTER_SETTLE_TICKS,
  }
end

function M.reach_for(s, agent)
  agent = agent or s.agent
  return build_distance(agent)
end

-- -------------------------------------------------------------------------
-- Persistent scheduler state used by the construction task
-- -------------------------------------------------------------------------

local function zone_center(zone)
  return {x = (zone.bounds.left_top.x + zone.bounds.right_bottom.x) / 2,
    y = (zone.bounds.left_top.y + zone.bounds.right_bottom.y) / 2}
end

local function zone_entries(entries, zone)
  local result = {}
  for _, entry in pairs(entries or {}) do
    if is_open_entry(entry) and zone.entries[entry.key] then
      result[#result + 1] = entry
    end
  end
  table.sort(result, function(a, b)
    local am = a.ghost and a.ghost.tags and a.ghost.tags.ae_plan_id and 1 or 0
    local bm = b.ghost and b.ghost.tags and b.ghost.tags.ae_plan_id and 1 or 0
    if am ~= bm then return am > bm end
    local abox = a.ghost and a.ghost.bounding_box
    local bbox = b.ghost and b.ghost.bounding_box
    local aa = abox and (abox.right_bottom.x - abox.left_top.x)
      * (abox.right_bottom.y - abox.left_top.y) or 0
    local ba = bbox and (bbox.right_bottom.x - bbox.left_top.x)
      * (bbox.right_bottom.y - bbox.left_top.y) or 0
    if math.abs(aa - ba) > 1e-9 then return aa > ba end
    if a.key ~= b.key then return a.key < b.key end
    return false
  end)
  return result
end

local function nearest_distance(position, ghost)
  local box = ghost.bounding_box
  if not box then return distance(position, ghost.position) end
  local x = math.max(box.left_top.x, math.min(position.x, box.right_bottom.x))
  local y = math.max(box.left_top.y, math.min(position.y, box.right_bottom.y))
  local dx, dy = position.x - x, position.y - y
  return math.sqrt(dx * dx + dy * dy)
end

function M.reset(task)
  task.work_plan = nil
end

-- Rebuild the persistent plan from the live task ledger. Zone identity is derived
-- from grid coordinates, and every entry carries a stable key, so a save/load or a
-- reconciliation rescan never assigns a ghost to a different zone.
function M.sync(s, task, agent)
  agent = agent or s.agent
  local reach = build_distance(agent)
  if not reach then return nil, "build_distance_unavailable" end
  local grid_size = M.grid_size(agent)
  local overlap = M.zone_overlap(agent)
  local plan = task.work_plan
  if not plan or plan.reach ~= reach or plan.grid_size ~= grid_size
    or plan.overlap ~= overlap then
    plan = {reach = reach, grid_size = grid_size, overlap = overlap, zones = {},
      rejected = {}}
    task.work_plan = plan
  end
  for _, zone in pairs(plan.zones) do
    zone.entries = {}
    zone.entry_objects = {}
  end
  local count = 0
  for _, entry in pairs(task.entries or {}) do
    if is_open_entry(entry) and count < MAX_COVER_GHOSTS then
      count = count + 1
      local gx = math.floor(entry.position.x / grid_size)
      local gy = math.floor(entry.position.y / grid_size)
      local id = string.format("z:%d,%d", gx, gy)
      local zone = plan.zones[id]
      if not zone then
        zone = {
          id = id, gx = gx, gy = gy,
          bounds = {
            left_top = {x = gx * grid_size - overlap, y = gy * grid_size - overlap},
            right_bottom = {x = (gx + 1) * grid_size + overlap,
              y = (gy + 1) * grid_size + overlap},
          },
          entries = {}, entry_objects = {}, completed = false, attempts = 0,
        }
        plan.zones[id] = zone
      end
      zone.entries[entry.key] = true
      zone.entry_objects[#zone.entry_objects + 1] = entry
      entry.work_zone = id
      if entry.ghost and entry.ghost.tags and entry.ghost.tags.ae_plan_id then
        zone.module_count = (zone.module_count or 0) + 1
      end
    end
  end
  for _, zone in pairs(plan.zones) do
    -- Count only work that is still live; already built/cancelled/rejected ghosts
    -- belong to the ledger, not to the scheduler's pending set.
    local pending, modules = 0, 0
    for _, entry in pairs(zone.entry_objects or {}) do
      if is_open_entry(entry) then
        pending = pending + 1
        if entry.ghost and entry.ghost.tags and entry.ghost.tags.ae_plan_id then
          modules = modules + 1
        end
      end
    end
    zone.module_count = modules
    zone.pending_count = pending
    zone.completed = pending == 0
  end
  return plan
end

local function zone_candidates(plan, zone, reach)
  local candidates = {}
  local seen = {}
  local function consider(position)
    if not position then return end
    local k = key(position)
    if seen[k] then return end
    seen[k] = true
    candidates[#candidates + 1] = position_copy(position)
  end
  local center = zone_center(zone)
  consider(center)
  local entries = zone.entry_objects or {}
  local cx, cy, count = 0, 0, 0
  for _, entry in ipairs(entries) do
    cx, cy = cx + entry.position.x, cy + entry.position.y
    count = count + 1
    if count <= 8 then
      for index = 0, 7 do
        local angle = index * math.pi / 4
        consider({x = entry.position.x + math.cos(angle) * reach * 0.55,
          y = entry.position.y + math.sin(angle) * reach * 0.55})
      end
    end
  end
  if count > 0 then consider({x = cx / count, y = cy / count}) end
  for _, ring in ipairs({1.0, 2.0, 3.0, 4.5}) do
    for index = 0, 11 do
      local angle = index * math.pi / 6
      consider({x = center.x + math.cos(angle) * ring,
        y = center.y + math.sin(angle) * ring})
    end
  end
  return candidates
end

local function score_candidate(agent, plan, position, entries, next_zone_distance)
  local covered = 0
  for _, entry in ipairs(entries) do
    if nearest_distance(position, entry.ghost) <= plan.reach * 0.98 then
      covered = covered + 1
    end
  end
  return {
    covered = covered,
    distance_from_agent = distance(agent.position, position),
    next_zone_distance = next_zone_distance or 0,
    position = position,
  }
end

-- Persistent zone selection used by the construction task.
function M.select(s, task, agent)
  agent = agent or s.agent
  local plan, reason = M.sync(s, task, agent)
  if not plan then return nil, reason end
  local zone_list = {}
  local total_pending = 0
  local global_modules = 0
  for _, zone in pairs(plan.zones) do
    if not zone.completed and (zone.pending_count or 0) > 0 then
      zone_list[#zone_list + 1] = zone
      total_pending = total_pending + (zone.pending_count or 0)
      global_modules = global_modules + (zone.module_count or 0)
    end
  end
  if #zone_list == 0 then return nil, "no_pending_ghosts", plan end
  -- Large plan modules must be built before logistics belts so the belts cannot
  -- enclose a 2x2/3x3 module footprint. Module zones stay exclusive until every
  -- module ghost has been built or the executor has explicitly recorded it as
  -- unreachable.
  if global_modules > 0 then
    local module_zones = {}
    for _, zone in ipairs(zone_list) do
      if (zone.module_count or 0) > 0 then
        module_zones[#module_zones + 1] = zone
      end
    end
    if #module_zones > 0 then zone_list = module_zones end
  end
  table.sort(zone_list, function(a, b)
    if a.gy ~= b.gy then return a.gy < b.gy end
    return a.gx < b.gx
  end)
  local scored = {}
  for index = 1, math.min(#zone_list, MAX_CANDIDATES) do
    local zone = zone_list[index]
    local entries = zone_entries(task.entries, zone)
    local next_zone = index < #zone_list and zone_center(zone_list[index + 1]) or nil
    local next_distance = next_zone and distance(zone_center(zone), next_zone) or 0
    local best
    for _, candidate in ipairs(zone_candidates(plan, zone, plan.reach)) do
      local reject_key = zone.id .. "@" .. key(candidate)
      if not (plan.rejected and plan.rejected[reject_key]) then
        if not occupancy(agent, candidate) then
          local score = score_candidate(agent, plan, candidate, entries, next_distance)
          score.zone_id = zone.id
          score.reject_key = reject_key
          if not best
            or score.covered > best.score.covered
            or (score.covered == best.score.covered
              and score.distance_from_agent < best.score.distance_from_agent - 1e-9)
            or (score.covered == best.score.covered
              and math.abs(score.distance_from_agent - best.score.distance_from_agent) <= 1e-9
              and key(candidate) < key(best.position)) then
            best = {zone = zone, position = candidate, score = score}
          end
        end
      end
    end
    if best then scored[#scored + 1] = best end
  end
  table.sort(scored, function(a, b)
    local am = (a.zone.module_count or 0) > 0 and 1 or 0
    local bm = (b.zone.module_count or 0) > 0 and 1 or 0
    if am ~= bm then return am > bm end
    if a.score.covered ~= b.score.covered then return a.score.covered > b.score.covered end
    if math.abs(a.score.distance_from_agent - b.score.distance_from_agent) > 1e-9 then
      return a.score.distance_from_agent < b.score.distance_from_agent
    end
    if math.abs(a.score.next_zone_distance - b.score.next_zone_distance) > 1e-9 then
      return a.score.next_zone_distance < b.score.next_zone_distance
    end
    if a.zone.id ~= b.zone.id then return a.zone.id < b.zone.id end
    return key(a.position) < key(b.position)
  end)
  local best = scored[1]
  if not best then
    if global_modules > 0 then
      plan.module_stalls = (plan.module_stalls or 0) + 1
    end
    return nil, "no_usable_work_position", plan
  end
  best.zone.work_position = best.position
  best.zone.work_position_tick = game.tick
  best.zone.attempts = (best.zone.attempts or 0) + 1
  best.plan = plan
  best.total_pending = total_pending
  return best, nil, plan
end

function M.reject_position(task, zone_id, position)
  local plan = task.work_plan
  if not plan or not zone_id or not position then return end
  plan.rejected[zone_id .. "@" .. key(position)] = true
end

-- A zone is complete only when none of its ghosts is still pending. Ghosts
-- that were blocked or reported unreachable are terminal ledger states and do
-- not keep the zone open.
function M.zone_is_complete(task, zone_id)
  local plan = task.work_plan
  local zone = plan and plan.zones[zone_id]
  if not zone then return true end
  local pending = 0
  for _, entry in pairs(task.entries or {}) do
    if entry.status == "pending" and zone.entries[entry.key] then
      pending = pending + 1
    end
  end
  zone.pending_count = pending
  zone.completed = pending == 0
  return zone.completed
end

function M.mark_unreachable_zone(task, zone_id, reason)
  local plan = task.work_plan
  local zone = plan and plan.zones[zone_id]
  if not zone then return end
  for _, entry in pairs(task.entries or {}) do
    if is_open_entry(entry) and zone.entries[entry.key] then
      entry.status, entry.reason = "unreachable", reason or "no_work_position"
    end
  end
  zone.completed = true
end

function M.pending_in_zone(task, zone_id)
  local plan = task.work_plan
  local zone = plan and plan.zones[zone_id]
  if not zone then return {} end
  return zone_entries(task.entries, zone)
end

function M.plan_summary(task)
  local plan = task.work_plan
  if not plan then return {available = false} end
  local zones = {}
  for _, zone in pairs(plan.zones) do
    zones[#zones + 1] = {
      id = zone.id, gx = zone.gx, gy = zone.gy, bounds = zone.bounds,
      pending_count = zone.pending_count or 0, completed = zone.completed == true,
      work_position = zone.work_position, attempts = zone.attempts or 0,
    }
  end
  table.sort(zones, function(a, b) return a.id < b.id end)
  return {
    available = true, reach = plan.reach, grid_size = plan.grid_size,
    overlap = plan.overlap, zones = zones,
    rejected = plan.rejected or {},
  }
end

return M