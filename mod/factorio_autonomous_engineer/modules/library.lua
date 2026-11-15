-- Parse-time module loading.
--
-- Factorio 2.1 only permits require() while control.lua is being parsed. The catalog
-- therefore resolves the explicit manifest and every module file here, at require time,
-- and the runtime catalog reads this preloaded table. No filesystem scan or dynamic
-- require happens during gameplay ticks or RCON operations.
local ok_manifest, manifest = pcall(require, "modules.manifest")
if not ok_manifest then
  return {manifest = nil, manifest_error = tostring(manifest), definitions = {}}
end

local definitions, errors = {}, {}
for _, path in ipairs(manifest.modules or {}) do
  local ok, def = pcall(require, path)
  if ok and type(def) == "table" then
    definitions[#definitions + 1] = {path = path, def = def}
  else
    errors[#errors + 1] = {
      code = "module_load_failed", module_path = path,
      message = "failed to load '" .. tostring(path) .. "': " .. tostring(def),
    }
  end
end
return {manifest = manifest, definitions = definitions, errors = errors}
