--[[
  The real error path for name-based enrollment.

    usage: moon exec lua -- tests/e2e/enroll_errors.lua <workspace>

  Every case here must fail with a structured error whose message tells the
  caller what to do next, and must leave the workspace untouched.
--]]

package.path = 'src/?.lua;src/?/init.lua;' .. package.path

local api = require('luals_composer')

local workspace = ...
assert(type(workspace) == 'string' and workspace ~= '', 'workspace path is required')

local function attempt(label, plugin)
  print('\n--- ' .. label .. ' ---')
  local result, err = api.enroll({ root = workspace, plugin = plugin })
  if result then
    io.stderr:write('UNEXPECTED SUCCESS: ' .. label .. '\n')
    os.exit(1)
  end
  print('  code    = ' .. tostring(err.code))
  print('  plugin  = ' .. tostring(err.plugin))
  for line in tostring(err.message):gmatch('[^\n]+') do print('  message = ' .. line) end
end

attempt('a package that is installed but ships no luals-plugin.lua', 'undescribed')
attempt('a package that is not installed at all', 'never-heard-of-it')
attempt('a manifest that claims a different package name', 'impostor')
attempt('a manifest whose text_edits is not a real edit mode', 'badmode')

print('\n--- the fallback the error message recommends must actually work ---')
local result, err = api.enroll({
  root = workspace,
  plugin = { name = 'undescribed',
    path = '.moonstone/env/share/lua/5.1/undescribed/luals/plugin.lua',
    transport = '^0.2.0', contract = 1, text_edits = 'insertions', args = {} },
})
if not result then
  io.stderr:write(('explicit fallback FAILED: [%s] %s\n'):format(err.code, err.message))
  os.exit(1)
end
print('  explicit descriptor enrolled ' .. result.plugin.name .. ' -> ' .. result.plugin.path)
