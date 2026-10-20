local M = {}
function M.mkdir(path)
  local command
  if package.config:sub(1,1) == "\\" then
    assert(not path:find('[&|<>()^"!%%\r\n]'), 'unsafe test directory')
    path = path:gsub('/', '\\')
    command = 'if not exist "' .. path .. '\\NUL" mkdir "' .. path .. '"'
  else command = "mkdir -p '" .. path:gsub("'", "'\\''") .. "'" end
  local ok = os.execute(command)
  assert(ok == true or ok == 0, 'cannot create test directory: ' .. path)
  return true
end
return M
