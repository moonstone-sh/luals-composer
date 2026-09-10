--[[
  luals-composer / json

  A small, dependency-free JSONC (JSON + comments + trailing commas) decoder.

  WHY NOT `alter-jsonc`? This module runs inside lua-language-server's own Lua
  runtime, which is loaded by `load()` from a bare file path. None of the
  Moonstone runtime dependencies are on `package.path` there and there is no
  way to put them there portably. So the transport must parse its own config
  with zero dependencies.

  Comments and trailing commas are accepted because `.luarc.json` itself is
  read as JSONC by LuaLS, and a config file sitting next to it should not have
  stricter rules than its neighbour.

  Decode only. Nothing here writes JSON.
--]]

local M = {}

local escapes = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
  f = '\f', n = '\n', r = '\r', t = '\t',
}

---@param s string
---@param i integer
---@return integer
local function skip(s, i)
  while true do
    local c = s:sub(i, i)
    if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
      i = i + 1
    elseif c == '/' and s:sub(i + 1, i + 1) == '/' then
      local nl = s:find('\n', i, true)
      if not nl then return #s + 1 end
      i = nl + 1
    elseif c == '/' and s:sub(i + 1, i + 1) == '*' then
      local e = s:find('*/', i + 2, true)
      if not e then return #s + 1 end
      i = e + 2
    else
      return i
    end
  end
end

local parse_value

---@return string, integer
local function parse_string(s, i)
  i = i + 1 -- past the opening quote
  local buf = {}
  while true do
    local c = s:sub(i, i)
    if c == '' then error('unterminated string', 0) end
    if c == '"' then return table.concat(buf), i + 1 end
    if c == '\\' then
      local e = s:sub(i + 1, i + 1)
      if escapes[e] then
        buf[#buf + 1] = escapes[e]
        i = i + 2
      elseif e == 'u' then
        local hex = s:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16)
        if not cp then error('bad \\u escape', 0) end
        buf[#buf + 1] = utf8 and utf8.char(cp) or string.char(cp % 256)
        i = i + 6
      else
        error('bad escape \\' .. e, 0)
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
end

---@return table, integer
local function parse_array(s, i)
  local out = {}
  i = skip(s, i + 1)
  if s:sub(i, i) == ']' then return out, i + 1 end
  while true do
    local v
    v, i = parse_value(s, i)
    out[#out + 1] = v
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == ',' then
      i = skip(s, i + 1)
      if s:sub(i, i) == ']' then return out, i + 1 end -- trailing comma
    elseif c == ']' then
      return out, i + 1
    else
      error('expected , or ] at byte ' .. i, 0)
    end
  end
end

---@return table, integer
local function parse_object(s, i)
  local out = {}
  i = skip(s, i + 1)
  if s:sub(i, i) == '}' then return out, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then error('expected object key at byte ' .. i, 0) end
    local k
    k, i = parse_string(s, i)
    i = skip(s, i)
    if s:sub(i, i) ~= ':' then error('expected : at byte ' .. i, 0) end
    local v
    v, i = parse_value(s, skip(s, i + 1))
    out[k] = v
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == ',' then
      i = skip(s, i + 1)
      if s:sub(i, i) == '}' then return out, i + 1 end -- trailing comma
    elseif c == '}' then
      return out, i + 1
    else
      error('expected , or } at byte ' .. i, 0)
    end
  end
end

---@return any, integer
parse_value = function(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == '{' then return parse_object(s, i) end
  if c == '[' then return parse_array(s, i) end
  if c == '"' then return parse_string(s, i) end
  if s:sub(i, i + 3) == 'true' then return true, i + 4 end
  if s:sub(i, i + 4) == 'false' then return false, i + 5 end
  if s:sub(i, i + 3) == 'null' then return nil, i + 4 end
  local num = s:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', i)
  if num and num ~= '' then
    local v = tonumber(num)
    if v then return v, i + #num end
  end
  error('unexpected character ' .. (c == '' and '<eof>' or ('%q'):format(c)) .. ' at byte ' .. i, 0)
end

--- Decode a JSONC string.
---@param s string
---@return any? value    nil on failure
---@return string? err
function M.decode(s)
  local ok, v = pcall(function()
    local val, i = parse_value(s, 1)
    i = skip(s, i)
    if i <= #s then error('trailing content at byte ' .. i, 0) end
    return val
  end)
  if not ok then return nil, tostring(v) end
  return v, nil
end

return M
