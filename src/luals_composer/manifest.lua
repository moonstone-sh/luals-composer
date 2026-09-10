--[[
  luals-composer / manifest

  PLUGIN SELF-DESCRIPTION.

  Without this module, every consumer of `enroll()` has to hand-type the child
  plugin's whole descriptor — its exact file path inside `.moonstone/env`, the
  transport range it was verified against, its contract number and its edit
  mode. Only the plugin's own author actually knows those four things, and the
  consumer is the one forced to keep them correct.

  So a plugin package may instead ship ONE file that answers them, and
  enrollment looks it up by package name.

  LOCATION — fixed, so a bare name is enough to find it
  -----------------------------------------------------
  A package's manifest sits at the ROOT OF ITS INSTALLED LUA MODULE TREE:

      <root>/.moonstone/env/share/lua/<abi>/<module>/luals-plugin.lua

  `<module>` is derived from the requested name: a `scope/` prefix is dropped
  and `-` becomes `_`, which is the same transformation Moonstone already
  applies when it materialises a package into the Lua tree
  (`moonstone/hydronium-luax` -> `hydronium_luax`). Pass `module = "..."` in
  the request to override it.

  That location is a FIXED FUNCTION OF THE NAME, which is the whole point:
  `enroll{ plugin = "valua" }` can find it with no other input. Composer's own
  installed identity is located the same way
  (`project.installed_transport_path` -> `luals_composer/init.lua`); this is
  that mechanism generalised from one hard-coded package to any package.

  FORMAT — a Lua module returning a table
  ---------------------------------------
  Composer's other two files (`.luarc.json`, `luals-composer.json`) are JSON,
  so JSON was the obvious candidate and was rejected for two reasons.

  1. Different author. Those two files are written BY Composer and read by
     LuaLS. A manifest is written BY HAND, once, by a package author, and
     wants comments explaining why a plugin is `ranges` and not `insertions`.

  2. `args = {}` is ambiguous in JSON and is not ambiguous in Lua. A JSON
     decoder without a distinct array type — including this package's own
     `json.lua` — cannot tell `[]` from `{}`, and `contract.validate` rejects
     a non-array `args`. Enrollment already carries a workaround for exactly
     this when it WRITES the sidecar (`enrollment.lua`, the `ensure_array`
     pass). Re-importing that hazard on the read side, in a file whose entire
     job is to be unambiguous, would be a poor trade.

  Packaging is not a factor either way: `ballad`'s `conventions.tree` copies
  every file under the collected root, so a manifest of either format ships
  from all three of these repos with no partiture change.

  The returned table is exactly `contract.validate`'s descriptor shape:

      return {
        name       = "valua",
        path       = "tooling/luals/plugin.lua",  -- relative to THIS file
        transport  = "^0.1.0",
        contract   = 1,
        text_edits = "insertions",
        args       = {},
      }

  `path` is relative to the manifest's own directory — i.e. to the installed
  module root — because that is the only layout the manifest can speak about.
  A source repository whose on-disk layout differs from its installed layout
  (clingy: `luals/` is a sibling of `src/`, but installs INTO the module tree)
  must write the installed-relative path here.

  `priority` is deliberately NOT read from a manifest. Ordering is a property
  of the consuming workspace, not of a package, and a package must not be able
  to promote itself above its neighbours in someone else's registry.

  EVALUATION — data, in an empty environment
  ------------------------------------------
  The manifest is loaded as a text-only chunk with an EMPTY `_ENV`, so it can
  reach no global, no standard library and no I/O. It is configuration that
  happens to be spelled in Lua, and it is treated as such. This keeps the same
  "never let an installed tree run code just to be identified" stance as
  `project.transport_identity_at`, which scrapes literals rather than
  executing them.
--]]

local project = require('luals_composer.project')

local M = {}

--- Fixed filename, at the root of a package's installed Lua module tree.
M.BASENAME = 'luals-plugin.lua'

--- Lua module directory a Moonstone package name materialises into.
---@param name string  e.g. "moonstone/hydronium-luax" or "valua"
---@return string module e.g. "hydronium_luax" / "valua"
function M.module_dir(name)
  local bare = name:gsub('^[^/]+/', '')
  return (bare:gsub('%-', '_'))
end

--- Read one manifest file as inert data.
---@param path string absolute path
---@return table? descriptor
---@return string? err
function M.read(path)
  local text, read_error = project.read_file(path)
  if not text then return nil, read_error or ('cannot read ' .. path) end
  local chunk, load_error = load(text, '@' .. path, 't', {})
  if not chunk then return nil, 'manifest is not loadable Lua: ' .. tostring(load_error) end
  local ok, value = pcall(chunk)
  if not ok then return nil, 'manifest failed to evaluate: ' .. tostring(value) end
  if type(value) ~= 'table' then return nil, 'manifest must return a table' end
  return value
end

--- Where a named package's manifest would live, relative to the project root.
---@param root string
---@param name string
---@param module string?
---@return string? module_root  project-relative, e.g. ".moonstone/env/share/lua/5.4/valua"
---@return string? err_or_manifest_relpath
function M.location(root, name, module)
  local tree, err = project.installed_lua_tree(root)
  if not tree then return nil, err end
  local module_root = tree .. '/' .. (module or M.module_dir(name))
  return module_root, module_root .. '/' .. M.BASENAME
end

local ADVICE = "Either add %s to that package, or enroll it with an explicit descriptor: "
  .. "plugin = { name = %q, path = ..., transport = ..., contract = ..., text_edits = ... }."

--- Resolve a name-only plugin request into a full descriptor.
---
--- Returns a descriptor whose `path` is project-relative and whose remaining
--- fields are verbatim from the manifest. It performs NO contract validation:
--- the caller feeds the result through the same `contract.validate` an
--- explicitly typed descriptor goes through, so there is exactly one
--- validation route.
---
--- On failure the third return distinguishes "this package said nothing"
--- (`missing`, and falling back to an explicit descriptor is the fix) from
--- "this package said something wrong" (`invalid`, and the package is at
--- fault). Callers surface those as different error codes.
---@param root string
---@param request table  { name = string, module = string? }
---@return table? descriptor
---@return string? err
---@return string? kind  "missing" | "invalid"
function M.resolve(root, request)
  local name = request.name
  if type(name) ~= 'string' or name == '' then
    return nil, 'plugin lookup requires a package name', 'invalid'
  end
  local module_root, manifest_path = M.location(root, name, request.module)
  if not module_root then return nil, manifest_path, 'missing' end
  local absolute_root = project.absolute(module_root, root)
  local absolute_manifest = project.absolute(manifest_path, root)

  if not project.exists(absolute_manifest) then
    if not project.exists(absolute_root) then
      return nil, ("no installed package provides '%s': nothing is materialised at %s. "
        .. "Add it as a dependency and run `moon sync`, or enroll it with an explicit descriptor: "
        .. "plugin = { name = %q, path = ..., transport = ..., contract = ..., text_edits = ... }.")
        :format(name, module_root, name), 'missing'
    end
    return nil, ("'%s' is installed but ships no LuaLS self-description: expected %s. "):format(name, manifest_path)
      .. ADVICE:format(M.BASENAME, name), 'missing'
  end

  local data, err = M.read(absolute_manifest)
  if not data then return nil, ('%s: %s'):format(manifest_path, err), 'invalid' end
  if data.name ~= name then
    return nil, ('%s declares the plugin name %s, not %q'):format(manifest_path,
      type(data.name) == 'string' and ('%q'):format(data.name) or tostring(data.name), name), 'invalid'
  end
  if type(data.path) ~= 'string' or data.path == '' then
    return nil, ('%s declares no plugin `path`'):format(manifest_path), 'invalid'
  end
  if project.absolute(data.path, '.') ~= ('./' .. data.path) or data.path:find('%.%.') then
    return nil, ('%s must declare `path` relative to its own directory, without ".."'):format(manifest_path), 'invalid'
  end

  return {
    name = data.name,
    path = module_root .. '/' .. data.path,
    transport = data.transport,
    contract = data.contract,
    text_edits = data.text_edits,
    args = data.args,
  }
end

return M
