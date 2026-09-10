-- Alter is loaded only by the project tooling API, never the LuaLS entry.
local project = require('luals_composer.project')
local identity = require('luals_composer.version')
local contract = require('luals_composer.contract')
local manifest = require('luals_composer.manifest')
local semver = require('luals_composer.semver')
local M = {}
local Plan = {}
Plan.__index = Plan

local function failure(code, message, extra)
  local codes = {
    invalid_options='config_conflict', invalid_config='config_conflict', invalid_registry='config_conflict', unsupported_config='config_conflict',
    ambiguous_migration='source_conflict', missing_environment='transport_missing', missing_transport='transport_missing',
    unverified_transport='transport_unidentified', incompatible_transport='transport_incompatible',
    invalid_plugin='plugin_conflict', missing_plugin='plugin_conflict', duplicate_plugin='plugin_conflict',
    -- Distinct on purpose: a caller that offered only a name can catch this
    -- one and retry with an explicit descriptor.
    undescribed_plugin='plugin_undescribed',
    missing_dependency='io_error', write_failed='io_error', activation_failed='io_error', render_failed='io_error',
  }
  local err = extra or {}
  err.code, err.message = codes[code] or code, message
  return nil, err
end

local function clone(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = clone(v) end
  return out
end

local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function setting(doc, name)
  local flat, nested = doc:value_at({'runtime.' .. name}), doc:value_at({'runtime', name})
  if flat ~= nil and nested ~= nil then return nil, 'both dotted and nested runtime.' .. name .. ' are configured' end
  if flat ~= nil then return flat end
  return nested
end

local function paths(value)
  if value == nil then return {} end
  if type(value) == 'string' and value ~= '' then return {value} end
  if contract.array(value, true) then return value end
  return nil
end

function Plan:preview()
  return { config = self.config_text, sidecar = self.sidecar_text,
    changes = clone(self.changes), warnings = clone(self.warnings), summary = self.summary }
end

function Plan:result(changed, changes)
  return {
    changed = changed,
    config = self.config_path,
    registry = self.sidecar_path,
    transport = clone(self.transport),
    plugin = clone(self.plugin),
    changes = clone(changes or self.changes),
    warnings = clone(self.warnings),
  }
end

function Plan:commit()
  if self.committed then return self:result(false, {}) end
  for path, snapshot in pairs(self.snapshots) do
    local current, read_error, read_code = project.read_file(path)
    if current == nil and read_error and read_code ~= 2 then return failure('io_error', 'could not read planning input: ' .. path, {cause=read_error,path=path}) end
    if current ~= snapshot.text then return failure('stale_plan', 'file changed after planning: ' .. path, {path=path}) end
  end
  local sidecar, err = self.sidecar_doc:commit()
  if not sidecar then return failure('write_failed', 'could not write Composer registry', {cause=err, path=self.sidecar_path, partial=false}) end
  -- The sidecar is written first. Existing Composer users may see the new
  -- registry before this activation write; this is explicitly not atomic.
  if project.read_file(self.config_path) ~= self.snapshots[self.config_path].text then
    return failure('stale_plan', 'LuaLS config changed while writing registry', {path=self.config_path, partial=sidecar.changed, written=sidecar.changed and {self.sidecar_path} or {}})
  end
  local config
  config, err = self.config_doc:commit()
  if not config then return failure('activation_failed', 'registry written but LuaLS activation failed',
    {cause=err, path=self.config_path, partial=sidecar.changed, written=sidecar.changed and {self.sidecar_path} or {}}) end
  self.committed = true
  return self:result(sidecar.changed or config.changed)
end

function M.plan(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then return failure('invalid_options', 'plan options must be a table') end
  local root = opts.root or opts.cwd
  if type(root) ~= 'string' or root == '' then return failure('invalid_options', 'root must name the project directory') end
  root = root:gsub('/+$', '')
  if root == '' then root = '/' end
  local plugin = clone(opts.plugin)
  -- `plugin = "valua"` is shorthand for `plugin = { name = "valua" }`; both ask
  -- the named package to describe itself. See the descriptor completion below.
  if type(plugin) == 'string' then plugin = { name = plugin } end
  if type(plugin) ~= 'table' then return failure('invalid_plugin', 'plugin descriptor is required') end
  if plugin.priority ~= nil and plugin.priority ~= 'first' and plugin.priority ~= 'last' then return failure('order_conflict', 'priority must be first or last') end
  local runtime, lua_dir = project.lua_runtime(root)
  if not runtime then return failure('missing_environment', lua_dir) end
  local entry = project.installed_transport_path(root)
  local absolute_entry = project.absolute(entry, root)
  if not project.exists(absolute_entry) then return failure('missing_transport', 'Composer is not installed; add moonstone/luals-composer and run moon sync', {path=absolute_entry}) end
  local installed = project.transport_identity_at(absolute_entry)
  if not installed or installed.PACKAGE ~= identity.PACKAGE or installed.CONTRACT ~= identity.CONTRACT
    or not semver.parse(installed.VERSION) then return failure('unverified_transport', 'installed Composer has no compatible PACKAGE/VERSION/CONTRACT identity') end
  -- DESCRIPTOR COMPLETION, the one additive branch.
  --
  -- `path` is the discriminator: a descriptor without one could never validate
  -- before this existed ("plugin path must be nonempty"), so no working caller
  -- changes behaviour. With a path, this is untouched explicit-descriptor mode.
  -- Without one, the named package is asked to describe itself, and anything
  -- the caller DID supply still wins — an override stays possible field by
  -- field. Either way the descriptor leaves here by the same door and is
  -- validated by the same `contract.validate` call below; there is no second,
  -- looser route into the registry.
  if plugin.path == nil then
    local described, lookup_error, kind = manifest.resolve(root, plugin)
    if not described then
      -- A package that said nothing gets the distinct code, because the
      -- caller's fix is to fall back. A package that said something wrong is
      -- an ordinary bad descriptor, and reads as one.
      return failure(kind == 'missing' and 'undescribed_plugin' or 'invalid_plugin',
        lookup_error, {plugin=plugin.name})
    end
    for key, value in pairs(described) do
      if plugin[key] == nil then plugin[key] = clone(value) end
    end
  end
  plugin.module = nil
  local valid, validation_error = contract.validate(plugin, installed.VERSION, false)
  if not valid then
    local parsed = semver.satisfies(installed.VERSION, plugin.transport)
    if parsed == false then return failure('incompatible_transport', validation_error) end
    return failure('invalid_plugin', validation_error)
  end
  local supported, version_error = semver.satisfies(installed.VERSION, plugin.transport)
  if not supported then return failure('incompatible_transport', version_error or 'installed Composer does not satisfy ' .. plugin.transport) end
  plugin.path = project.portable(plugin.path, root)
  if not project.exists(project.absolute(plugin.path, root)) then return failure('missing_plugin', 'plugin file does not exist: ' .. plugin.path) end
  if project.absolute(plugin.path, root) == absolute_entry then return failure('invalid_plugin', 'Composer cannot enroll itself') end
  plugin.args = plugin.args or {}

  local loaded, alter = pcall(require, 'alter')
  local backend_ok, backend = pcall(require, 'alter_jsonc')
  if not loaded or not backend_ok then return failure('missing_dependency', 'enrollment requires moonstone/alter and moonstone/alter-jsonc') end
  local config_path = project.absolute(opts.config or project.CONFIG_BASENAME, root)
  -- The canonical selector is workspace-relative, as LuaLS supplies a scope
  -- URI rather than its config-file location to the plugin.
  if config_path ~= project.absolute(project.CONFIG_BASENAME, root) then
    return failure('unsupported_config', 'managed enrollment currently requires the project-root .luarc.json')
  end
  if project.exists(root .. '/.luarc.jsonc') then return failure('config_conflict', '.luarc.jsonc also exists; choose one LuaLS configuration before enrollment') end
  for _, key in ipairs({'LUALS_COMPOSER_PLUGINS', 'LUALS_COMPOSER_CONFIG'}) do
    local value = os.getenv(key)
    if value and value ~= '' then return failure('config_conflict', key .. ' overrides project configuration') end
  end
  local sidecar_path = project.absolute(project.REGISTRY_BASENAME, root)
  local snapshots = {}
  for _, path in ipairs({config_path, sidecar_path, absolute_entry, project.parent(absolute_entry)..'/version.lua', root..'/.moonstone/env/env.toml', project.absolute(plugin.path,root)}) do
    local contents, read_error, read_code = project.read_file(path)
    if contents == nil and read_error and read_code ~= 2 then return failure('io_error', 'could not read planning input: ' .. path, {cause=read_error,path=path}) end
    snapshots[path] = {text=contents}
  end
  local config_doc, err = alter.open(config_path, {backend=backend, create=true, default_text='{}\n', fs=opts.fs})
  if not config_doc then return failure('invalid_config', 'cannot open LuaLS config', {cause=err}) end
  if config_doc:kind_at({}) ~= 'object' then return failure('invalid_config', 'LuaLS config must be an object') end
  local runtime_kind = config_doc:kind_at({'runtime'})
  if runtime_kind ~= 'none' and runtime_kind ~= 'object' then return failure('config_conflict', 'runtime must be an object') end
  local existing, conflict = setting(config_doc, 'plugin')
  if conflict then return failure('config_conflict', conflict) end
  existing = paths(existing)
  if not existing then return failure('config_conflict', 'runtime.plugin must be a string or string array') end
  local arguments
  arguments, conflict = setting(config_doc, 'pluginArgs')
  if conflict then return failure('config_conflict', conflict) end
  arguments = paths(arguments)
  if not arguments then return failure('config_conflict', 'runtime.pluginArgs must be a string array') end

  local direct, transport_count = {}, 0
  for _, path in ipairs(existing) do
    local absolute = project.absolute(path, root)
    local candidate = project.transport_identity_at(absolute)
    if absolute == absolute_entry or (candidate and candidate.PACKAGE == identity.PACKAGE) then
      transport_count = transport_count + 1
      if absolute ~= absolute_entry then return failure('config_conflict', 'LuaLS points to another Composer installation: ' .. path) end
    elseif path:match('luals_composer[/\\]init%.lua$') then
      return failure('unverified_transport', 'existing Composer path has unverified identity: ' .. path)
    else direct[#direct+1] = path end
  end
  if transport_count > 1 then return failure('config_conflict', 'multiple Composer entries are configured') end
  if transport_count == 1 and #direct > 0 then return failure('config_conflict', 'Composer and direct sibling plugins require explicit migration') end
  local selector, legacy_args = nil, {}
  for _, argument in ipairs(arguments) do
    local selected = argument:match('^%-%-config=(.*)$')
    if selected then
      if selector or selected ~= project.REGISTRY_BASENAME then return failure('config_conflict', 'conflicting sidecar selector') end
      selector = selected
    else legacy_args[#legacy_args+1] = argument end
  end
  if selector and (transport_count ~= 1 or #direct > 0 or #legacy_args > 0) then return failure('config_conflict', 'managed selector is mixed with direct plugins or arguments') end
  local warnings = {}
  if not selector and transport_count == 1 then
    if #direct > 0 and #legacy_args > 0 then return failure('ambiguous_migration', 'shared pluginArgs cannot be assigned to Composer and direct plugins') end
    for _, argument in ipairs(legacy_args) do
      local path = argument:match('^%-%-plugin=(.+)$') or argument
      if path:sub(1,2) == '--' then return failure('ambiguous_migration', 'unknown Composer argument: ' .. argument) end
      direct[#direct+1] = path
    end
    legacy_args = {}
  elseif #direct > 0 and #legacy_args > 0 then
    return failure('ambiguous_migration', 'direct plugin arguments require explicit migration into child descriptors')
  elseif #direct == 0 and #legacy_args > 0 then
    return failure('ambiguous_migration', 'pluginArgs has no owning plugin')
  end
  local sidecar_doc
  sidecar_doc, err = alter.open(sidecar_path, {backend=backend, create=true, default_text='{}\n', fs=opts.fs})
  if not sidecar_doc then return failure('invalid_registry', 'cannot open Composer registry', {cause=err}) end
  if sidecar_doc:kind_at({}) ~= 'object' then return failure('invalid_registry', 'registry must be an object') end
  local sidecar_exists = snapshots[sidecar_path].text ~= nil
  local plugins = {}
  if sidecar_exists then
    if sidecar_doc:value_at({'version'}) ~= 1 or sidecar_doc:value_at({'package'}) ~= identity.PACKAGE
      or sidecar_doc:kind_at({'plugins'}) ~= 'array' then return failure('invalid_registry', 'registry requires version=1, package identity and plugins array') end
    plugins = clone(sidecar_doc:value_at({'plugins'}))
    if not selector and (#direct > 0 or #arguments > 0) then return failure('ambiguous_migration', 'an existing sidecar and a legacy plugin list compete') end
  elseif selector then return failure('invalid_registry', 'selected registry does not exist') end
  local names, seen_paths = {}, {}
  for _, spec in ipairs(plugins) do
    local accepted, why = contract.validate(spec, installed.VERSION, true)
    if not accepted then return failure('invalid_registry', why) end
    spec.args = spec.args or {}
    local absolute = project.absolute(spec.path, root)
    if names[spec.name] or seen_paths[absolute] then return failure('duplicate_plugin', 'registry repeats a plugin name or path') end
    if absolute == absolute_entry then return failure('invalid_registry', 'Composer cannot be its own child') end
    names[spec.name], seen_paths[absolute] = true, spec.name
  end
  for i, path in ipairs(direct) do
    path = project.portable(path, root)
    local absolute = project.absolute(path, root)
    if seen_paths[absolute] then return failure('duplicate_plugin', 'legacy list repeats a plugin path') end
    local name = absolute == project.absolute(plugin.path, root) and plugin.name or ('legacy-' .. i)
    if names[name] then return failure('duplicate_plugin', 'legacy plugin name conflicts: ' .. name) end
    if not project.exists(absolute) then return failure('missing_plugin', 'legacy plugin file does not exist: ' .. path) end
    local spec = {name=name,path=path,transport='^'..installed.VERSION,contract=identity.CONTRACT,text_edits='legacy',args=clone(legacy_args)}
    plugins[#plugins+1] = spec
    names[name], seen_paths[absolute] = true, name
    warnings[#warnings+1] = 'Migrated ' .. path .. ' with the legacy edit contract; update its library to enroll explicitly.'
  end
  local replaced = false
  for i, spec in ipairs(plugins) do
    if spec.name == plugin.name then
      if project.absolute(spec.path, root) ~= project.absolute(plugin.path, root) then return failure('plugin_conflict', 'plugin name is already registered at another path') end
      plugins[i], replaced = plugin, true
    elseif project.absolute(spec.path, root) == project.absolute(plugin.path, root) then
      if spec.text_edits == 'legacy' then plugins[i], replaced = plugin, true
      else return failure('plugin_conflict', 'plugin path is already registered under another name') end
    end
  end
  if not replaced then
    if plugin.priority == 'first' then table.insert(plugins,1,plugin)
    else plugins[#plugins+1] = plugin end
  end
  plugin.priority = nil
  -- Preserve existing priority. New consumers append; explicit order changes
  -- belong in the reviewed sidecar rather than package-install timing.
  for _, name in ipairs({'plugin', 'pluginArgs'}) do
    if config_doc:kind_at({'runtime.'..name}) ~= 'none' then config_doc:at('runtime.'..name):remove() end
  end
  if runtime_kind == 'none' then config_doc:at('runtime'):ensure_object() end
  if not equal(config_doc:value_at({'runtime','plugin'}), {entry}) then config_doc:at('runtime','plugin'):set({entry}) end
  if not equal(config_doc:value_at({'runtime','pluginArgs'}), {'--config='..project.REGISTRY_BASENAME}) then config_doc:at('runtime','pluginArgs'):set({'--config='..project.REGISTRY_BASENAME}) end
  if sidecar_doc:value_at({'version'}) ~= 1 then sidecar_doc:at('version'):set(1) end
  if sidecar_doc:value_at({'package'}) ~= identity.PACKAGE then sidecar_doc:at('package'):set(identity.PACKAGE) end
  local plugins_changed = not equal(sidecar_doc:value_at({'plugins'}), plugins)
  if plugins_changed then sidecar_doc:at('plugins'):set(plugins) end
  for i, spec in ipairs(plugins) do
    if #spec.args == 0 and (plugins_changed or sidecar_doc:kind_at({'plugins',i,'args'}) ~= 'array') then
      sidecar_doc:at('plugins',i,'args'):remove():ensure_array()
    end
  end
  local config_text, config_result = config_doc:render()
  if not config_text then return failure('render_failed', 'could not render LuaLS config', {cause=config_result}) end
  local sidecar_text, sidecar_result = sidecar_doc:render()
  if not sidecar_text then return failure('render_failed', 'could not render registry', {cause=sidecar_result}) end
  local changes = {}
  if sidecar_result.changed then changes[#changes+1] = sidecar_path end
  if config_result.changed then changes[#changes+1] = config_path end
  return setmetatable({config_doc=config_doc,sidecar_doc=sidecar_doc,config_path=config_path,sidecar_path=sidecar_path,config=config_path,registry=sidecar_path,
    transport={package=installed.PACKAGE,version=installed.VERSION,contract=installed.CONTRACT,path=entry},plugin=clone(plugin),
    config_text=config_text,sidecar_text=sidecar_text,snapshots=snapshots,changes=changes,warnings=warnings,
    summary=#changes==0 and 'already enrolled' or 'enroll '..plugin.name,changed=#changes>0}, Plan)
end
return M
