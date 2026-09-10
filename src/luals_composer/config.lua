--[[
  luals-composer / config

  Works out WHICH child plugins to compose, and in what priority order.

  A --config= selector explicitly selects a managed registry and refuses
  competing plugin lists/environment overrides. Empty managed lists remain
  authoritative. The following precedence applies to legacy configurations
  without a selector.

  THREE LEGACY SOURCES, highest precedence first
  --------------------------------------------
  1. `LUALS_COMPOSER_PLUGINS` env var — `;`- or `,`-separated paths. An
     escape hatch for CI, tests, and one-off experiments; nothing has to be
     written to disk to use it.

  2. `Lua.runtime.pluginArgs` in `.luarc.json` — a REAL LuaLS mechanism, not an
     invention. `script/plugin.lua:108-122` reads it and `:157` passes it to
     the plugin chunk as its third vararg:

         local args = config.get(scp.uri, 'Lua.runtime.pluginArgs')
         ...
         xpcall(f, log.error, f, uri, myArgs)

     so inside a plugin `local _, uri, args = ...` yields the array. Entries
     may be bare paths or `--plugin=<path>`.

  3. `luals-composer.json` sitting next to `.luarc.json` — the richest form,
     and the one to prefer for a checked-in project, because it can name
     plugins and carry settings that do not fit in a flat string array.

  A source that yields at least one plugin wins outright; the transport does
  not merge across sources, because a half-overridden plugin list is far more
  confusing than a replaced one.

  PATH RESOLUTION
  ---------------
  Absolute paths are used as-is. `~` expands to `$HOME`. `${workspaceFolder}`
  expands to the workspace root. Relative paths resolve against the workspace
  root for sources 1 and 2, and against the config file's own directory for
  source 3 — which is what someone editing that file expects.
--]]

local json = require('luals_composer.json')
local contract = require('luals_composer.contract')
local identity = require('luals_composer.version')

local M = {}

M.CONFIG_BASENAME = 'luals-composer.json'
M.ENV_PLUGINS = 'LUALS_COMPOSER_PLUGINS'
M.ENV_CONFIG = 'LUALS_COMPOSER_CONFIG'

--------------------------------------------------------------------------
-- path helpers
--------------------------------------------------------------------------

---@param p string
---@return boolean
function M.is_absolute(p)
  return p:sub(1, 1) == '/' or p:match('^%a:[/\\]') ~= nil
end

---@param uri string?
---@return string? path
function M.uri_to_path(uri)
  if type(uri) ~= 'string' then return nil end
  local p = uri:gsub('^file://', '')
  if p == '' then return nil end
  p = p:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
  return p
end

---@param p string
---@return string
function M.dirname(p)
  return p:match('^(.*)[/\\][^/\\]*$') or '.'
end

--- Resolve one configured path against a base directory.
---@param p string
---@param base string?      directory relative paths resolve against
---@param workspace string? value substituted for ${workspaceFolder}
---@return string
function M.resolve_path(p, base, workspace)
  -- The parentheses matter: gsub returns (string, count), and passing that
  -- count straight through as gsub's `n` argument would cap replacements at 0.
  local folder = ((workspace or base or '.'):gsub('%%', '%%%%'))
  p = (p:gsub('%${workspaceFolder}', folder))
  local home = os.getenv('HOME')
  if home and p:sub(1, 2) == '~/' then
    p = home .. p:sub(2)
  end
  if M.is_absolute(p) then return p end
  return ((base or '.') .. '/' .. p):gsub('/%./', '/')
end

---@param path string
---@return string? contents
function M.read_file(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local s = fh:read('a')
  fh:close()
  return s
end

--------------------------------------------------------------------------
-- entry normalisation
--------------------------------------------------------------------------

--- Turn one configured entry into `{ path = ..., name = ... }`.
--- Accepts a bare string, a `--plugin=<path>` argument, or an object with
--- `path` (required), `name` and `enabled`.
---@param entry any
---@param base string?
---@param workspace string?
---@return table? plugin
---@return string? err
local function normalise_entry(entry, base, workspace)
  local path, name
  if type(entry) == 'string' then
    path = entry:match('^%-%-plugin=(.+)$') or entry
    if path:sub(1, 2) == '--' then
      return nil, nil -- an unrelated pluginArgs flag; silently ignore
    end
  elseif type(entry) == 'table' then
    if entry.enabled == false then return nil, nil end
    path = entry.path
    name = entry.name
    if type(path) ~= 'string' then
      return nil, 'plugin entry has no string `path`'
    end
  else
    return nil, ('plugin entry must be a string or object, got %s'):format(type(entry))
  end

  local resolved = M.resolve_path(path, base, workspace)
  return {
    path = resolved,
    name = name or resolved:match('([^/\\]+)$') or resolved,
    args = type(entry) == 'table' and entry.args or nil,
    contract = type(entry) == 'table' and entry.contract or nil,
    transport = type(entry) == 'table' and entry.transport or nil,
    text_edits = type(entry) == 'table' and entry.text_edits or nil,
  }, nil
end

---@param list table
---@param base string?
---@param workspace string?
---@return table plugins
---@return table errors
local function normalise_list(list, base, workspace)
  local plugins, errors = {}, {}
  for _, entry in ipairs(list) do
    local p, err = normalise_entry(entry, base, workspace)
    if p then
      plugins[#plugins + 1] = p
    elseif err then
      errors[#errors + 1] = err
    end
  end
  return plugins, errors
end

--------------------------------------------------------------------------
-- sources
--------------------------------------------------------------------------

---@param value string
---@return table
local function split_list(value)
  local out = {}
  -- Note: bind the trimmed value to a NEW local rather than reassigning the
  -- loop variable. lua-language-server's embedded Lua treats generic-for
  -- control variables as const and raises "attempt to assign to const
  -- variable" — which standalone PUC Lua 5.4 does not. This module runs inside
  -- that interpreter, so its rules are the ones that matter.
  for piece in value:gmatch('[^;,]+') do
    local trimmed = piece:match('^%s*(.-)%s*$')
    if trimmed ~= '' then out[#out + 1] = trimmed end
  end
  return out
end

--- Locate the sidecar config file.
---@param workspace string?
---@return string? path
function M.find_config_file(workspace)
  local explicit = os.getenv(M.ENV_CONFIG)
  if explicit and explicit ~= '' then return explicit end
  if not workspace then return nil end
  local candidate = workspace .. '/' .. M.CONFIG_BASENAME
  if M.read_file(candidate) then return candidate end
  return nil
end

--- Resolve the full transport configuration.
---
---@param opts table  { uri = <scope uri>, args = <pluginArgs array>, cwd = <fallback dir> }
---@return table config  { plugins = {...}, source = string, workspace = string?,
---                        errors = string[], settings = table }
function M.resolve(opts)
  opts = opts or {}
  local workspace = M.uri_to_path(opts.uri) or opts.cwd
  local config = {
    plugins = {},
    source = 'none',
    workspace = workspace,
    errors = {},
    settings = {},
  }

  -- A selector is authoritative, including an empty plugin list. Never let
  -- stale environment/pluginArgs data silently mask a managed sidecar.
  local selector, other_args
  other_args = {}
  for _, argument in ipairs(opts.args or {}) do
    if type(argument) ~= 'string' then
      config.errors[1] = 'pluginArgs must be strings'; return config
    end
    if argument == '--config' then config.errors[1] = '--config requires a value'; return config end
    local path = argument:match('^%-%-config=(.*)$')
    if path then
      if selector or path == '' then config.errors[1] = 'duplicate or empty --config selector'; return config end
      selector = path
    else other_args[#other_args + 1] = argument end
  end
  local env_config = os.getenv(M.ENV_CONFIG)
  local env_plugins = os.getenv(M.ENV_PLUGINS)
  if selector and (#other_args > 0 or (env_plugins and env_plugins ~= '')
    or (env_config and env_config ~= '' and M.resolve_path(env_config, workspace, workspace) ~= M.resolve_path(selector, workspace, workspace))) then
    config.errors[1] = '--config cannot mix with another plugin configuration source'; return config
  end
  local selected_file = selector or (env_config and env_config ~= '' and env_config)
  if selected_file then
    local path = M.resolve_path(selected_file, workspace, workspace)
    config.source = path
    local raw = M.read_file(path)
    if not raw then config.errors[1] = 'cannot read selected config ' .. path; return config end
    local data, err = json.decode(raw)
    if not data then config.errors[1] = 'invalid selected config: ' .. tostring(err); return config end
    if data.version ~= 1 or data.package ~= identity.PACKAGE or not contract.array(data.plugins) then
      config.errors[1] = 'selected config has unsupported identity/version or invalid plugins array'; return config
    end
    local names, paths = {}, {}
    for _, spec in ipairs(data.plugins) do
      local valid, validation_error = contract.validate(spec, nil, true)
      if not valid then config.errors[1] = validation_error; config.plugins = {}; return config end
      local resolved_path = M.resolve_path(spec.path, M.dirname(path), workspace)
      if names[spec.name] or paths[resolved_path] then config.errors[1] = 'duplicate plugin name/path'; config.plugins = {}; return config end
      names[spec.name], paths[resolved_path] = true, true
      if spec.enabled ~= false then config.plugins[#config.plugins + 1] = normalise_entry(spec, M.dirname(path), workspace) end
    end
    config.settings = type(data.settings) == 'table' and data.settings or {}
    return config
  end

  -- 1. environment
  local env = os.getenv(M.ENV_PLUGINS)
  if env and env ~= '' then
    local plugins, errs = normalise_list(split_list(env), workspace, workspace)
    if #plugins > 0 then
      config.plugins, config.source = plugins, M.ENV_PLUGINS
      for _, e in ipairs(errs) do config.errors[#config.errors + 1] = e end
      return config
    end
  end

  -- 2. Lua.runtime.pluginArgs
  if type(opts.args) == 'table' and #opts.args > 0 then
    local plugins, errs = normalise_list(opts.args, workspace, workspace)
    if #plugins > 0 then
      config.plugins, config.source = plugins, 'Lua.runtime.pluginArgs'
      for _, e in ipairs(errs) do config.errors[#config.errors + 1] = e end
      return config
    end
  end

  -- 3. luals-composer.json
  local file = M.find_config_file(workspace)
  if file then
    local raw = M.read_file(file)
    if not raw then
      config.errors[#config.errors + 1] = ('cannot read %s'):format(file)
      return config
    end
    local data, err = json.decode(raw)
    if not data then
      config.errors[#config.errors + 1] = ('%s is not valid JSON: %s'):format(file, err)
      return config
    end
    if type(data.plugins) ~= 'table' then
      config.errors[#config.errors + 1] = ('%s has no `plugins` array'):format(file)
      return config
    end
    local base = M.dirname(file)
    local plugins, errs = normalise_list(data.plugins, base, workspace or base)
    config.plugins, config.source = plugins, file
    config.settings = type(data.settings) == 'table' and data.settings or {}
    for _, e in ipairs(errs) do config.errors[#config.errors + 1] = e end
    return config
  end

  return config
end

return M
