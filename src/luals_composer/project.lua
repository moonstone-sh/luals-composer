--[[
  luals-composer / project

  Filesystem-shaped questions about a Moonstone project: where its root is,
  which Lua ABI directory its environment materialised into, and how to express
  a path so that it stays valid when the project moves.

  Deliberately free of `alter` and `clingy` so it can be tested with nothing but
  a scratch directory.
--]]

local version_mod = require('luals_composer.version')

local M = {}

M.CONFIG_BASENAME = '.luarc.json'
M.REGISTRY_BASENAME = 'luals-composer.json'
M.MANIFEST_BASENAME = 'moonstone.toml'

---@param path string
---@return string? contents
function M.read_file(path)
  local fh, err, code = io.open(path, 'rb')
  if not fh then return nil, err, code end
  local s, read_error, read_code = fh:read('a')
  local closed, close_error = fh:close()
  if not s then return nil, read_error, read_code end
  if not closed then return nil, close_error end
  return s
end

---@param path string
---@return boolean
function M.exists(path)
  local fh = io.open(path, 'rb')
  if not fh then return false end
  fh:close()
  return true
end

---@param path string
---@return string?
function M.parent(path)
  local p = path:match('^(.*)/[^/]+$')
  if p == '' then return '/' end
  return p
end

--- Walk upward looking for `moonstone.toml`.
--- Falls back to `start` so a non-Moonstone directory still works.
---@param start string
---@return string root
function M.find_root(start)
  local current = start
  while current and current ~= '' do
    if M.exists(current .. '/' .. M.MANIFEST_BASENAME) then return current end
    local up = M.parent(current)
    if up == current then break end
    current = up
  end
  return start
end

--- The Lua ABI directory Moonstone materialised, e.g. "5.4" or "5.1".
---
--- Read from `.moonstone/env/env.toml` the same way valua's own CLI does, so
--- both packages agree on where an installed plugin lives.
---@param root string
---@return string? luals_runtime  e.g. "Lua 5.4" / "LuaJIT"
---@return string? lua_dir_or_err e.g. "5.4"
function M.lua_runtime(root)
  local env = M.read_file(root .. '/.moonstone/env/env.toml')
  if not env then
    return nil, 'Moonstone environment not found; run `moon sync` first'
  end
  local runtime = env:match('%[runtime%](.-)\n%[') or env:match('%[runtime%](.*)$')
  if not runtime then return nil, 'Moonstone environment has no runtime table' end
  local name = runtime:match('name%s*=%s*"([^"]+)"')
  local version = runtime:match('version%s*=%s*"([^"]+)"')
  if name == 'luajit' then return 'LuaJIT', '5.1' end
  if name ~= 'lua' then return nil, 'unsupported Moonstone runtime: ' .. tostring(name) end
  local major, minor
  if version then major, minor = version:match('^(%d+)%.(%d+)') end
  if not major then return nil, 'could not determine the selected Lua version' end
  return 'Lua ' .. major .. '.' .. minor, major .. '.' .. minor
end

--- Root of the Lua module tree Moonstone materialised for this project.
---
--- Every installed package lands under here as `<tree>/<module>/...`, which is
--- what lets a package be located from nothing but its name — see
--- `manifest.lua`. `installed_transport_path` is just this with Composer's own
--- module path appended.
---@param root string
---@return string? relpath  relative to `root`, e.g. ".moonstone/env/share/lua/5.4"
---@return string? err
function M.installed_lua_tree(root)
  local runtime, lua_dir = M.lua_runtime(root)
  if not runtime then return nil, lua_dir end
  return ('.moonstone/env/share/lua/%s'):format(lua_dir)
end

--- Path of the transport's entry point inside this project's environment.
---@param root string
---@return string? relpath  relative to `root`
---@return string? err
function M.installed_transport_path(root)
  local tree, err = M.installed_lua_tree(root)
  if not tree then return nil, err end
  return ('%s/%s'):format(tree, version_mod.ENTRY_RELPATH)
end

--- Absolute path for a possibly-relative config path.
---@param path string
---@param root string
---@return string
function M.absolute(path, root)
  if path:sub(1, 1) == '/' or path:match('^%a:[/\\]') then return path end
  return root .. '/' .. path
end

--- Express `path` relative to `root` when it sits underneath it.
---
--- Config files travel with the repository, so a path inside the project should
--- be stored relative. A path outside it (a sibling checkout, say) has to stay
--- absolute or it would break.
---@param path string
---@param root string
---@return string
function M.portable(path, root)
  if path:sub(1, 1) ~= '/' then return path end
  local prefix = root .. '/'
  if path:sub(1, #prefix) == prefix then return path:sub(#prefix + 1) end
  return path
end

--- Read `version = "..."` out of a `moonstone.toml`'s `[package]` table.
---@param manifest_path string
---@return string? version
function M.manifest_version(manifest_path)
  local text = M.read_file(manifest_path)
  if not text then return nil end
  local pkg = text:match('%[package%](.-)\n%[') or text:match('%[package%](.*)$')
  if not pkg then return nil end
  return pkg:match('version%s*=%s*"([^"]+)"')
end

--- Read installed package identity as literal metadata without executing Lua.
---@param entry_path string  absolute path to luals_composer/init.lua
---@return table? identity
function M.transport_identity_at(entry_path)
  local dir = M.parent(entry_path)
  if not dir then return nil end

  local vfile = dir .. '/version.lua'
  local text = M.read_file(vfile)
  if not text then return nil end
  -- Read literal returned metadata, ignoring comment examples and never
  -- executing statements that happen to precede the table.
  text = text:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', '')
  text = text:match('return%s*{(.-)}')
  if not text then return nil end
  local package_name = text:match("%f[%w_]PACKAGE%s*=%s*['\"]([^'\"]+)['\"]")
  local version = text:match("%f[%w_]VERSION%s*=%s*['\"]([^'\"]+)['\"]")
  local contract = text:match('%f[%w_]CONTRACT%s*=%s*(%d+)')
  if not package_name or not version or not contract then return nil end
  return { PACKAGE = package_name, VERSION = version, CONTRACT = tonumber(contract) }
end

function M.transport_version_at(entry_path)
  local identity = M.transport_identity_at(entry_path)
  return identity and identity.VERSION
end

return M
