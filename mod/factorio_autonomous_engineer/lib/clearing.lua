-- Terrain clearing performed through the character's normal mining mechanic.
-- Only natural trees and rocks are eligible. Player-owned entities, chests and
-- resources are never removed by this module.
local M = {}

local MINE_RANGE = 4.0

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function is_rock_name(name)
  return type(name) == "string" and string.find(name, "rock", 1, true) ~= nil
end

function M.is_clearable(entity)
  if not entity or not entity.valid then return false end
  if entity.type == "tree" then return true end
  if entity.type == "simple-entity" and is_rock_name(entity.name) then
    return entity.minable == true
  end
  return false
end

function M.describe(entity)
  if not entity or not entity.valid then return nil end
  return {name = entity.name, type = entity.type}
end

-- mine_entity is a script-level equivalent of the character's ordinary mining action.
-- The caller is responsible for walking into reach first; this guard prevents accidental
-- remote clearing if a future caller forgets the movement step.
function M.mine(agent, entity)
  if not entity or not entity.valid then return true, "already_cleared" end
  if not M.is_clearable(entity) then return false, "not_clearable" end
  if not agent or not agent.valid then return false, "agent_unavailable" end
  if distance(agent.position, entity.position) > MINE_RANGE then return false, "out_of_reach" end
  local ok, mined = pcall(function() return agent.mine_entity(entity) end)
  if not ok then return false, "mine_error" end
  if not mined then return false, "inventory_full_or_not_minable" end
  if entity.valid then return false, "mine_no_effect" end
  return true
end

function M.mine_range()
  return MINE_RANGE
end

return M
