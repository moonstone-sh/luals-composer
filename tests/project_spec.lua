local project = require("luals_composer.project")

local TMP = os.tmpname()
os.remove(TMP)
os.execute("mkdir -p " .. TMP)

local serial = 0
local function scratch()
  serial = serial + 1
  local root = TMP .. "/p" .. serial
  assert_equal(os.execute("mkdir -p " .. root .. "/.moonstone/env"), true)
  return root
end

local function write(path, contents)
  local fh = assert(io.open(path, "wb"))
  fh:write(contents)
  fh:close()
end

describe("project identity", function()
  it("finds the nearest Moonstone project from a nested path", function()
    local root = scratch()
    write(root .. "/moonstone.toml", '[package]\nname = "demo"\nversion = "1.0.0"\n')
    os.execute("mkdir -p " .. root .. "/a/b")
    assert_equal(project.find_root(root .. "/a/b"), root)
  end)

  it("maps PUC Lua to its LuaLS runtime and share directory", function()
    local root = scratch()
    write(root .. "/.moonstone/env/env.toml", [[
[runtime]
name = "lua"
version = "5.4.9"
abi = "lua54"
]])
    local runtime, share = project.lua_runtime(root)
    assert_equal(runtime, "Lua 5.4")
    assert_equal(share, "5.4")
    assert_equal(project.installed_transport_path(root),
      ".moonstone/env/share/lua/5.4/luals_composer/init.lua")
  end)

  it("maps LuaJIT's lua51 ABI to share/lua/5.1", function()
    local root = scratch()
    write(root .. "/.moonstone/env/env.toml", [[
[runtime]
name = "luajit"
version = "2.1.0"
abi = "lua51"
]])
    local runtime, share = project.lua_runtime(root)
    assert_equal(runtime, "LuaJIT")
    assert_equal(share, "5.1")
    assert_equal(project.installed_transport_path(root),
      ".moonstone/env/share/lua/5.1/luals_composer/init.lua")
  end)

  it("explains a missing or unreadable Moonstone environment", function()
    local root = scratch()
    os.remove(root .. "/.moonstone/env/env.toml")
    local runtime, err = project.lua_runtime(root)
    assert_nil(runtime)
    assert_match(err, "moon sync")

    write(root .. "/.moonstone/env/env.toml", '[runtime]\nname = "lua"\n')
    runtime, err = project.lua_runtime(root)
    assert_nil(runtime)
    assert_match(err, "determine")
  end)

  it("reads installed identity without executing arbitrary version modules", function()
    local root = scratch()
    local dir = root .. "/luals_composer"
    os.execute("mkdir -p " .. dir)
    write(dir .. "/init.lua", "return {}")
    write(dir .. "/version.lua", [[
      HARMFUL_VERSION_SIDE_EFFECT = true
      return {
        PACKAGE = "moonstone/luals-composer",
        VERSION = "0.1.0",
        CONTRACT = 1,
        ENTRY_RELPATH = "luals_composer/init.lua",
      }
    ]])
    _G.HARMFUL_VERSION_SIDE_EFFECT = nil
    local identity = project.transport_identity_at(dir .. "/init.lua")
    assert_equal(identity.VERSION, "0.1.0")
    assert_nil(_G.HARMFUL_VERSION_SIDE_EFFECT,
      "reading installed metadata must not mutate caller globals")
  end)
end)
