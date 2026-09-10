-- Public enrollment API. Requiring this module never boots the LuaLS plugin.
local identity = require('luals_composer.version')
local M = { VERSION = identity.VERSION, PACKAGE = identity.PACKAGE, CONTRACT = identity.CONTRACT }
function M.plan(opts) return require('luals_composer.enrollment').plan(opts) end
function M.enroll(opts)
  local plan, err = M.plan(opts)
  if not plan then return nil, err end
  return plan:commit()
end
return M
