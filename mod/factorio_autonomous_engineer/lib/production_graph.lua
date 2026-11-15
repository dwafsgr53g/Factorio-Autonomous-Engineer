-- Deterministic production dependency resolution for the Layout Planner.
--
-- The graph is derived from the declarative module catalog, module ports and the actual
-- Factorio recipe/prototype data. It never chooses a placement, creates an entity or spends
-- an item. A module's declared interfaces remain authoritative; recipes are used to verify
-- the declared production step and to distinguish recipe inputs from auxiliary inputs such
-- as furnace fuel.
--
-- Throughput analysis is deliberately absent. The resolver answers "which catalog modules
-- can form this minimal chain, and what is still missing?", not "how fast will it run?".
local format = require("lib.module_format")
local modules = require("lib.modules")

local M = {}

M.CATEGORY_PRIORITY = {
  mining = 0, smelting = 1, production = 2, power = 3, logistics = 4, other = 5,
}

local function sorted_keys(value)
  local keys = {}
  for key in pairs(value or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local function item_key(kind, name)
  return tostring(kind) .. ":" .. tostring(name)
end

local function port_kind(port)
  if port.type == "item" then return "item", port.item end
  if port.type == "fluid" then return "fluid", port.fluid end
  return "electric", nil
end

local function port_record(port)
  local kind, name = port_kind(port)
  return {
    id = port.id, type = port.type, role = port.role, kind = kind,
    item = port.item, fluid = port.fluid, connector = port.connector,
    capacity = port.capacity,
  }
end

local function recipe_products(recipe)
  local map = {}
  for _, product in ipairs(recipe.products or {}) do
    local kind = product.type == "fluid" and "fluid" or "item"
    map[item_key(kind, product.name)] = true
  end
  return map
end

local function recipe_ingredients(recipe)
  local map = {}
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    local kind = ingredient.type == "fluid" and "fluid" or "item"
    map[item_key(kind, ingredient.name)] = true
  end
  return map
end

local function recipe_accepted_by_module(def, recipe, env)
  for _, entity in ipairs((def.geometry or {}).entities or {}) do
    local proto = env.prototypes.entity[entity.name]
    if proto and proto.crafting_categories and recipe.categories then
      -- recipe.categories is an array of category names in Factorio 2.1, while
      -- entity prototyping categories are a name-keyed dictionary.
      for _, category in pairs(recipe.categories) do
        if proto.crafting_categories[category] then return true end
      end
    end
  end
  return false
end

-- Return the process recipe, its source and a diagnostic. A fixed entity recipe is
-- authoritative. A module such as the stone furnace has no script-assignable recipe, so a
-- unique force-enabled recipe producing its declared output and accepted by its entity
-- category is inferred. Ambiguity is reported instead of guessed.
local function module_recipe(def, output_keys, env)
  local fixed
  for _, entity in ipairs((def.geometry or {}).entities or {}) do
    if entity.recipe then
      if fixed and fixed ~= entity.recipe then
        return nil, nil, "conflicting_entity_recipes"
      end
      fixed = entity.recipe
    end
  end
  if fixed then
    local recipe = env.prototypes.recipe[fixed]
    if not recipe then return nil, nil, "unknown_recipe" end
    return fixed, "entity_recipe", nil, recipe
  end
  local candidates = {}
  for _, name in ipairs(sorted_keys(env.prototypes.recipe or {})) do
    local recipe = env.prototypes.recipe[name]
    local products = recipe_products(recipe)
    local produces_declared = false
    for key in pairs(output_keys) do
      if products[key] then produces_declared = true break end
    end
    local force_recipe = env.force and env.force.recipes and env.force.recipes[name] or nil
    local enabled = force_recipe == nil or force_recipe.enabled == true
    if produces_declared and enabled and recipe_accepted_by_module(def, recipe, env) then
      candidates[#candidates + 1] = name
    end
  end
  if #candidates == 0 then return nil, nil, "unsupported_production_step" end
  if #candidates > 1 then
    return nil, nil, "ambiguous_recipe", nil, candidates
  end
  local name = candidates[1]
  return name, "inferred_output_recipe", nil, env.prototypes.recipe[name]
end

function M.analyze_module(entry, env)
  local def = entry.definition
  local expanded = format.expand(def, {}, 0)
  local analysis = {
    module_id = def.id, module_version = def.module_version,
    name = def.name, category = def.category,
    available = entry.availability.available,
    availability_reasons = entry.availability_reasons,
    inputs = {}, outputs = {}, electric_inputs = {}, electric_outputs = {},
    kind = nil, recipe = nil, recipe_source = nil, unsupported = nil,
    external_inputs = {}, produced_keys = {},
  }
  if not expanded then
    analysis.unsupported = "geometry_expansion_failed"
    return analysis
  end
  for _, port in ipairs(expanded.ports) do
    local record = port_record(port)
    if port.type == "electric" then
      if port.role == "input" or port.role == "bidirectional" then
        analysis.electric_inputs[#analysis.electric_inputs + 1] = record
      end
      if port.role == "output" or port.role == "bidirectional" then
        analysis.electric_outputs[#analysis.electric_outputs + 1] = record
      end
    else
      if port.role == "input" or port.role == "bidirectional" then
        analysis.inputs[#analysis.inputs + 1] = record
      end
      if port.role == "output" or port.role == "bidirectional" then
        analysis.outputs[#analysis.outputs + 1] = record
        analysis.produced_keys[item_key(record.kind, record.item or record.fluid)] = true
      end
    end
  end

  local output_keys = {}
  for _, port in ipairs(analysis.outputs) do
    output_keys[item_key(port.kind, port.item or port.fluid)] = true
  end
  local recipe_name, source, reason, recipe, candidates = module_recipe(def, output_keys, env)
  if reason then
    if reason == "unsupported_production_step" and #analysis.outputs > 0 then
      -- A mining module extracts a resource directly rather than crafting from ingredients.
      local extraction = true
      for _, port in ipairs(analysis.outputs) do
        local proto = port.item and env.prototypes.entity[port.item] or nil
        if not proto or proto.type ~= "resource" then extraction = false break end
      end
      if extraction and analysis.category == "mining" then
        analysis.kind = "extraction"
        analysis.external_inputs = analysis.inputs
        return analysis
      end
    end
    analysis.unsupported = reason
    analysis.recipe_candidates = candidates
    return analysis
  end
  analysis.kind = "recipe"
  analysis.recipe = {name = recipe_name, source = source}
  analysis.recipe_products = recipe_products(recipe)
  analysis.recipe_ingredients = recipe_ingredients(recipe)
  for _, port in ipairs(analysis.outputs) do
    if port.kind ~= "electric" then
      local key = item_key(port.kind, port.item or port.fluid)
      if not analysis.recipe_products[key] then
        analysis.unsupported = "declared_output_not_in_recipe"
        return analysis
      end
    end
  end
  -- Declared inputs that are not recipe ingredients are auxiliary interfaces (for
  -- example furnace fuel). They are never silently treated as supplied.
  local auxiliary = {}
  for _, port in ipairs(analysis.inputs) do
    local key = item_key(port.kind, port.item or port.fluid)
    if not analysis.recipe_ingredients[key] then auxiliary[#auxiliary + 1] = port end
  end
  analysis.auxiliary_inputs = auxiliary
  analysis.external_inputs = auxiliary
  return analysis
end

local function build_indexes(catalog, env)
  local analyses, producers, consumers = {}, {item = {}, fluid = {}}, {item = {}, fluid = {}}
  for _, summary in ipairs(catalog.modules) do
    local entry = catalog.by_id[summary.id]
    local analysis = M.analyze_module(entry, env)
    analyses[summary.id] = analysis
    for _, port in ipairs(analysis.outputs) do
      local key = item_key(port.kind, port.item or port.fluid)
      producers[key] = producers[key] or {}
      producers[key][#producers[key] + 1] = {
        module_id = summary.id, port_id = port.id, kind = port.kind,
        available = analysis.available,
      }
    end
    for _, port in ipairs(analysis.inputs) do
      local key = item_key(port.kind, port.item or port.fluid)
      consumers[key] = consumers[key] or {}
      consumers[key][#consumers[key] + 1] = {
        module_id = summary.id, port_id = port.id, kind = port.kind,
        available = analysis.available,
      }
    end
  end
  return analyses, producers, consumers
end

local function sorted_candidates(list)
  table.sort(list, function(a, b)
    local pa = M.CATEGORY_PRIORITY[a.category] or 9
    local pb = M.CATEGORY_PRIORITY[b.category] or 9
    if pa ~= pb then return pa < pb end
    return a.module_id < b.module_id
  end)
  return list
end

local function choose_producer(index, key, analyses)
  local candidates = {}
  for _, candidate in ipairs(index[key] or {}) do
    local analysis = analyses[candidate.module_id]
    if not analysis.unsupported then
      candidates[#candidates + 1] = {
        module_id = candidate.module_id, port_id = candidate.port_id,
        category = analysis.category, available = analysis.available,
        availability_reasons = analysis.availability_reasons,
      }
    end
  end
  sorted_candidates(candidates)
  local available = {}
  for _, candidate in ipairs(candidates) do
    if candidate.available then available[#available + 1] = candidate end
  end
  if #available > 0 then return available[1], candidates end
  return nil, candidates
end

local function add_missing(missing_map, record)
  local key = table.concat({record.code, tostring(record.kind), tostring(record.item),
    tostring(record.node_id), tostring(record.port_id)}, "|")
  if not missing_map[key] then
    missing_map[key] = record
  end
end

local function sorted_records(map, comparator)
  local records = {}
  for _, record in pairs(map) do records[#records + 1] = record end
  table.sort(records, comparator)
  return records
end

local function record_sort(a, b)
  if a.code ~= b.code then return a.code < b.code end
  if tostring(a.kind) ~= tostring(b.kind) then return tostring(a.kind) < tostring(b.kind) end
  if tostring(a.item) ~= tostring(b.item) then return tostring(a.item) < tostring(b.item) end
  if tostring(a.node_id) ~= tostring(b.node_id) then
    return tostring(a.node_id) < tostring(b.node_id)
  end
  return tostring(a.port_id) < tostring(b.port_id)
end

local function edge_sort(a, b)
  local left = table.concat({tostring(a.from), tostring(a.from_port), tostring(a.to),
    tostring(a.to_port), tostring(a.kind), tostring(a.item), tostring(a.status)}, "|")
  local right = table.concat({tostring(b.from), tostring(b.from_port), tostring(b.to),
    tostring(b.to_port), tostring(b.kind), tostring(b.item), tostring(b.status)}, "|")
  return left < right
end

-- Resolve a minimal module set for one requested output item.
--
-- env: {prototypes=prototypes, force=force, surface=surface, stage=stage}
function M.resolve(env, goal_item)
  if type(goal_item) ~= "string" or goal_item == "" then
    return nil, {code = "invalid_goal_item", message = "goal_item must be a non-empty string"}
  end
  if not env.prototypes.item[goal_item] then
    return nil, {code = "unknown_goal_item", message = "unknown item prototype '"
      .. goal_item .. "'"}
  end
  local catalog = modules.load(env)
  local analyses, producers, consumers = build_indexes(catalog, env)
  local goal_key = item_key("item", goal_item)
  local goal_node = nil
  local nodes, nodes_by_module, order = {}, {}, {}
  local edges, missing_map = {}, {}
  local resolving = {}
  local category_count = {}

  local ensure_node

  local function add_electric_requirements(node, analysis)
    for _, port in ipairs(analysis.electric_inputs) do
      local edge = {
        from = "external:electric-network", from_port = nil, to = node.id,
        to_port = port.id, kind = "electric", item = nil,
        status = "unresolved", routing_required = false,
        physical_connection = false, requirement = "electric_network",
        port_position_unresolved = true,
      }
      edges[#edges + 1] = edge
      add_missing(missing_map, {
        code = "external_infrastructure", kind = "infrastructure",
        item = "electric-network", node_id = node.id, port_id = port.id,
        external = true, mandatory = true,
        message = "electric power must come from an existing network or a future power module",
      })
    end
  end

  local function connect_input(node, analysis, port)
    local key = item_key(port.kind, port.item or port.fluid)
    local producer, candidates = choose_producer(producers, key, analyses)
    if producer and not resolving[producer.module_id] then
      local supplier = ensure_node(producer.module_id)
      if supplier then
        edges[#edges + 1] = {
          from = supplier.id, from_port = producer.port_id,
          to = node.id, to_port = port.id, kind = port.kind,
          item = port.item or port.fluid, status = "route_required",
          routing_required = true, physical_connection = false,
        }
        return
      end
    end
    local auxiliary = false
    for _, candidate in ipairs(analysis.auxiliary_inputs or {}) do
      if candidate.id == port.id then auxiliary = true break end
    end
    local unavailable_reasons = nil
    if candidates and #candidates > 0 then
      unavailable_reasons = {}
      for _, candidate in ipairs(candidates) do
        unavailable_reasons[#unavailable_reasons + 1] = {
          module_id = candidate.module_id,
          reasons = candidate.availability_reasons or {"module_unavailable"},
        }
      end
    end
    edges[#edges + 1] = {
      from = "missing:" .. key, from_port = nil, to = node.id,
      to_port = port.id, kind = port.kind, item = port.item or port.fluid,
      status = "missing_supplier", routing_required = true,
      physical_connection = false,
      reason = producer and "cycle_in_dependency_graph" or "no_available_module_outputs_item",
    }
    add_missing(missing_map, {
      code = "missing_supplier", kind = auxiliary and "fuel" or port.kind,
      item = port.item or port.fluid, node_id = node.id, port_id = port.id,
      external = true, mandatory = true,
      candidates = unavailable_reasons,
      message = "no available catalog module supplies " .. tostring(port.item or port.fluid)
        .. (auxiliary and " (auxiliary/fuel input)" or ""),
    })
  end

  ensure_node = function(module_id)
    local existing = nodes_by_module[module_id]
    if existing then return existing end
    local entry = catalog.by_id[module_id]
    local analysis = analyses[module_id]
    if not entry or not analysis then return nil end
    if resolving[module_id] then return nil end
    local count = (category_count[analysis.category] or 0) + 1
    category_count[analysis.category] = count
    local node = {
      id = analysis.category .. "_" .. tostring(count),
      module_id = module_id, module_version = analysis.module_version,
      name = analysis.name, category = analysis.category,
      recipe = analysis.recipe, kind = analysis.kind or "unsupported",
      inputs = analysis.inputs, outputs = analysis.outputs,
      electric_inputs = analysis.electric_inputs,
      availability = analysis.available,
      availability_reasons = analysis.availability_reasons,
      unsupported = analysis.unsupported,
    }
    nodes[#nodes + 1] = node
    nodes_by_module[module_id] = node
    if analysis.unsupported then
      add_missing(missing_map, {
        code = "unsupported_production_step", kind = "production",
        item = goal_item, node_id = node.id, port_id = nil, external = false,
        mandatory = true, message = "module '" .. module_id .. "' cannot be resolved: "
          .. tostring(analysis.unsupported),
      })
      order[#order + 1] = node.id
      return node
    end
    resolving[module_id] = true
    add_electric_requirements(node, analysis)
    local remaining_auxiliary = {}
    for _, port in ipairs(analysis.inputs) do
      local auxiliary = false
      for _, candidate in ipairs(analysis.auxiliary_inputs or {}) do
        if candidate.id == port.id then auxiliary = true break end
      end
      if auxiliary then
        remaining_auxiliary[#remaining_auxiliary + 1] = port
      else
        connect_input(node, analysis, port)
      end
    end
    -- Auxiliary interfaces are reported against the world rather than recursively
    -- resolved by a recipe producer; a future fuel-supply module may claim them.
    for _, port in ipairs(remaining_auxiliary) do
      connect_input(node, analysis, port)
    end
    resolving[module_id] = nil
    order[#order + 1] = node.id
    return node
  end

  local goal_producer, goal_candidates = choose_producer(producers, goal_key, analyses)
  if not goal_producer then
    local candidates = {}
    for _, candidate in ipairs(goal_candidates or {}) do
      candidates[#candidates + 1] = {
        module_id = candidate.module_id,
        reasons = candidate.availability_reasons or {"module_unavailable"},
      }
    end
    return {
      goal_item = goal_item, status = "unsupported", nodes = {}, order = {}, edges = {},
      missing = {{
        code = "missing_supplier", kind = "item", item = goal_item,
        node_id = nil, port_id = nil, external = true, mandatory = true,
        candidates = candidates,
        message = "no available catalog module produces the requested goal item",
      }},
      external_dependencies = {},
      available_modules = {},
      selected_modules = {},
      requested_output = goal_item,
      throughput_analysis = "not_implemented",
      minimal_module_set = true,
      consumers = {},
      producers = {},
    }
  end
  goal_node = ensure_node(goal_producer.module_id)
  local goal_edge = nil
  if goal_node then
    for _, port in ipairs(goal_node.outputs) do
      if port.type == "item" and port.item == goal_item then
        goal_edge = {port = port}
        break
      end
    end
    if goal_edge then
      edges[#edges + 1] = {
        from = goal_node.id, from_port = goal_edge.port.id, to = "requested_output",
        to_port = nil, kind = "item", item = goal_item, status = "requested_output",
        routing_required = false, physical_connection = false,
      }
    end
  end

  local missing = sorted_records(missing_map, record_sort)
  table.sort(edges, edge_sort)
  local ordered_nodes = {}
  local seen_order = {}
  for _, node_id in ipairs(order) do
    if not seen_order[node_id] then
      seen_order[node_id] = true
      for _, node in ipairs(nodes) do
        if node.id == node_id then ordered_nodes[#ordered_nodes + 1] = node break end
      end
    end
  end
  local sorted_nodes = {}
  for _, node in ipairs(nodes) do sorted_nodes[#sorted_nodes + 1] = node end
  table.sort(sorted_nodes, function(a, b) return a.id < b.id end)
  local external = {}
  for _, record in ipairs(missing) do
    if record.external then external[#external + 1] = record end
  end
  local available_modules = {}
  for _, summary in ipairs(catalog.modules) do
    available_modules[#available_modules + 1] = {
      module_id = summary.id, name = summary.name, category = summary.category,
      available = summary.available,
    }
  end
  local selected_modules = {}
  for _, node in ipairs(ordered_nodes) do
    selected_modules[#selected_modules + 1] = {
      instance_id = node.id, module_id = node.module_id, name = node.name,
      category = node.category, parameters = {}, recipe = node.recipe,
    }
  end
  local consumers_summary, producers_summary = {}, {}
  for _, key in ipairs(sorted_keys(consumers)) do
    local list = {}
    for _, candidate in ipairs(consumers[key]) do list[#list + 1] = candidate.module_id end
    table.sort(list)
    consumers_summary[key] = list
  end
  for _, key in ipairs(sorted_keys(producers)) do
    local list = {}
    for _, candidate in ipairs(producers[key]) do list[#list + 1] = candidate.module_id end
    table.sort(list)
    producers_summary[key] = list
  end
  return {
    goal_item = goal_item,
    requested_output = goal_item,
    status = #missing > 0 and "partial" or "complete",
    nodes = sorted_nodes, order = order, edges = edges,
    missing = missing, external_dependencies = external,
    available_modules = available_modules, selected_modules = selected_modules,
    consumers = consumers_summary, producers = producers_summary,
    throughput_analysis = "not_implemented", minimal_module_set = true,
    recipe_data_source = "live_prototypes",
  }
end

-- Evaluate electric edges once placements exist. A nearby pole with a live network is the
-- only accepted proof that the actual world can supply power in this stage. It still does
-- not prove that the entity is inside the pole's supply area, so physical_connection stays
-- false and the limitation is reported.
function M.evaluate_infrastructure(graph, context)
  local surface = context.surface
  local bounds_by_node = context.bounds_by_node or {}
  local radius = context.radius or 16
  local counts = {externally_supplied = 0, missing_supplier = 0}
  local missing_power_nodes = {}
  for _, edge in ipairs(graph.edges) do
    if edge.kind == "electric" then
      local bounds = bounds_by_node[edge.to]
      local poles = 0
      if surface and bounds then
        local expanded = {
          {x = bounds[1].x - radius, y = bounds[1].y - radius},
          {x = bounds[2].x + radius, y = bounds[2].y + radius},
        }
        for _, pole in pairs(surface.find_entities_filtered{
          area = expanded, type = "electric-pole"}) do
          if pole.valid and pole.electric_network_id then poles = poles + 1 end
        end
      end
      edge.network_poles_in_radius = poles
      edge.physical_connection = false
      edge.network_presence_only = true
      if poles > 0 then
        edge.status = "externally_supplied"
        edge.external_source = "existing_electric_network"
        counts.externally_supplied = counts.externally_supplied + 1
      else
        edge.status = "missing_supplier"
        edge.reason = "no_existing_electric_network_in_range"
        counts.missing_supplier = counts.missing_supplier + 1
        missing_power_nodes[edge.to] = true
      end
    end
  end
  local external = {}
  local seen = {}
  for _, record in ipairs(graph.missing or {}) do
    local include = true
    if record.kind == "infrastructure" and record.item == "electric-network" then
      include = missing_power_nodes[record.node_id] == true
    end
    local key = table.concat({record.code, tostring(record.kind), tostring(record.item)}, "|")
    if include and not seen[key] then
      seen[key] = true
      local copy = {}
      for field, value in pairs(record) do copy[field] = value end
      external[#external + 1] = copy
    end
  end
  table.sort(external, record_sort)
  graph.external_dependencies = external
  return {counts = counts, external_dependencies = external,
    missing_power_nodes = missing_power_nodes}
end

function M.recipe_for(env, recipe_name)
  if not recipe_name then return nil end
  return env.prototypes.recipe[recipe_name]
end

return M
