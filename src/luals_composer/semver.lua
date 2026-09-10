--[[
  luals-composer / semver

  Version comparison and constraint matching, dependency-free and pure.

  WHY IN-TREE? `enroll` has to answer "does the installed transport satisfy the
  version this plugin pinned?" before it can decide whether to install, update,
  or refuse. Moonstone resolves constraints for *packages*, but this question is
  about what is already written into a project's `.luarc.json` /
  `luals-composer.json`, which Moonstone does not read. So the check lives
  here, and it is deliberately a small, testable, side-effect-free module.

  SUPPORTED CONSTRAINT SYNTAX
    *  /  any        anything
    1.2.3  / =1.2.3  exact
    >1.2.3  >=1.2.3  <1.2.3  <=1.2.3
    ^1.2.3           >=1.2.3 <2.0.0    (caret: no breaking change)
    ^0.1.2           >=0.1.2 <0.2.0    (0.x: minor is the breaking axis)
    ^0.0.3           >=0.0.3 <0.0.4    (0.0.x: every patch may break)
    ~1.2.3           >=1.2.3 <1.3.0
    ">=1.0.0 <2.0.0" conjunction, space- or comma-separated

  Prereleases compare below their release (`1.0.0-rc.1` < `1.0.0`), matching
  semver. Prerelease identifiers compare numerically when both are numeric,
  otherwise lexically.
--]]

local M = {}

--- Parse a version string into its parts.
---@param s string
---@return table? parsed  { major, minor, patch, prerelease = string? }
function M.parse(s)
  if type(s) ~= 'string' then return nil end
  local body = s
  local major, minor, patch, rest = body:match('^(%d+)%.(%d+)%.(%d+)(.*)$')
  if not major then return nil end
  for _, n in ipairs({ major, minor, patch }) do
    if #n > 1 and n:sub(1, 1) == '0' then return nil end
    if tonumber(n) > 9007199254740991 then return nil end
  end
  local prerelease
  if rest and rest ~= '' then
    local suffix, build = rest:match('^(.-)%+([%w%.%-]+)$')
    if suffix then rest = suffix end
    if rest ~= '' then
      prerelease = rest:match('^%-([%w%.%-]+)$')
      if not prerelease then return nil end
    elseif not build then return nil end
    for _, list in ipairs({ prerelease or '', build or '' }) do
      if list ~= '' and (list:sub(1, 1) == '.' or list:sub(-1) == '.' or list:find('..', 1, true)) then return nil end
    end
    if prerelease then
      for id in prerelease:gmatch('[^.]+') do
        if id:match('^%d+$') and #id > 1 and id:sub(1, 1) == '0' then return nil end
      end
    end
  end
  return {
    major = tonumber(major),
    minor = tonumber(minor),
    patch = tonumber(patch),
    prerelease = prerelease,
  }
end

---@param a string
---@param b string
---@return integer? -1|0|1
local function compare_prerelease(a, b)
  -- Absent prerelease outranks present: 1.0.0 > 1.0.0-rc.1
  if a == nil and b == nil then return 0 end
  if a == nil then return 1 end
  if b == nil then return -1 end

  local function split(s)
    local out = {}
    for piece in s:gmatch('[^%.]+') do out[#out + 1] = piece end
    return out
  end
  local ap, bp = split(a), split(b)
  for i = 1, math.max(#ap, #bp) do
    local x, y = ap[i], bp[i]
    if x == nil then return -1 end
    if y == nil then return 1 end
    local nx, ny = tonumber(x), tonumber(y)
    if nx and ny then
      if nx ~= ny then return nx < ny and -1 or 1 end
    elseif nx then
      return -1 -- numeric identifiers rank below alphanumeric
    elseif ny then
      return 1
    elseif x ~= y then
      return x < y and -1 or 1
    end
  end
  return 0
end

--- Compare two version strings.
---@param a string
---@param b string
---@return integer? -1 when a<b, 0 when equal, 1 when a>b; nil if unparseable
function M.compare(a, b)
  local pa, pb = M.parse(a), M.parse(b)
  if not pa or not pb then return nil end
  for _, k in ipairs({ 'major', 'minor', 'patch' }) do
    if pa[k] ~= pb[k] then return pa[k] < pb[k] and -1 or 1 end
  end
  return compare_prerelease(pa.prerelease, pb.prerelease)
end

--- Upper bound (exclusive) implied by a caret constraint.
---@param p table parsed version
---@return table
local function caret_bound(p)
  if p.major > 0 then return { major = p.major + 1, minor = 0, patch = 0 } end
  if p.minor > 0 then return { major = 0, minor = p.minor + 1, patch = 0 } end
  return { major = 0, minor = 0, patch = p.patch + 1 }
end

---@param p table
---@return string
local function tostr(p)
  return ('%d.%d.%d'):format(p.major, p.minor, p.patch)
end

--- Evaluate one atomic comparator against a version.
---@param version string
---@param atom string
---@return boolean? ok
---@return string? err
local function match_atom(version, atom)
  if atom == '*' or atom == 'any' or atom == '' then return true end

  local op, rest = atom:match('^([<>=~^]+)%s*(.+)$')
  if not op then op, rest = '=', atom end

  local target = M.parse(rest)
  if not target then return nil, ('unparseable version %q in constraint'):format(rest) end

  -- `version` is validated by M.satisfies before we get here, so every
  -- M.compare below is guaranteed non-nil. A prerelease of the target release
  -- sorts below it inside M.compare, so no operator needs special casing.
  if op == '=' or op == '==' then
    return M.compare(version, rest) == 0
  elseif op == '>' then
    return M.compare(version, rest) > 0
  elseif op == '>=' then
    return M.compare(version, rest) >= 0
  elseif op == '<' then
    return M.compare(version, rest) < 0
  elseif op == '<=' then
    return M.compare(version, rest) <= 0
  elseif op == '^' then
    local upper = caret_bound(target)
    return M.compare(version, rest) >= 0 and M.compare(version, tostr(upper)) < 0
  elseif op == '~' then
    local upper = { major = target.major, minor = target.minor + 1, patch = 0 }
    return M.compare(version, rest) >= 0 and M.compare(version, tostr(upper)) < 0
  end
  return nil, ('unknown operator %q in constraint'):format(op)
end

--- Does `version` satisfy `constraint`?
---
--- A constraint is a conjunction of atoms separated by spaces or commas, so
--- `">=1.0.0 <2.0.0"` and `">=1.0.0, <2.0.0"` are equivalent.
---
---@param version string
---@param constraint string?  nil or "*" means "anything"
---@return boolean? ok    nil on a malformed input
---@return string? err
function M.satisfies(version, constraint)
  if type(version) ~= 'string' then return nil, 'version must be a string' end
  if not M.parse(version) then return nil, ('unparseable version %q'):format(version) end
  if constraint == nil or constraint == '' then return true end
  if type(constraint) ~= 'string' then return nil, 'constraint must be a string' end

  local seen, matches = false, true
  for atom in constraint:gmatch('[^,%s]+') do
    seen = true
    local ok, err = match_atom(version, atom)
    if ok == nil then return nil, err end
    if not ok then matches = false end
  end
  if not seen then return true end
  return matches
end

return M
