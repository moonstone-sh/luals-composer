--[[
  luals-composer / log

  Diagnostics have to actually reach a human, and inside LuaLS there are three
  possible places for that:

    * `log.info` / `log.warn` — LuaLS's own logger, a global inside the server
      process. Writes to the server log file, which is what a user is told to
      attach to a bug report. Absent when the module is loaded outside LuaLS
      (in tests), hence the guards.
    * stderr — visible when the server is driven from a terminal or a test
      harness, and captured by most editors' LSP output panes.
    * a ring buffer — kept so `luals-composer`'s own state can be inspected
      from a test without scraping text streams.

  Everything is prefixed `[luals-composer]` so it is greppable in a log file
  that is otherwise entirely LuaLS's.
--]]

local M = {}

M.PREFIX = '[luals-composer] '
M.records = {}
M.to_stderr = true

---@param level string
---@param msg string
local function emit(level, msg)
  local line = M.PREFIX .. msg
  M.records[#M.records + 1] = { level = level, message = msg }

  local ls = rawget(_G, 'log')
  if type(ls) == 'table' then
    local fn = ls[level] or ls.info
    if type(fn) == 'function' then pcall(fn, line) end
  end

  if M.to_stderr then
    pcall(function() io.stderr:write(line .. '\n') end)
  end
end

---@param ... any
local function join(...)
  local parts = {}
  for i = 1, select('#', ...) do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  return table.concat(parts, ' ')
end

function M.info(...) emit('info', join(...)) end
function M.warn(...) emit('warn', join(...)) end
function M.error(...) emit('error', join(...)) end

--- Drop every buffered record. For tests.
function M.reset() M.records = {} end

return M
