--[[
  luals-composer / transport

  The composition core: holds the loaded children and implements each LuaLS
  plugin hook by fanning out to all of them.

  Kept separate from `init.lua` so it can be constructed and driven from a
  plain Lua test with no language server anywhere in sight.

  THE PROBLEM BEING SOLVED (`script/plugin.lua:24-52`)
  ----------------------------------------------------
      for _, interface in ipairs(interfaces) do
          local method = interface[event]
          if type(method) ~= 'function' then
              return false                                  -- (A)
          end
          suc, res1, res2 = xpcall(method, log.error, uri, ...)   -- (B)
      end
      return failed == 0, res1, res2

  (A) One listed plugin without the hook aborts the event for EVERY plugin.
  (B) `res1` is overwritten each iteration, so only the LAST plugin's result
      survives — results are never merged.

  Neither is fixable from outside LuaLS. So `.luarc.json` lists exactly ONE
  plugin — this transport — and the transport does the fan-out itself, with the
  semantics `plugin.dispatch` should have had.

  Three failure modes are contained here rather than propagated:

    * a child that returns `nil` for a file it does not own contributes nothing
      and disturbs nobody — this is (A) fixed, and it is the exact bug that
      made `valua` + `hydronium-luax` mutually exclusive;
    * a child that throws is caught per-call and the rest still run;
    * a child that is slow is timed, so a pathological one is identifiable in
      the log rather than merely "the editor feels sluggish".
--]]

local merge  = require('luals_composer.merge')
local loader = require('luals_composer.loader')
local log    = require('luals_composer.log')
local contract = require('luals_composer.contract')

local M = {}
M.__index = M

--- Build a transport over an already-resolved configuration.
---@param config table  from luals_composer.config.resolve
---@param uri string?
---@param args table?
---@return table transport
function M.new(config, uri, args)
  local self = setmetatable({
    config = config,
    children = loader.load_all(config.plugins or {}, uri, args),
    -- Overlap warnings repeat on every keystroke, because OnSetText re-runs on
    -- every document change. Report each distinct conflict once per file so
    -- the log stays readable and the message is still not lost.
    reported = {},
  }, M)
  return self
end

--- Call one child hook with the crash and slowness guards.
---@param child table
---@param hook string
---@return boolean ok
---@return any result
function M:invoke(child, hook, ...)
  local fn = child.hooks[hook]
  if not fn then return false, nil end

  local started = os.clock()
  local ok, result = xpcall(fn, function(err)
    return tostring(err) .. '\n' .. debug.traceback('', 2)
  end, ...)
  local elapsed = os.clock() - started

  if not ok then
    log.error(('%s.%s errored; continuing without it: %s'):format(child.name, hook, result))
    return false, nil
  end
  if elapsed > 0.1 then
    log.warn(('%s.%s took %.3fs'):format(child.name, hook, elapsed))
  end
  return true, result
end

--------------------------------------------------------------------------
-- OnSetText
--------------------------------------------------------------------------

--- Fan out `OnSetText` and merge the results.
---
--- Every child is handed the SAME original, unmodified `text` — never the
--- output of the child before it. That is sound because `mergeDiff` treats
--- `start`/`finish` as offsets into the original document
--- (`string-merger.lua:69-72`), so independent diffs simply concatenate. It is
--- also the only option: a chained design would need each child to rebase the
--- previous child's offsets, which no plugin's API allows.
---
---@param uri string
---@param text string
---@return table? diffs
function M:OnSetText(uri, text)
  if type(text) ~= 'string' then return nil end

  local contributions = {}
  for _, child in ipairs(self.children) do
    if child.hooks.OnSetText then
      local ok, result = self:invoke(child, 'OnSetText', uri, text)
      if ok then
        local valid, err = contract.check_edits(result, text, child.text_edits)
        if not valid then
          local key = tostring(uri) .. '\0' .. child.name .. '\0' .. err
          if not self.reported[key] then
            self.reported[key] = true
            log.error(child.name .. ': ' .. err .. '; contribution dropped')
          end
          ok = false
        end
      end
      contributions[#contributions + 1] = {
        name = child.name,
        result = ok and result or nil,
      }
    end
  end

  local diffs, report = merge.merge(contributions, text)

  for _, warning in ipairs(report.warnings) do
    local key = uri .. '\0' .. warning
    if not self.reported[key] then
      self.reported[key] = true
      log.warn(('%s: %s'):format(uri, warning))
    end
  end

  return diffs
end

--------------------------------------------------------------------------
-- OnTransformAst
--------------------------------------------------------------------------

--- Chain the AST through every child that wants it.
---
--- Unlike text diffs, AST rewrites genuinely are sequential: each child should
--- see the tree as the previous one left it. A child returning nil is read as
--- "no change", not as "discard the tree".
---@param uri string
---@param ast table
---@return table ast
function M:OnTransformAst(uri, ast)
  for _, child in ipairs(self.children) do
    if child.hooks.OnTransformAst then
      local ok, result = self:invoke(child, 'OnTransformAst', uri, ast)
      if ok and result ~= nil then ast = result end
    end
  end
  return ast
end

--------------------------------------------------------------------------
-- ResolveRequire
--------------------------------------------------------------------------

--- First child with an answer wins; ties go to configuration order.
--- There is nothing to merge here — a `require` resolves to one file.
---@param uri string
---@param name string
---@return string? resolved
function M:ResolveRequire(uri, name, suri)
  for _, child in ipairs(self.children) do
    if child.hooks.ResolveRequire then
      local ok, result = self:invoke(child, 'ResolveRequire', uri, name, suri)
      if ok and result then return result end
    end
  end
  return nil
end

--------------------------------------------------------------------------
-- VM.OnCompileFunctionParam
--------------------------------------------------------------------------

--- Build the `VM` table, or nil when no child supplies the hook.
---
--- This hook already composes on its own — `script/vm/compiler.lua:1531-1546`
--- iterates all interfaces itself rather than going through `plugin.dispatch`.
--- It is forwarded anyway so that a project which lists ONLY the transport
--- keeps whatever its children provide.
---
--- Crucially the table is omitted entirely when nothing implements the hook.
--- LuaLS calls `interface.VM.OnCompileFunctionParam(...)` unguarded, so
--- exposing a `VM` table without a working function would crash parameter
--- compilation for every plugin in the workspace.
---@return table? vm
function M:build_vm()
  local providers = {}
  for _, child in ipairs(self.children) do
    if child.vm then
      providers[#providers + 1] = { name = child.name, fn = child.vm.OnCompileFunctionParam }
    end
  end
  if #providers == 0 then return nil end

  return {
    OnCompileFunctionParam = function(next_, func, param)
      for _, p in ipairs(providers) do
        local ok, claimed = pcall(p.fn, next_, func, param)
        if not ok then
          log.error(('%s.VM.OnCompileFunctionParam errored; continuing: %s'):format(p.name, claimed))
        elseif claimed then
          return true
        end
      end
      return false
    end,
  }
end

--- One-line summary of what got composed, for the log and for tests.
---@return string
function M:describe()
  if #self.children == 0 then
    return ('no child plugins configured (source: %s)'):format(self.config.source or 'none')
  end
  local names = {}
  for i, c in ipairs(self.children) do
    names[#names + 1] = ('%d:%s'):format(i, c.name)
  end
  return ('composing %d plugin(s) from %s -> %s'):format(
    #self.children, self.config.source or 'none', table.concat(names, ' '))
end

return M
