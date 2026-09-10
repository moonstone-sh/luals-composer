local api = require("luals_composer")
local json = require("luals_composer.json")

local TMP = os.tmpname()
os.remove(TMP)
os.execute("mkdir -p " .. TMP)

local serial = 0
local function write(path, contents)
  local fh = assert(io.open(path, "wb"))
  fh:write(contents)
  fh:close()
end

local function read(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local contents = fh:read("a")
  fh:close()
  return contents
end

local function mkdir(path)
  assert_equal(os.execute("mkdir -p " .. path), true)
end

local function fixture(options)
  options = options or {}
  serial = serial + 1
  local root = TMP .. "/project" .. serial
  mkdir(root .. "/.moonstone/env")
  write(root .. "/moonstone.toml", [[
[package]
name = "fixture"
version = "1.0.0"
]])
  write(root .. "/.moonstone/env/env.toml", [[
[runtime]
name = "lua"
version = "5.4.9"
abi = "lua54"
]])

  local transport_dir = root .. "/.moonstone/env/share/lua/5.4/luals_composer"
  if not options.transport_missing then
    mkdir(transport_dir)
    write(transport_dir .. "/init.lua", "return {}\n")
    if not options.transport_unidentified then
      write(transport_dir .. "/version.lua",
        ('return { PACKAGE = "moonstone/luals-composer", VERSION = %q, CONTRACT = 1, ENTRY_RELPATH = "luals_composer/init.lua" }\n')
          :format(options.transport_version or "0.1.0"))
    end
  end

  mkdir(root .. "/plugins")
  write(root .. "/plugins/subject.lua", "function OnSetText() return nil end\n")
  write(root .. "/plugins/other.lua", "function OnSetText() return nil end\n")
  return root
end

local function descriptor(root, overrides)
  local value = {
    name = "subject",
    path = root .. "/plugins/subject.lua",
    transport = "^0.1.0",
    contract = 1,
    text_edits = "insertions",
    args = {},
    priority = "last",
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function plan_for(root, overrides)
  return api.plan({ root = root, plugin = descriptor(root, overrides) })
end

local function decode_file(path)
  local value, err = json.decode(assert(read(path), "missing file: " .. path))
  assert_nil(err)
  return value
end

local function assert_error_code(err, code)
  assert_true(type(err) == "table", "expected a structured error")
  assert_equal(err.code, code, err.message)
  assert_true(type(err.message) == "string" and err.message ~= "")
end

describe("enrollment planning", function()
  it("plans and previews a fresh project without writing either file", function()
    local root = fixture()
    local plan, err = plan_for(root)
    assert_nil(err)
    assert_not_nil(plan)
    assert_true(type(plan.summary) == "string" and plan.summary ~= "")
    assert_true(type(plan.changes) == "table" and #plan.changes > 0)
    assert_true(type(plan.warnings) == "table")
    assert_equal(plan.config, root .. "/.luarc.json")
    assert_equal(plan.registry, root .. "/luals-composer.json")
    assert_equal(plan.transport.package, "moonstone/luals-composer")
    assert_equal(plan.transport.version, "0.1.0")
    assert_equal(plan.transport.contract, 1)
    assert_equal(plan.plugin.name, "subject")
    assert_nil(read(plan.config))
    assert_nil(read(plan.registry))

    local preview = plan:preview()
    assert_true(type(preview.config) == "string")
    assert_true(type(preview.sidecar) == "string")
    assert_not_nil(json.decode(preview.config))
    assert_not_nil(json.decode(preview.sidecar))
    assert_nil(read(plan.config), "preview must not write .luarc.json")
    assert_nil(read(plan.registry), "preview must not write the sidecar")
  end)

  it("commits the canonical selector and managed sidecar", function()
    local root = fixture()
    local plan = assert(plan_for(root))
    local result, err = plan:commit()
    assert_nil(err)
    assert_equal(result.changed, true)
    assert_equal(result.config, root .. "/.luarc.json")
    assert_equal(result.registry, root .. "/luals-composer.json")
    assert_equal(result.transport.package, "moonstone/luals-composer")
    assert_equal(result.plugin.name, "subject")

    local repeated, repeated_err = plan:commit()
    assert_nil(repeated_err)
    assert_equal(repeated.changed, false)
    assert_equal(repeated.config, result.config)
    assert_equal(repeated.registry, result.registry)
    assert_equal(repeated.transport.version, result.transport.version)
    assert_equal(repeated.plugin.name, result.plugin.name)

    local luarc = decode_file(root .. "/.luarc.json")
    assert_equal(#luarc.runtime.plugin, 1)
    assert_equal(luarc.runtime.plugin[1],
      ".moonstone/env/share/lua/5.4/luals_composer/init.lua")
    assert_same(luarc.runtime.pluginArgs, { "--config=luals-composer.json" })

    local sidecar = decode_file(root .. "/luals-composer.json")
    assert_equal(sidecar.version, 1)
    assert_equal(sidecar.package, "moonstone/luals-composer")
    assert_equal(#sidecar.plugins, 1)
    assert_equal(sidecar.plugins[1].name, "subject")
    assert_equal(sidecar.plugins[1].path, "plugins/subject.lua")
    assert_equal(sidecar.plugins[1].contract, 1)
    assert_equal(sidecar.plugins[1].text_edits, "insertions")
    assert_same(sidecar.plugins[1].args, {})
    assert_nil(sidecar.plugins[1].priority,
      "priority selects insertion position; array order is canonical")
  end)

  it("is byte-stable and reports no change on repeated enrollment", function()
    local root = fixture()
    local first = assert(api.enroll({ root = root, plugin = descriptor(root) }))
    assert_equal(first.changed, true)
    local config_before = read(root .. "/.luarc.json")
    local sidecar_before = read(root .. "/luals-composer.json")

    local second, err = api.enroll({ root = root, plugin = descriptor(root) })
    assert_nil(err)
    assert_equal(second.changed, false)
    assert_equal(read(root .. "/.luarc.json"), config_before)
    assert_equal(read(root .. "/luals-composer.json"), sidecar_before)
  end)

  it("preserves unrelated LuaLS settings", function()
    local root = fixture()
    write(root .. "/.luarc.json", [[
{
  // must survive enrollment
  "runtime": { "version": "Lua 5.4" },
  "workspace": { "checkThirdParty": false },
  "diagnostics": { "globals": ["describe"] }
}
]])
    assert(api.enroll({ root = root, plugin = descriptor(root) }))
    local luarc = decode_file(root .. "/.luarc.json")
    assert_equal(luarc.runtime.version, "Lua 5.4")
    assert_equal(luarc.workspace.checkThirdParty, false)
    assert_equal(luarc.diagnostics.globals[1], "describe")
  end)
end)

describe("enrollment migration and ordering", function()
  it("migrates an unambiguous direct plugin list when pluginArgs is empty", function()
    local root = fixture()
    write(root .. "/.luarc.json", [[
{ "runtime": { "plugin": ["plugins/other.lua"], "pluginArgs": [] } }
]])
    local result, err = api.enroll({ root = root, plugin = descriptor(root) })
    assert_nil(err)
    assert_not_nil(result)
    local sidecar = decode_file(root .. "/luals-composer.json")
    assert_equal(#sidecar.plugins, 2)
    assert_equal(sidecar.plugins[1].path, "plugins/other.lua")
    assert_equal(sidecar.plugins[1].text_edits, "legacy")
    assert_equal(sidecar.plugins[2].name, "subject")
  end)

  it("deduplicates an exact plugin already present in a legacy list", function()
    local root = fixture()
    write(root .. "/.luarc.json", [[
{ "runtime": { "plugin": ["plugins/subject.lua"], "pluginArgs": [] } }
]])
    local result, err = api.enroll({ root = root, plugin = descriptor(root) })
    assert_nil(err)
    assert_not_nil(result)
    local sidecar = decode_file(root .. "/luals-composer.json")
    assert_equal(#sidecar.plugins, 1)
    assert_equal(sidecar.plugins[1].path, "plugins/subject.lua")
  end)

  it("preserves disabled children while excluding them at runtime", function()
    local root = fixture()
    write(root .. "/luals-composer.json", [[
{
  "version": 1,
  "package": "moonstone/luals-composer",
  "plugins": [
    { "name": "off", "path": "plugins/other.lua", "transport": "^0.1.0",
      "contract": 1, "text_edits": "insertions", "args": [],
      "enabled": false }
  ]
}
]])
    assert(api.enroll({ root = root, plugin = descriptor(root) }))
    local sidecar = decode_file(root .. "/luals-composer.json")
    assert_equal(#sidecar.plugins, 2)
    assert_equal(sidecar.plugins[1].name, "off")
    assert_equal(sidecar.plugins[1].enabled, false)
  end)

  it("supports first and last insertion while preserving existing order", function()
    local root = fixture()
    assert(api.enroll({ root = root, plugin = descriptor(root, {
      name = "existing", path = root .. "/plugins/other.lua", priority = "last",
    }) }))
    assert(api.enroll({ root = root, plugin = descriptor(root, {
      name = "first", priority = "first",
    }) }))
    local sidecar = decode_file(root .. "/luals-composer.json")
    assert_equal(sidecar.plugins[1].name, "first")
    assert_equal(sidecar.plugins[2].name, "existing")
    assert_nil(sidecar.plugins[1].priority)
    assert_nil(sidecar.plugins[2].priority)
  end)
end)

describe("enrollment refusals", function()
  it("refuses an invalid existing .luarc.json", function()
    local root = fixture()
    write(root .. "/.luarc.json", "{ not json")
    local plan, err = plan_for(root)
    assert_nil(plan)
    assert_error_code(err, "config_conflict")
    assert_equal(read(root .. "/.luarc.json"), "{ not json")
  end)

  it("refuses transport plus direct sibling plugins", function()
    local root = fixture()
    write(root .. "/.luarc.json", [[
{ "runtime": {
  "plugin": [
    ".moonstone/env/share/lua/5.4/luals_composer/init.lua",
    "plugins/other.lua"
  ],
  "pluginArgs": ["--config=luals-composer.json"]
} }
]])
    local plan, err = plan_for(root)
    assert_nil(plan)
    assert_error_code(err, "config_conflict")
  end)

  it("refuses direct plugin migration when direct pluginArgs carry meaning", function()
    local root = fixture()
    write(root .. "/.luarc.json", [[
{ "runtime": {
  "plugin": ["plugins/other.lua"],
  "pluginArgs": ["--mode=special"]
} }
]])
    local plan, err = plan_for(root)
    assert_nil(plan)
    assert_error_code(err, "source_conflict")
  end)

  it("refuses a duplicate name that points somewhere else", function()
    local root = fixture()
    assert(api.enroll({ root = root, plugin = descriptor(root) }))
    local plan, err = plan_for(root, { path = root .. "/plugins/other.lua" })
    assert_nil(plan)
    assert_error_code(err, "plugin_conflict")
  end)

  it("refuses a child that recursively points at the transport", function()
    local root = fixture()
    local path = root .. "/.moonstone/env/share/lua/5.4/luals_composer/init.lua"
    local plan, err = plan_for(root, { path = path, name = "transport-child" })
    assert_nil(plan)
    assert_error_code(err, "plugin_conflict")
  end)

  it("refuses an unknown insertion priority", function()
    local root = fixture()
    local plan, err = plan_for(root, { priority = "middle" })
    assert_nil(plan)
    assert_error_code(err, "order_conflict")
  end)

  it("distinguishes missing, unidentified, and incompatible transports", function()
    local missing = fixture({ transport_missing = true })
    local plan, err = plan_for(missing)
    assert_nil(plan)
    assert_error_code(err, "transport_missing")

    local unidentified = fixture({ transport_unidentified = true })
    plan, err = plan_for(unidentified)
    assert_nil(plan)
    assert_error_code(err, "transport_unidentified")

    local incompatible = fixture({ transport_version = "1.0.0" })
    plan, err = plan_for(incompatible)
    assert_nil(plan)
    assert_error_code(err, "transport_incompatible")
  end)

  it("validates the consumer contract before planning writes", function()
    local root = fixture()
    for _, bad in ipairs({
      { contract = 2 },
      { text_edits = "anything" },
      { args = "--not-an-array" },
      { transport = "not a constraint" },
    }) do
      local plan, err = plan_for(root, bad)
      assert_nil(plan)
      assert_not_nil(err)
      assert_nil(read(root .. "/.luarc.json"))
    end
  end)
end)

describe("enrollment transaction safety", function()
  it("detects a stale .luarc.json immediately before commit", function()
    local root = fixture()
    local plan = assert(plan_for(root))
    write(root .. "/.luarc.json", '{ "changed": "outside" }\n')
    local result, err = plan:commit()
    assert_nil(result)
    assert_error_code(err, "stale_plan")
    assert_equal(read(root .. "/.luarc.json"), '{ "changed": "outside" }\n')
    assert_nil(read(root .. "/luals-composer.json"))
  end)

  it("detects a stale sidecar immediately before commit", function()
    local root = fixture()
    local plan = assert(plan_for(root))
    write(root .. "/luals-composer.json", '{ "changed": "outside" }\n')
    local result, err = plan:commit()
    assert_nil(result)
    assert_error_code(err, "stale_plan")
    assert_nil(read(root .. "/.luarc.json"))
    assert_equal(read(root .. "/luals-composer.json"), '{ "changed": "outside" }\n')
  end)

  it("detects a changed consumer plugin before activating its descriptor", function()
    local root = fixture()
    local plan = assert(plan_for(root))
    write(root .. "/plugins/subject.lua", "function OnSetText() return {} end\n")
    local result, err = plan:commit()
    assert_nil(result)
    assert_error_code(err, "stale_plan")
    assert_nil(read(root .. "/.luarc.json"))
    assert_nil(read(root .. "/luals-composer.json"))
  end)

  it("reports practical write failures without leaving a half-enrolled config", function()
    local root = fixture()
    local plan = assert(plan_for(root))
    mkdir(root .. "/luals-composer.json")
    local result, err = plan:commit()
    assert_nil(result)
    assert_error_code(err, "io_error")
    assert_nil(read(root .. "/.luarc.json"),
      "failure to install the sidecar must not leave LuaLS pointing at it")
  end)
end)

--------------------------------------------------------------------------
-- Enrollment by name: the plugin describes itself, the consumer does not.
--------------------------------------------------------------------------

--- Materialise a package into the fixture's Moonstone environment, exactly
--- where `moon sync` would put it, optionally with a self-description.
local function install(root, module, manifest_text)
  local module_root = root .. "/.moonstone/env/share/lua/5.4/" .. module
  mkdir(module_root .. "/luals")
  write(module_root .. "/luals/plugin.lua", "function OnSetText() return nil end\n")
  if manifest_text then write(module_root .. "/luals-plugin.lua", manifest_text) end
  return ".moonstone/env/share/lua/5.4/" .. module .. "/luals/plugin.lua"
end

local SELF_DESCRIPTION = [[
return {
  name = "subject",
  path = "luals/plugin.lua",
  transport = "^0.1.0",
  contract = 1,
  text_edits = "insertions",
  args = {},
}
]]

describe("enrollment by package name", function()
  it("produces the same enrollment as the equivalent hand-typed descriptor", function()
    -- Two fresh projects, same installed package. One consumer hand-types the
    -- whole descriptor the way every caller had to before; the other passes
    -- nothing but the name. The results must be indistinguishable.
    --
    -- "Indistinguishable" is asserted on the PARSED registry, not on its
    -- bytes. Composer serialises a descriptor in Lua `pairs` order, which is
    -- unspecified — it varies with the per-process string hash seed and with
    -- the order the fields were assigned. The two modes do build their
    -- descriptor tables by different routes, so the KEY ORDER inside each
    -- descriptor object may legitimately differ while the document does not.
    -- That is a pre-existing property of enrollment (two hand-typed runs in
    -- two processes differ the same way), it is invisible to every JSON
    -- reader, and asserting on it would be asserting on luck.
    --
    -- `.luarc.json` is byte-compared, because it holds no descriptor table —
    -- only string arrays, whose order Composer does control.
    local typed_root = fixture()
    local named_root = fixture()
    local relative = install(typed_root, "subject", SELF_DESCRIPTION)
    assert_equal(install(named_root, "subject", SELF_DESCRIPTION), relative)

    local typed = assert(api.plan({ root = typed_root, plugin = {
      name = "subject", path = relative, transport = "^0.1.0",
      contract = 1, text_edits = "insertions", args = {},
    } }))
    local named = assert(api.plan({ root = named_root, plugin = "subject" }))

    assert_equal(named:preview().config, typed:preview().config)
    assert_same(named.plugin, typed.plugin, "the resolved descriptors must be equal as values")
    assert_same(named.warnings, typed.warnings)
    assert_equal(#named.warnings, 0, "self-description is not a migration and must not warn")

    assert(named:commit())
    assert(typed:commit())
    assert_equal(read(named_root .. "/.luarc.json"), read(typed_root .. "/.luarc.json"))
    assert_same(decode_file(named_root .. "/luals-composer.json"),
      decode_file(typed_root .. "/luals-composer.json"),
      "the registries must parse to the same document")

    local registry = decode_file(named_root .. "/luals-composer.json")
    assert_equal(registry.plugins[1].name, "subject")
    assert_equal(registry.plugins[1].path, relative)
    assert_equal(registry.plugins[1].text_edits, "insertions")
    assert_equal(registry.plugins[1].contract, 1)
  end)

  it("accepts the bare string and the { name = ... } table identically", function()
    local string_root, table_root = fixture(), fixture()
    install(string_root, "subject", SELF_DESCRIPTION)
    install(table_root, "subject", SELF_DESCRIPTION)
    local from_string = assert(api.plan({ root = string_root, plugin = "subject" }))
    local from_table = assert(api.plan({ root = table_root, plugin = { name = "subject" } }))
    assert_same(from_string.plugin, from_table.plugin)
    assert_same(json.decode(from_string:preview().sidecar), json.decode(from_table:preview().sidecar))
  end)

  it("resolves a hyphenated package name into its underscored module tree", function()
    local root = fixture()
    install(root, "hydronium_luax", (SELF_DESCRIPTION
      :gsub('"subject"', '"hydronium-luax"'):gsub('"insertions"', '"ranges"')))
    local plan = assert(api.plan({ root = root, plugin = "hydronium-luax" }))
    assert_equal(plan.plugin.name, "hydronium-luax")
    assert_equal(plan.plugin.path, ".moonstone/env/share/lua/5.4/hydronium_luax/luals/plugin.lua")
    assert_equal(plan.plugin.text_edits, "ranges")
  end)

  it("lets the consumer keep ordering control the manifest cannot claim", function()
    local root = fixture()
    install(root, "subject", SELF_DESCRIPTION)
    assert(plan_for(root, { name = "first-comer" }):commit())
    local plan = assert(api.plan({ root = root, plugin = { name = "subject", priority = "first" } }))
    assert(plan:commit())
    local registry = decode_file(root .. "/luals-composer.json")
    assert_equal(registry.plugins[1].name, "subject")
    assert_equal(registry.plugins[2].name, "first-comer")
  end)

  it("lets a caller override any single field the manifest declared", function()
    local root = fixture()
    install(root, "subject", SELF_DESCRIPTION)
    local plan = assert(api.plan({ root = root,
      plugin = { name = "subject", text_edits = "ranges", args = { "--verbose" } } }))
    assert_equal(plan.plugin.text_edits, "ranges", "the caller's mode must win")
    assert_same(plan.plugin.args, { "--verbose" })
    assert_equal(plan.plugin.transport, "^0.1.0", "unspecified fields still come from the manifest")
  end)

  it("routes a self-described descriptor through the same contract validation", function()
    -- A manifest cannot smuggle in a descriptor an explicit caller would be
    -- refused for. Same validator, same message, same error code.
    local root = fixture()
    install(root, "subject", (SELF_DESCRIPTION:gsub('"insertions"', '"whatever"')))
    local plan, err = api.plan({ root = root, plugin = "subject" })
    assert_nil(plan)
    assert_error_code(err, "plugin_conflict")
    assert_match(err.message, "text_edits must be insertions or ranges")
  end)

  it("refuses a manifest whose declared transport range excludes the installed Composer", function()
    local root = fixture()
    install(root, "subject", (SELF_DESCRIPTION:gsub('"%^0%.1%.0"', '"^9.0.0"')))
    local plan, err = api.plan({ root = root, plugin = "subject" })
    assert_nil(plan)
    assert_error_code(err, "transport_incompatible")
  end)

  it("tells a caller exactly what to do when the package ships no manifest", function()
    local root = fixture()
    install(root, "subject") -- installed, but silent about LuaLS
    local plan, err = api.plan({ root = root, plugin = "subject" })
    assert_nil(plan)
    assert_error_code(err, "plugin_undescribed")
    assert_match(err.message, "ships no LuaLS self%-description")
    assert_match(err.message, "luals%-plugin%.lua")
    assert_match(err.message, "explicit descriptor")
    assert_equal(err.plugin, "subject")
    assert_nil(read(root .. "/.luarc.json"), "a failed lookup must write nothing")
    assert_nil(read(root .. "/luals-composer.json"))
  end)

  it("blames the package, not the consumer, for a manifest that is wrong", function()
    -- A malformed self-description is an ordinary bad descriptor. It must NOT
    -- read as "this package is undescribed", because falling back to an
    -- explicit descriptor is not the fix here — the manifest is.
    local root = fixture()
    install(root, "subject", (SELF_DESCRIPTION:gsub('"subject"', '"someone-else"')))
    local plan, err = api.plan({ root = root, plugin = "subject" })
    assert_nil(plan)
    assert_error_code(err, "plugin_conflict")
    assert_match(err.message, "declares the plugin name")
  end)

  it("distinguishes a package that is not installed at all", function()
    local root = fixture()
    local plan, err = api.plan({ root = root, plugin = "absent" })
    assert_nil(plan)
    assert_error_code(err, "plugin_undescribed")
    assert_match(err.message, "no installed package provides 'absent'")
    assert_match(err.message, "moon sync")
  end)

  it("still refuses a descriptor that is neither a name nor a table", function()
    local root = fixture()
    local plan, err = api.plan({ root = root, plugin = 42 })
    assert_nil(plan)
    assert_error_code(err, "plugin_conflict")
    assert_match(err.message, "plugin descriptor is required")
  end)

  it("leaves the explicit-descriptor path untouched for an undescribed plugin", function()
    -- The fallback the error message recommends has to actually work.
    local root = fixture()
    install(root, "subject")
    local plan = assert(api.plan({ root = root, plugin = descriptor(root, {
      name = "subject",
      path = ".moonstone/env/share/lua/5.4/subject/luals/plugin.lua",
    }) }))
    assert(plan:commit())
    local registry = decode_file(root .. "/luals-composer.json")
    assert_equal(registry.plugins[1].path, ".moonstone/env/share/lua/5.4/subject/luals/plugin.lua")
  end)
end)
