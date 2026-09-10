--[[
  Drive REAL enrollment against a REAL workspace, for tests/e2e/verify_named.sh.

    usage: moon exec lua -- tests/e2e/enroll_named.lua <workspace> named|typed
           moon exec lua -- tests/e2e/enroll_named.lua <ws-named> both <ws-typed>

  `named` passes nothing but each package's name and lets the package's own
  luals-plugin.lua supply the rest. `typed` hand-types the identical descriptor
  the way every consumer had to before self-description existed. Both write
  through the same public API; the point of the pair is that the files they
  produce are compared by the calling script.

  `both` does the two runs IN ONE PROCESS, which is what makes a byte-for-byte
  comparison meaningful. Composer serialises a descriptor in Lua `pairs` order,
  and Lua 5.4 randomises its string hash seed per process, so the ORDER OF KEYS
  inside each descriptor object differs between any two runs — including two
  hand-typed runs. That is a pre-existing property of enrollment, not of name
  resolution, and it is invisible to every JSON reader. Sharing one process
  fixes the seed and isolates the thing actually under test.
--]]

package.path = 'src/?.lua;src/?/init.lua;' .. package.path

local api = require('luals_composer')

local workspace, mode, other = ...
assert(type(workspace) == 'string' and workspace ~= '', 'workspace path is required')
assert(mode == 'named' or mode == 'typed' or mode == 'both', 'mode must be named, typed or both')

local TREE = '.moonstone/env/share/lua/5.1/'

-- Enrollment order is the priority order the registry ends up in.
-- hydronium-luax goes first: it owns whole regions of a .luax file and must
-- win any genuine range conflict.
local requests = {
  {
    named = { name = 'hydronium-luax', priority = 'first' },
    typed = { name = 'hydronium-luax', path = TREE .. 'hydronium_luax/luals/init.lua',
      transport = '^0.1.0', contract = 1, text_edits = 'ranges', args = {}, priority = 'first' },
  },
  {
    named = 'valua',
    typed = { name = 'valua', path = TREE .. 'valua/tooling/luals/plugin.lua',
      transport = '^0.1.0', contract = 1, text_edits = 'insertions', args = {} },
  },
  {
    named = 'clingy',
    typed = { name = 'clingy', path = TREE .. 'clingy/luals/plugin.lua',
      transport = '^0.1.0', contract = 1, text_edits = 'insertions', args = {} },
  },
}

local function run(root, which)
  for _, request in ipairs(requests) do
    local plugin = request[which]
    local label = type(plugin) == 'string' and ('"' .. plugin .. '"') or ('{ name = "' .. plugin.name .. '", ... }')
    local result, err = api.enroll({ root = root, plugin = plugin })
    if not result then
      io.stderr:write(('FAILED enroll %s: [%s] %s\n'):format(label, err.code, err.message))
      os.exit(1)
    end
    print(('  enrolled %-40s -> %s  changed=%s'):format(label, result.plugin.path, tostring(result.changed)))
    for _, warning in ipairs(result.warnings) do print('    warning: ' .. warning) end
  end
end

if mode == 'both' then
  assert(type(other) == 'string' and other ~= '', 'both mode needs a second workspace')
  print('-- by name, in ' .. workspace)
  run(workspace, 'named')
  print('-- hand-typed, in ' .. other)
  run(other, 'typed')
else
  run(workspace, mode)
end
