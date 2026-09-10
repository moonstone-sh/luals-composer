-- luals-composer test runner.
-- Same shape as the other Moonstone packages' runners (valua, clingy):
-- describe/it globals, plain asserts, non-zero exit on failure.

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local passed = 0
local failed = 0
local errors = {}
local current_suite = ""

function describe(name, fn)
  current_suite = name
  print("\n--- " .. name .. " ---")
  fn()
end

function it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  \27[32m✓\27[0m " .. name)
  else
    failed = failed + 1
    print("  \27[31m✗\27[0m " .. name)
    table.insert(errors, "[" .. current_suite .. "] " .. name .. ":\n    " .. tostring(err))
  end
end

local function render(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for _, h in ipairs(v) do
    if type(h) == "table" and h.start then
      parts[#parts + 1] = ("{%d,%d,%q}"):format(h.start, h.finish, h.text)
    else
      parts[#parts + 1] = tostring(h)
    end
  end
  return "[" .. table.concat(parts, " ") .. "]"
end

function assert_equal(actual, expected, msg)
  if actual ~= expected then
    error((msg or "Assertion failed") .. ": expected " .. render(expected)
      .. ", got " .. render(actual), 2)
  end
end

function assert_true(cond, msg)
  if not cond then error(msg or "Expected true, got false/nil", 2) end
end

function assert_false(cond, msg)
  if cond then error(msg or "Expected false, got true", 2) end
end

function assert_nil(v, msg)
  if v ~= nil then error((msg or "Expected nil") .. ", got " .. render(v), 2) end
end

function assert_not_nil(v, msg)
  if v == nil then error(msg or "Expected non-nil, got nil", 2) end
end

function assert_match(actual, pattern, msg)
  if type(actual) ~= "string" or not actual:match(pattern) then
    error((msg or "Expected value to match pattern") .. ": " .. tostring(pattern)
      .. "; got " .. render(actual), 2)
  end
end

function assert_throws(fn, needle, msg)
  local ok, err = pcall(fn)
  if ok then error(msg or "Expected function to throw", 2) end
  if needle and not tostring(err):find(needle, 1, true) then
    error((msg or "Thrown error did not contain expected text") .. ": "
      .. tostring(needle) .. "; got " .. tostring(err), 2)
  end
  return err
end

local function equal_tables(actual, expected, seen)
  if actual == expected then return true end
  if type(actual) ~= type(expected) or type(actual) ~= "table" then return false end
  seen = seen or {}
  if seen[actual] == expected then return true end
  seen[actual] = expected
  for key, value in pairs(expected) do
    if not equal_tables(actual[key], value, seen) then return false end
  end
  for key in pairs(actual) do
    if expected[key] == nil then return false end
  end
  return true
end

function assert_same(actual, expected, msg)
  if not equal_tables(actual, expected) then
    error((msg or "Tables differ") .. ": expected " .. render(expected)
      .. ", got " .. render(actual), 2)
  end
end

--- Assert a diff list matches, element by element, with a readable failure.
function assert_diffs(actual, expected, msg)
  assert_not_nil(actual, (msg or "diffs") .. " should not be nil")
  if #actual ~= #expected then
    error((msg or "diffs") .. ": expected " .. #expected .. " hunk(s) "
      .. render(expected) .. ", got " .. #actual .. " " .. render(actual), 2)
  end
  for i = 1, #expected do
    local a, e = actual[i], expected[i]
    if a.start ~= e.start or a.finish ~= e.finish or a.text ~= e.text then
      error((msg or "diffs") .. " hunk " .. i .. ": expected "
        .. ("{%d,%d,%q}"):format(e.start, e.finish, e.text) .. ", got "
        .. ("{%d,%d,%q}"):format(a.start, a.finish, a.text), 2)
    end
  end
end

--- Assert at least one warning contains `needle`.
function assert_warned(report, needle, msg)
  for _, w in ipairs(report.warnings) do
    if w:find(needle, 1, true) then return end
  end
  error((msg or "expected a warning containing") .. " " .. ("%q"):format(needle)
    .. "; got: " .. table.concat(report.warnings, " | "), 2)
end

local specs = {
  "tests.facade_spec",
  "tests.version_spec",
  "tests.semver_spec",
  "tests.project_spec",
  "tests.contract_spec",
  "tests.merge_spec",
  "tests.json_spec",
  "tests.config_spec",
  "tests.loader_spec",
  "tests.transport_spec",
  "tests.manifest_spec",
  "tests.enrollment_spec",
}

for _, spec in ipairs(specs) do
  require(spec)
end

print("\n=========================================")
print(string.format("Test Results: %d Passed, %d Failed", passed, failed))
print("=========================================")

if failed > 0 then
  print("\nFailures:")
  for _, err in ipairs(errors) do print(err) end
  os.exit(1)
else
  print("All tests passed successfully!")
  os.exit(0)
end
