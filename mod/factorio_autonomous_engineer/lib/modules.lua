-- Module catalog: loads the declarative library, rejects duplicates and invalid
-- definitions, resolves stable ids and reports force/surface availability.
--
-- Definitions are Lua data files. There is no filesystem scan: modules/manifest.lua is the
-- single explicit list of canonical module files. A module that fails validation is
-- excluded entirely instead of being partially interpreted.
local format = require("lib.module_format")
local library = require("modules.library")

local M = {}

M.MANIFEST_SCHEMA_VERSION = 1

local function add_error(errors, code, module_id, message, details)
  errors[#errors + 1] = {
    code = code, module_id = module_id, message = message, details = details,
  }
end

local function validate_manifest()
  local errors = {}
  local manifest = library.manifest
  if library.manifest_error then
    add_error(errors, "manifest_load_failed", nil, library.manifest_error)
    return nil, errors
  end
  if type(manifest) ~= "table" then
    add_error(errors, "invalid_manifest", nil, "manifest must return a table")
    return nil, errors
  end
  if manifest.schema_version ~= M.MANIFEST_SCHEMA_VERSION then
    add_error(errors, "unsupported_manifest_version", nil,
      "expected manifest schema_version " .. M.MANIFEST_SCHEMA_VERSION
        .. ", got " .. tostring(manifest.schema_version))
    return nil, errors
  end
  if type(manifest.modules) ~= "table" or #manifest.modules == 0 then
    add_error(errors, "invalid_manifest", nil, "manifest.modules must be a non-empty list")
    return nil, errors
  end
  local seen = {}
  for index, module_path in ipairs(manifest.modules) do
    if type(module_path) ~= "string" or not string.match(module_path, "^modules%.[%w_]+$") then
      add_error(errors, "invalid_manifest_entry", nil,
        "manifest entry " .. index .. " must be a module path like modules.example")
    elseif seen[module_path] then
      add_error(errors, "duplicate_manifest_entry", nil,
        "manifest lists '" .. module_path .. "' more than once")
    end
    seen[module_path] = true
  end
  return manifest, errors
end

-- env: {prototypes=prototypes, force=..., surface=..., stage=...}
function M.load(env)
  env = env or {prototypes = prototypes, force = game.forces.player}
  local manifest, manifest_errors = validate_manifest()
  local catalog = {
    schema_version = format.SCHEMA_VERSION,
    manifest_schema_version = M.MANIFEST_SCHEMA_VERSION,
    modules = {}, by_id = {}, errors = manifest_errors or {},
    loaded = 0, invalid = 0,
  }
  for _, error in ipairs(library.errors or {}) do
    add_error(catalog.errors, error.code, nil, error.message)
  end
  if not manifest then return catalog end
  local definitions = library.definitions

  local counts = {}
  for _, entry in ipairs(definitions) do
    local id = entry.def.id
    if type(id) == "string" then counts[id] = (counts[id] or 0) + 1 end
  end

  for _, entry in ipairs(definitions) do
    local def = entry.def
    local module_id = type(def.id) == "string" and def.id or entry.path
    local errors = format.validate_definition(def, env)
    if #errors > 0 then
      catalog.invalid = catalog.invalid + 1
      add_error(catalog.errors, "module_invalid", module_id,
        "module definition failed validation", errors)
    elseif type(def.id) == "string" and counts[def.id] > 1 then
      catalog.invalid = catalog.invalid + 1
      add_error(catalog.errors, "duplicate_module_id", module_id,
        "module id '" .. def.id .. "' is defined by more than one canonical file")
    else
      local availability = format.availability(def, env)
      local summary = format.summary(def)
      summary.path = entry.path
      summary.available = availability.available
      summary.availability_reasons = availability.reasons
      summary.default_cost = format.cost_estimate(def, {}, 0)
      catalog.modules[#catalog.modules + 1] = summary
      catalog.by_id[def.id] = {
        definition = def, summary = summary, availability = availability,
        availability_reasons = availability.reasons,
      }
      catalog.loaded = catalog.loaded + 1
    end
  end
  table.sort(catalog.modules, function(a, b) return a.id < b.id end)
  table.sort(catalog.errors, function(a, b)
    if a.code ~= b.code then return a.code < b.code end
    return tostring(a.module_id) < tostring(b.module_id)
  end)
  return catalog
end

function M.resolve(env, module_id)
  if type(module_id) ~= "string" then
    return nil, {{code = "invalid_module_id", message = "module id must be a string"}}
  end
  local catalog = M.load(env)
  local entry = catalog.by_id[module_id]
  if entry then return entry, catalog end
  local errors = {{code = "unknown_module", message = "unknown or invalid module '"
    .. module_id .. "'"}}
  for _, error in ipairs(catalog.errors) do
    if error.module_id == module_id then errors[#errors + 1] = error end
  end
  return nil, errors, catalog
end

function M.report(env)
  local catalog = M.load(env)
  return {
    schema_version = catalog.schema_version,
    manifest_schema_version = catalog.manifest_schema_version,
    loaded = catalog.loaded, invalid = catalog.invalid,
    modules = catalog.modules, errors = catalog.errors,
  }
end

function M.validate_definition(def, env)
  local errors = format.validate_definition(def, env)
  return {ok = #errors == 0, errors = errors}
end

return M
