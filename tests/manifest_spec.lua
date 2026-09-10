local manifest = require("luals_composer.manifest")

local TMP = os.tmpname()
os.remove(TMP)
os.execute("mkdir -p " .. TMP)

local serial = 0

local function write(path, contents)
  local fh = assert(io.open(path, "wb"))
  fh:write(contents)
  fh:close()
end

local function mkdir(path)
  assert_equal(os.execute("mkdir -p " .. path), true)
end

--- A project root with a materialised Moonstone environment, optionally
--- containing one installed package that may or may not describe itself.
local function fixture(options)
  options = options or {}
  serial = serial + 1
  local root = TMP .. "/mf" .. serial
  mkdir(root .. "/.moonstone/env")
  write(root .. "/.moonstone/env/env.toml", '[runtime]\nname = "lua"\nversion = "5.4.9"\nabi = "lua54"\n')
  if options.module then
    local module_root = root .. "/.moonstone/env/share/lua/5.4/" .. options.module
    mkdir(module_root .. "/luals")
    write(module_root .. "/luals/plugin.lua", "function OnSetText() return nil end\n")
    if options.manifest then write(module_root .. "/luals-plugin.lua", options.manifest) end
  end
  return root
end

local GOOD = [[
return {
  name = "subject",
  path = "luals/plugin.lua",
  transport = "^0.1.0",
  contract = 1,
  text_edits = "insertions",
  args = {},
}
]]

describe("manifest module naming", function()
  it("maps a Moonstone package name onto its installed Lua module directory", function()
    assert_equal(manifest.module_dir("valua"), "valua")
    assert_equal(manifest.module_dir("clingy"), "clingy")
    assert_equal(manifest.module_dir("hydronium-luax"), "hydronium_luax")
  end)

  it("drops a scope prefix the way Moonstone does when materialising", function()
    assert_equal(manifest.module_dir("moonstone/hydronium-luax"), "hydronium_luax")
    assert_equal(manifest.module_dir("moonstone/luals-composer"), "luals_composer")
  end)

  it("locates a manifest purely as a function of the project and the name", function()
    local root = fixture()
    local module_root, path = manifest.location(root, "moonstone/hydronium-luax")
    assert_equal(module_root, ".moonstone/env/share/lua/5.4/hydronium_luax")
    assert_equal(path, ".moonstone/env/share/lua/5.4/hydronium_luax/luals-plugin.lua")
  end)

  it("honours an explicit module override when name and directory differ", function()
    local root = fixture()
    local module_root = manifest.location(root, "subject", "vendored_subject")
    assert_equal(module_root, ".moonstone/env/share/lua/5.4/vendored_subject")
  end)

  it("reports a missing Moonstone environment rather than guessing an ABI", function()
    serial = serial + 1
    local bare = TMP .. "/bare" .. serial
    mkdir(bare)
    local module_root, err = manifest.location(bare, "subject")
    assert_nil(module_root)
    assert_match(err, "moon sync")
  end)
end)

describe("manifest reading", function()
  it("returns the declared table", function()
    local root = fixture({ module = "subject", manifest = GOOD })
    local data = assert(manifest.read(root .. "/.moonstone/env/share/lua/5.4/subject/luals-plugin.lua"))
    assert_equal(data.name, "subject")
    assert_equal(data.text_edits, "insertions")
    assert_equal(data.contract, 1)
  end)

  it("evaluates in an empty environment, so a manifest can reach no global", function()
    local root = fixture({ module = "subject", manifest = 'return { name = tostring(os.time()) }\n' })
    local data, err = manifest.read(root .. "/.moonstone/env/share/lua/5.4/subject/luals-plugin.lua")
    assert_nil(data)
    assert_match(err, "failed to evaluate")
  end)

  it("refuses a manifest that is not loadable Lua", function()
    local root = fixture({ module = "subject", manifest = "return {{{\n" })
    local data, err = manifest.read(root .. "/.moonstone/env/share/lua/5.4/subject/luals-plugin.lua")
    assert_nil(data)
    assert_match(err, "not loadable Lua")
  end)

  it("refuses a manifest that does not return a table", function()
    local root = fixture({ module = "subject", manifest = 'return "insertions"\n' })
    local data, err = manifest.read(root .. "/.moonstone/env/share/lua/5.4/subject/luals-plugin.lua")
    assert_nil(data)
    assert_match(err, "must return a table")
  end)
end)

describe("manifest resolution", function()
  it("completes a name-only request into a project-relative descriptor", function()
    local root = fixture({ module = "subject", manifest = GOOD })
    local descriptor = assert(manifest.resolve(root, { name = "subject" }))
    assert_equal(descriptor.name, "subject")
    assert_equal(descriptor.path, ".moonstone/env/share/lua/5.4/subject/luals/plugin.lua")
    assert_equal(descriptor.transport, "^0.1.0")
    assert_equal(descriptor.contract, 1)
    assert_equal(descriptor.text_edits, "insertions")
    assert_same(descriptor.args, {})
  end)

  it("never carries a self-assigned priority out of a package", function()
    local root = fixture({ module = "subject",
      manifest = GOOD:gsub("args = {},", 'args = {}, priority = "first",') })
    local descriptor = assert(manifest.resolve(root, { name = "subject" }))
    assert_nil(descriptor.priority)
  end)

  it("says the package is not installed when nothing is materialised", function()
    local root = fixture()
    local descriptor, err = manifest.resolve(root, { name = "subject" })
    assert_nil(descriptor)
    assert_match(err, "no installed package provides 'subject'")
    assert_match(err, "moon sync")
    assert_match(err, "explicit descriptor")
  end)

  it("says the package ships no self-description when it is installed without one", function()
    local root = fixture({ module = "subject" })
    local descriptor, err = manifest.resolve(root, { name = "subject" })
    assert_nil(descriptor)
    assert_match(err, "ships no LuaLS self%-description")
    assert_match(err, "luals%-plugin%.lua")
    assert_match(err, "explicit descriptor")
  end)

  it("refuses a manifest that claims another package's name", function()
    local root = fixture({ module = "subject", manifest = GOOD:gsub('"subject"', '"impostor"') })
    local descriptor, err = manifest.resolve(root, { name = "subject" })
    assert_nil(descriptor)
    assert_match(err, "declares the plugin name")
  end)

  it("refuses a manifest with no path", function()
    local root = fixture({ module = "subject", manifest = GOOD:gsub('path = "luals/plugin.lua",', "") })
    local descriptor, err = manifest.resolve(root, { name = "subject" })
    assert_nil(descriptor)
    assert_match(err, "declares no plugin `path`")
  end)

  it("refuses a path that escapes or ignores the package's own directory", function()
    for _, bad in ipairs({ "/etc/passwd", "../../elsewhere/plugin.lua" }) do
      local root = fixture({ module = "subject",
        manifest = GOOD:gsub('"luals/plugin%.lua"', ('%q'):format(bad)) })
      local descriptor, err = manifest.resolve(root, { name = "subject" })
      assert_nil(descriptor, "should refuse " .. bad)
      assert_match(err, "relative to its own directory")
    end
  end)

  it("requires a name to look anything up", function()
    local root = fixture()
    local descriptor, err = manifest.resolve(root, {})
    assert_nil(descriptor)
    assert_match(err, "requires a package name")
  end)
end)

describe("manifest failure kinds", function()
  it("reports a silent package as missing, so a caller knows to fall back", function()
    local root = fixture({ module = "subject" })
    local _, _, kind = manifest.resolve(root, { name = "subject" })
    assert_equal(kind, "missing")
    local absent = fixture()
    local _, _, absent_kind = manifest.resolve(absent, { name = "subject" })
    assert_equal(absent_kind, "missing")
  end)

  it("reports a wrong manifest as invalid, because falling back is not the fix", function()
    for _, broken in ipairs({
      GOOD:gsub('"subject"', '"impostor"'),
      GOOD:gsub('path = "luals/plugin.lua",', ""),
      GOOD:gsub('"luals/plugin%.lua"', '"../escape.lua"'),
      "return 7\n",
    }) do
      local root = fixture({ module = "subject", manifest = broken })
      local descriptor, _, kind = manifest.resolve(root, { name = "subject" })
      assert_nil(descriptor)
      assert_equal(kind, "invalid")
    end
  end)
end)
