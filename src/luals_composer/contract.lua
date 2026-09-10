local version = require('luals_composer.version')
local semver = require('luals_composer.semver')
local M = {}

function M.array(value, strings)
  if type(value) ~= 'table' then return false end
  local count = 0
  for k, v in pairs(value) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or (strings and type(v) ~= 'string') then return false end
    count = count + 1
  end
  return count == #value
end

function M.validate(spec, installed_version, allow_legacy)
  if type(spec) ~= 'table' then return nil, 'plugin must be a descriptor object' end
  if type(spec.name) ~= 'string' or not spec.name:match('^[%w_.%-]+$') then return nil, 'plugin name must be a nonempty identifier' end
  if type(spec.path) ~= 'string' or spec.path == '' then return nil, 'plugin path must be nonempty' end
  if spec.contract ~= version.CONTRACT then return nil, 'unsupported plugin contract' end
  if spec.text_edits ~= 'insertions' and spec.text_edits ~= 'ranges'
    and not (allow_legacy and spec.text_edits == 'legacy') then return nil, 'text_edits must be insertions or ranges' end
  if type(spec.transport) ~= 'string' or spec.transport == '' then return nil, 'transport version constraint is required' end
  local matches, err = semver.satisfies(installed_version or version.VERSION, spec.transport)
  if not matches then return nil, err or 'installed Composer version does not satisfy ' .. spec.transport end
  if spec.args ~= nil and not M.array(spec.args, true) then return nil, 'plugin args must be a string array' end
  return true
end

function M.check_edits(result, text, mode)
  if result == nil or mode == nil or mode == 'legacy' then return true end
  if type(result) ~= 'table' then return nil, 'OnSetText must return nil or original-document diffs' end
  -- LuaLS plugins may attach diagnostic fields to their diff arrays.
  for k in pairs(result) do
    if type(k) == 'number' and (k < 1 or k % 1 ~= 0 or k > #result) then return nil, 'diff array is sparse' end
  end
  for _, h in ipairs(result) do
    if type(h) ~= 'table' or type(h.start) ~= 'number' or type(h.finish) ~= 'number'
      or h.start % 1 ~= 0 or h.finish % 1 ~= 0 or type(h.text) ~= 'string'
      or h.start < 1 or h.start > #text + 1 or h.finish < h.start - 1 or h.finish > #text then
      return nil, 'invalid original-document diff bounds'
    end
    if mode == 'insertions' and h.finish ~= h.start - 1 then return nil, 'insertion plugin returned a replacement' end
    if #text > 0 and h.start == 1 and h.finish == #text then return nil, 'whole-document replacements violate the transport contract' end
  end
  return true
end
return M
