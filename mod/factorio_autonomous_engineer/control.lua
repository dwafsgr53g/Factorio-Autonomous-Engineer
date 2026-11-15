local lifecycle = require("lib.lifecycle")
local safety = require("lib.safety")
local tasks = require("lib.tasks")
local strategy = require("lib.strategy")
local site_selector = require("lib.site_selector")
local construction = require("lib.construction")
local modules = require("lib.modules")
local module_placer = require("lib.module_placer")
local layout_planner = require("lib.layout_planner")
local logistics = require("lib.logistics")

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
    capabilities = {"get_briefing", "select_starting_site", "gather_resource",
      "assist_construction", "plan_layout", "apply_layout", "build_logistics",
      "safety", "respawn"}}
end
operations.strategy_context = function(s) return strategy.context(s) end
-- Internal administrative helper used by the engine harness and future code-owned site
-- selection. It is not a model-facing MCP tool and does not expose coordinates to the LLM.
operations.set_home = function(s, p) return lifecycle.set_home(s, p) end
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
  local task_capability = p.task == "assist_construction" and "assist_construction" or p.task
  local allowed = false
  for _, capability in pairs(context.available_capabilities) do
    if capability == task_capability then allowed = true break end
  end
  assert(allowed, "Requested task is not available in the current domain")
  return tasks.start(s, p)
end
operations.construction_plan_place = function(s, p)
  assert(s.agent and s.agent.valid, "Agent is not alive")
  assert(not (s.safety and s.safety.active), "Safety controller is active")
  return construction.place_plan(s, p.plan or "test_basic")
end

-- Internal module-library surface. It is deliberately not a model-facing MCP tool:
-- coordinates and raw entity lists are test/planner inputs, not LLM actions.
local function module_env(s)
  local agent = s.agent
  assert(agent and agent.valid, "Agent is not alive")
  local context = strategy.context(s)
  return {prototypes = prototypes, force = agent.force, surface = agent.surface,
    stage = context.stage.id}
end

operations.module_catalog = function(s, p)
  local env = module_env(s)
  local report = modules.report(env)
  return report
end
operations.module_validate_definition = function(s, p)
  local env = module_env(s)
  return modules.validate_definition(p.definition, env)
end
operations.module_definition = function(s, p)
  local entry = modules.resolve(module_env(s), p.module_id)
  assert(entry, "Unknown module")
  return entry.definition
end
operations.module_resolve = function(s, p)
  p.stage = p.stage or strategy.context(s).stage.id
  local resolved, reason, details = module_placer.resolve(s, p)
  if not resolved then
    return {ok = false, reason = reason, details = details}
  end
  return {ok = true, module = resolved.module, parameters = resolved.parameters,
    orientation = resolved.orientation, anchor = resolved.anchor,
    footprint = resolved.footprint, bounds = resolved.absolute_bounds,
    entities = resolved.entities, ports = resolved.ports, reserved = resolved.reserved,
    cost_estimate = resolved.cost_estimate}
end
operations.module_instantiate = function(s, p)
  assert(not (s.safety and s.safety.active), "Safety controller is active")
  p.stage = p.stage or strategy.context(s).stage.id
  local result, reason, details = module_placer.instantiate(s, p)
  if not result then
    return {ok = false, reason = reason, details = details}
  end
  return {ok = true, deduplicated = result.deduplicated, instance = result.instance,
    fingerprint = result.fingerprints}
end
operations.module_instance_status = function(s, p)
  local result, reason = module_placer.instance_status(s, p.instance_key)
  if not result then return {ok = false, reason = reason} end
  return {ok = true, instance = result}
end
operations.module_instances = function(s, p)
  return {ok = true, instances = module_placer.instances(s)}
end

-- Internal Layout Planner surface. The create/apply operations expose full internal
-- placement data for engine tests; the model-facing plan_layout/apply_layout operations
-- below return compact summaries without coordinates, entity lists or ports.
operations.layout_plan_create = function(s, p)
  assert(not (s.safety and s.safety.active), "Safety controller is active")
  return layout_planner.create(s, p)
end
operations.layout_plan_apply = function(s, p)
  assert(not (s.safety and s.safety.active), "Safety controller is active")
  return layout_planner.apply(s, p)
end

-- Internal Stage-6 physical logistics surface. These operations are used by the
-- composite build_logistics task and by the engine harness. They are not model-facing
-- tools: no coordinates, entity lists or wire data are returned to the LLM.
operations.logistics_plan_create = function(s, p)
  assert(not (s.safety and s.safety.active), "Safety controller is active")
  return logistics.plan(s, p)
end
operations.logistics_plan_debug = function(s, p)
  local ok, result = xpcall(function() return logistics.plan(s, p) end, debug.traceback)
  return {ok = ok, result = ok and result or nil, traceback = not ok and result or nil}
end
operations.logistics_ghosts_place = function(s, p)
  assert(not (s.safety and s.safety.active), "Safety controller is active")
  return logistics.place_ghosts(s, p)
end
operations.logistics_verify = function(s, p)
  return logistics.verify(s, p)
end
operations.logistics_plan_status = function(s, p)
  return logistics.status(s, p.logistics_plan_id)
end
operations.logistics_plans = function(s, p)
  return {ok = true, plans = logistics.plans(s)}
end
operations.layout_plan_status = function(s, p)
  return layout_planner.status(s, p.plan_id)
end
operations.layout_plans = function(s, p)
  return {ok = true, plans = layout_planner.plans(s)}
end
operations.layout_planner_limits = function(s, p)
  return {ok = true, limits = layout_planner.limits()}
end

local function require_capability(s, capability)
  local context = strategy.context(s)
  for _, available in pairs(context.available_capabilities) do
    if available == capability then return end
  end
  error("Requested capability is not available in the current domain")
end

operations.plan_layout = function(s, p)
  require_capability(s, "plan_layout")
  local result = layout_planner.create(s, p)
  if not result.ok then return result end
  return layout_planner.public_summary(result.plan)
end
operations.apply_layout = function(s, p)
  require_capability(s, "apply_layout")
  return layout_planner.public_apply_summary(layout_planner.apply(s, p))
end
operations.task_status = function(s, p) return tasks.status(s, p.task_id) end
operations.task_debug = function(s, p)
  local task = s.task
  if not task then return {ok = false, reason = "no_task"} end
  local function pos(entity)
    return entity and entity.valid and {x = entity.position.x, y = entity.position.y} or nil
  end
  local pending = {}
  for key, entry in pairs(task.entries or {}) do
    if entry.status == "pending" or entry.status == "building" then
      pending[#pending + 1] = {
        key = key, status = entry.status, ghost_valid = entry.ghost and entry.ghost.valid or false,
        path_failures = entry.path_failures, position = entry.position,
      }
    end
  end
  table.sort(pending, function(a, b) return a.key < b.key end)
  return {ok = true, task_id = task.id, type = task.type, status = task.status,
    phase = task.phase, phase_started_tick = task.phase_started_tick,
    target_kind = task.target_kind, target_entry = task.target_entry,
    target_ghost = pos(task.target_ghost), target_chest = pos(task.target_chest),
    path_request = task.path_request, path_index = task.path_index,
    agent = pos(s.agent), pending = pending,
    scan_dirty = task.scan_dirty, last_scan_tick = task.last_scan_tick}
end
operations.task_entries = function(s, p)
  local task = s.task
  if not task then return {ok = false, reason = "no_task"} end
  local entries = {}
  for key, entry in pairs(task.entries or {}) do
    entries[#entries + 1] = {
      key = key, name = entry.name, position = entry.position,
      status = entry.status, reason = entry.reason, missing = entry.missing,
      path_failures = entry.path_failures,
    }
  end
  table.sort(entries, function(a, b) return a.key < b.key end)
  return {ok = true, task_id = task.id, type = task.type, status = task.status,
    phase = task.phase, reason = task.reason, entries = entries}
end
operations.task_cancel = function(s, p)
  return tasks.cancel(s, p.task_id, p.reason or "cancelled")
end
operations.task_resume = function(s, p)
  assert(safety.is_safe(s), "Cannot resume while the safety controller is active")
  return tasks.resume(s, p.task_id)
end

-- Internal composite planner entry point used by the engine harness and by future
-- high-level construction tasks. It accepts only a named code-owned plan, never coordinates.
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
  -- A successful respawn clears the emergency lock, but the task remains paused
  -- until the planner explicitly inspects state and resumes it.
  if s.lifecycle and s.lifecycle.status == "alive" and s.safety
    and s.safety.active and s.safety.status == "respawning" then
    s.safety.active, s.safety.status, s.safety.reason = false, "safe", "respawned"
    s.safety.path, s.safety.path_request = nil, nil
    s.safety.destination, s.safety.destination_kind = nil, nil
  end
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
