--[[
  luals-composer / loader

  Loads child plugins the same way lua-language-server itself does, so a plugin
  that works when listed directly in `.luarc.json` also works when composed.

  WHAT LuaLS DOES (`script/plugin.lua:130-162`)
  ---------------------------------------------
    * appends the plugin file's own directory as `<dir>/?.lua` to
      `package.path`, so the plugin can `require` its siblings;
    * builds a fresh environment `setmetatable({}, { __index = _ENV })`, so the
      chunk sees every global but its own assignments stay local to it;
    * `load(source, '@' .. path, 't', env)`;
    * calls the chunk as `f(f, uri, args)` — note the chunk itself is the first
      vararg, which is why real plugins start `local _, uri, args = ...`;
    * treats the ENVIRONMENT TABLE, not the return value, as the plugin
      interface. `OnSetText = function() end` at the top level of the file is
      the canonical way to expose a hook.

  This module reproduces all of that. It additionally accepts hooks from the
  chunk's RETURN value when the environment has none, because
  `hydronium-luax`'s entry file both assigns the globals and returns a module
  table, and a composed loader that only looked at one of the two would be
  fragile for no reason.

  ISOLATION
  ---------
  Each child gets its own environment table, so two children defining the same
  global never see each other's. They do share `package.loaded`, exactly as
  they would under LuaLS — the sandbox has never isolated `require`.
--]]

local log = require('luals_composer.log')
local contract = require('luals_composer.contract')

local M = {}

M.HOOKS = { 'OnSetText', 'OnTransformAst', 'ResolveRequire' }

--- Add a child's directory to `package.path` the way LuaLS does.
---@param path string
local function extend_package_path(path)
  local dir = path:match('^(.*)[/\\][^/\\]*$')
  if not dir then return end
  for _, pattern in ipairs({ dir .. '/?.lua', dir .. '/?/init.lua' }) do
    if not package.path:find(pattern, 1, true) then
      package.path = package.path .. ';' .. pattern
    end
  end
end

--- Load one child plugin.
---@param spec table   { path = string, name = string }
---@param uri string?  scope uri, forwarded to the chunk as LuaLS would
---@param args table?  plugin args, forwarded to the chunk as LuaLS would
---@return table? child   { name, path, hooks = { ... }, vm = table? }
---@return string? err
function M.load_child(spec, uri, args)
  if spec.contract ~= nil then
    local valid, validation_error = contract.validate(spec, nil, true)
    if not valid then return nil, ('%s: %s'):format(spec.name or '?', validation_error) end
  end
  local source = (function()
    local fh = io.open(spec.path, 'rb')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
  end)()

  if not source then
    return nil, ('plugin file not found: %s'):format(spec.path)
  end

  extend_package_path(spec.path)

  local env = setmetatable({}, { __index = _ENV })
  local chunk, err = load(source, '@' .. spec.path, 't', env)
  if not chunk then
    return nil, ('%s failed to compile: %s'):format(spec.name, err)
  end

  local ok, ret = xpcall(chunk, function(e)
    return tostring(e) .. '\n' .. debug.traceback('', 2)
  end, chunk, uri, spec.args or {})
  if not ok then
    return nil, ('%s errored while loading: %s'):format(spec.name, ret)
  end

  local hooks = {}
  for _, name in ipairs(M.HOOKS) do
    local fn = rawget(env, name)
    if type(fn) ~= 'function' and type(ret) == 'table' and type(ret[name]) == 'function' then
      fn = ret[name]
    end
    if type(fn) == 'function' then hooks[name] = fn end
  end

  local vm = rawget(env, 'VM')
  if type(vm) ~= 'table' and type(ret) == 'table' and type(ret.VM) == 'table' then
    vm = ret.VM
  end

  return {
    name = spec.name,
    path = spec.path,
    text_edits = spec.text_edits,
    hooks = hooks,
    -- Guard the VM table hard. `script/vm/compiler.lua:1537` calls
    -- `interface.VM.OnCompileFunctionParam(...)` with NO type check and NO
    -- xpcall, so a child shipping `VM = {}` without the hook would throw and
    -- take down parameter compilation for every plugin. Only accept a VM table
    -- that actually carries the function.
    vm = (type(vm) == 'table' and type(vm.OnCompileFunctionParam) == 'function') and vm or nil,
  }, nil
end

--- Load every configured child, skipping the ones that fail.
---@param specs table   array of { path, name }, in priority order
---@param uri string?
---@param args table?
---@return table children
function M.load_all(specs, uri, args)
  local children = {}
  for _, spec in ipairs(specs) do
    local child, err = M.load_child(spec, uri, args)
    if child then
      local names = {}
      for _, h in ipairs(M.HOOKS) do
        if child.hooks[h] then names[#names + 1] = h end
      end
      if child.vm then names[#names + 1] = 'VM.OnCompileFunctionParam' end
      children[#children + 1] = child
      log.info(('loaded %s (%s) hooks=[%s]'):format(
        child.name, child.path,
        #names > 0 and table.concat(names, ', ') or 'none'))
      if #names == 0 then
        log.warn(('%s exposes no known plugin hooks; it will contribute nothing'):format(child.name))
      end
    else
      -- A child that cannot load must never stop the others. This is the whole
      -- point of the transport.
      log.error(err)
    end
  end
  return children
end

return M
