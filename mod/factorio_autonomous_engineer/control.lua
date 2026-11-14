local lifecycle = require("lib.lifecycle")
local safety = require("lib.safety")
local tasks = require("lib.tasks")
local strategy = require("lib.strategy")
local site_selector = require("lib.site_selector")

local function state()
  storage.autonomous_engineer = storage.autonomous_engineer or {
    cache = {}, cache_order = {}, events = {}, next_event_id = 0,
  }
  return storage.autonomous_engineer
end

local operations = {}
operations.ping = function(s)
  return {mod_version = "0.1.0-dev", factorio_version = script.active_mods.base,
    agent_state = lifecycle.status(s),
    capabilities = {"get_briefing", "select_starting_site", "gather_resource", "safety", "respawn"}}
end
operations.strategy_context = function(s) return strategy.context(s) end
operations.select_starting_site = function(s)
  local context = strategy.context(s)
  assert(context.stage.id == "early_game" or context.stage.id == "automation_bootstrap",
    "Starting-site selection is only available during the bootstrap stage")
  return site_selector.select(s)
end
operations.agent_status = function(s)
  local agent = s.agent and s.agent.valid and s.agent or nil
  return {
    lifecycle = lifecycle.status(s),
    safety = safety.status(s),
    task = tasks.status(s),
    inventory = agent and agent.get_main_inventory().get_contents() or {},
  }
end
operations.agent_events = function(s, p)
  return lifecycle.events(s, p.limit or 20, p.after_id or 0)
end
operations.task_start = function(s, p)
  local context = strategy.context(s)
  local allowed = false
  for _, capability in pairs(context.available_capabilities) do
    if capability == "gather_resource" then allowed = true break end
  end
  assert(allowed, "Resource gathering is not available in the current domain")
  return tasks.start(s, p)
end
operations.task_status = function(s, p) return tasks.status(s, p.task_id) end
operations.task_cancel = function(s, p)
  return tasks.cancel(s, p.task_id, p.reason or "cancelled")
end
operations.task_resume = function(s, p)
  assert(safety.is_safe(s), "Cannot resume while the safety controller is active")
  return tasks.resume(s, p.task_id)
end

commands.add_command("ae", "Factorio Autonomous Engineer RCON bridge", function(command)
  if command.player_index then return end
  local decoded, request = pcall(helpers.json_to_table, command.parameter or "")
  if not decoded or type(request) ~= "table" or type(request.id) ~= "string" then
    rcon.print(helpers.table_to_json({ok = false, error = "Invalid request"}))
    return
  end
  local s = state()
  local cached = s.cache[request.id]
  if cached then rcon.print(cached) return end
  local handler = operations[request.operation]
  local ok, result = pcall(function()
    assert(handler, "Unknown operation: " .. tostring(request.operation))
    return handler(s, request.params or {})
  end)
  local encoded, response = pcall(helpers.table_to_json, {
    id = request.id, ok = ok, tick = game.tick,
    result = ok and result or nil, error = not ok and tostring(result) or nil,
  })
  if not encoded then
    response = helpers.table_to_json({id = request.id, ok = false,
      error = "Result serialization failed; inspect task status before retrying"})
  end
  s.cache[request.id] = response
  s.cache_order[#s.cache_order + 1] = request.id
  if #s.cache_order > 512 then s.cache[table.remove(s.cache_order, 1)] = nil end
  rcon.print(response)
end)

script.on_init(function()
  local s = state()
  lifecycle.initialize(s)
end)
script.on_configuration_changed(function()
  local s = state()
  lifecycle.initialize(s)
end)
script.on_event(defines.events.on_tick, function()
  local s = state()
  lifecycle.tick(s)
  safety.tick(s)
  tasks.tick(s)
end)
script.on_event(defines.events.on_entity_damaged, function(event)
  safety.on_damaged(state(), event)
end)
script.on_event(defines.events.on_entity_died, function(event)
  local s = state()
  if lifecycle.on_died(s, event) then
    safety.on_agent_died(s, event)
    tasks.on_agent_died(s)
  end
end)
script.on_event(defines.events.on_script_path_request_finished, function(event)
  local s = state()
  safety.path_finished(s, event)
  tasks.path_finished(s, event)
end)

remote.add_interface("factorio_autonomous_engineer", {
  get_agent = function() return state().agent end,
  get_status = function() return operations.agent_status(state()) end,
  invoke = function(operation, params)
    assert(operations[operation], "Unknown operation")
    return operations[operation](state(), params or {})
  end,
})
