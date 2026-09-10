--[[
  luals-composer — compose several OnSetText-based lua-language-server plugins.

  THIS FILE IS THE PLUGIN ENTRY POINT. Point `.luarc.json` at it, and ONLY at
  it:

      {
        "runtime": {
          "plugin": "/abs/path/to/luals-composer/src/luals_composer/init.lua",
          "pluginArgs": ["--config=luals-composer.json"]
        }
      }

  The public `require('luals_composer').enroll()` API maintains this selector
  and the managed child registry. See README.md for migration rules.

  WHY THE INDIRECTION EXISTS
  --------------------------
  LuaLS's `plugin.dispatch` (`script/plugin.lua:24-52`) keeps only the LAST
  listed plugin's result for `OnSetText`, and aborts the event entirely if any
  listed plugin lacks the hook. Two plugins that each handle a different file
  type therefore cannot coexist: whichever is listed last wins, and it returns
  nil for the other's files. Listing one transport instead, and merging the
  children's diffs here, is the only fix available from outside the server.

  ORDER IS PRIORITY. List first the plugin that must win a genuine range
  conflict — for `.luax` workspaces that is `hydronium-luax`, which owns whole
  regions of the file.

  LOADING CONTRACT
  ----------------
  LuaLS loads this file with `load(src, '@'..path, 't', env)` and calls it as
  `chunk(chunk, uri, pluginArgs)` (`script/plugin.lua:148,157`), then reads the
  hooks off `env`. So the varargs below are LuaLS's, and the global assignments
  at the bottom are how the hooks become visible. The file is NOT `require`d,
  so it has to put its own `src/` on `package.path` before requiring anything.
--]]

local _chunk, scope_uri, plugin_args = ...

do
  local info = debug.getinfo(1, 'S')
  local self_path = info and info.source and info.source:gsub('^@', '') or ''
  local src_root = self_path:match('^(.*)/luals_composer/init%.lua$')
  if src_root and src_root ~= '' then
    for _, pattern in ipairs({ src_root .. '/?.lua', src_root .. '/?/init.lua' }) do
      if not package.path:find(pattern, 1, true) then
        package.path = pattern .. ';' .. package.path
      end
    end
  end
end

local config_mod = require('luals_composer.config')
local Transport  = require('luals_composer.transport')
local log        = require('luals_composer.log')

local resolved = config_mod.resolve({
  uri = scope_uri,
  args = plugin_args,
})

for _, err in ipairs(resolved.errors) do
  log.error(err)
end

local transport = Transport.new(resolved, scope_uri, plugin_args)
log.info(transport:describe())

if #transport.children == 0 then
  log.warn(
    'nothing to compose. Set Lua.runtime.pluginArgs in .luarc.json, add a ' ..
    config_mod.CONFIG_BASENAME .. ' beside it, or set ' .. config_mod.ENV_PLUGINS .. '.')
end

--------------------------------------------------------------------------
-- LuaLS plugin interface
--------------------------------------------------------------------------

--- @param uri string
--- @param text string
--- @return table? diffs
function OnSetText(uri, text)
  return transport:OnSetText(uri, text)
end

--- @param uri string
--- @param ast table
--- @return table ast
function OnTransformAst(uri, ast)
  return transport:OnTransformAst(uri, ast)
end

--- @param uri string
--- @param name string
--- @return string? resolved
function ResolveRequire(uri, name, suri)
  return transport:ResolveRequire(uri, name, suri)
end

-- Only exposed when a child actually implements it; see transport:build_vm.
VM = transport:build_vm()

return {
  transport = transport,
  config = resolved,
  OnSetText = OnSetText,
  OnTransformAst = OnTransformAst,
  ResolveRequire = ResolveRequire,
  VM = VM,
}
