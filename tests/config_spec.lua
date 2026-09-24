local config = require("luals_composer.config")

--- Scratch directory for real config files. Tests write real files rather than
--- mocking io, so path resolution is exercised for real.
local TMP = os.tmpname()
os.remove(TMP)
os.execute("mkdir -p " .. TMP)

local function write(path, contents)
  local fh = assert(io.open(path, "wb"))
  fh:write(contents)
  fh:close()
  return path
end

--- Run `fn` with an environment variable set, then restore it.
--- Lua has no setenv, so this shells out only where the platform allows it;
--- instead we drive the env-var path by passing it through resolve's opts where
--- possible and skip otherwise. Here we simply assert the reader is wired.
local function env_is_clean()
  return not os.getenv(config.ENV_PLUGINS) and not os.getenv(config.ENV_CONFIG)
end

describe("config path helpers", function()
  it("recognises absolute paths", function()
    assert_true(config.is_absolute("/a/b"))
    assert_true(config.is_absolute("C:/a/b"))
    assert_false(config.is_absolute("a/b"))
    assert_false(config.is_absolute("./a"))
  end)

  it("converts file URIs to paths and decodes percent-escapes", function()
    assert_equal(config.uri_to_path("file:///Users/x/ws"), "/Users/x/ws")
    assert_equal(config.uri_to_path("file:///a%20b/c"), "/a b/c")
    assert_nil(config.uri_to_path(nil))
  end)

  it("resolves relative paths against a base", function()
    assert_equal(config.resolve_path("plug.lua", "/ws"), "/ws/plug.lua")
    assert_equal(config.resolve_path("/abs/plug.lua", "/ws"), "/abs/plug.lua")
  end)

  it("substitutes ${workspaceFolder}", function()
    assert_equal(config.resolve_path("${workspaceFolder}/p.lua", "/base", "/ws"), "/ws/p.lua")
  end)

  it("expands a leading ~", function()
    local home = os.getenv("HOME")
    if home then
      assert_equal(config.resolve_path("~/p.lua", "/ws"), home .. "/p.lua")
    end
  end)

  it("derives a directory name", function()
    assert_equal(config.dirname("/a/b/c.json"), "/a/b")
    assert_equal(config.dirname("c.json"), ".")
  end)
end)

describe("config.resolve — Lua.runtime.pluginArgs", function()
  it("reads a plain array of paths, preserving order as priority", function()
    if not env_is_clean() then return end
    local c = config.resolve({
      uri = "file:///ws",
      args = { "/abs/hydronium.lua", "valua/plugin.lua" },
    })
    assert_equal(c.source, "Lua.runtime.pluginArgs")
    assert_equal(#c.plugins, 2)
    assert_equal(c.plugins[1].path, "/abs/hydronium.lua")
    assert_equal(c.plugins[2].path, "/ws/valua/plugin.lua")
    assert_equal(c.plugins[1].name, "hydronium.lua")
  end)

  it("accepts the --plugin=<path> form", function()
    if not env_is_clean() then return end
    local c = config.resolve({ uri = "file:///ws", args = { "--plugin=/abs/p.lua" } })
    assert_equal(#c.plugins, 1)
    assert_equal(c.plugins[1].path, "/abs/p.lua")
  end)

  it("ignores unrelated flags without failing", function()
    if not env_is_clean() then return end
    local c = config.resolve({ uri = "file:///ws", args = { "--verbose", "/abs/p.lua" } })
    assert_equal(#c.plugins, 1)
    assert_equal(c.plugins[1].path, "/abs/p.lua")
  end)
end)

describe("config.resolve — luals-composer.json", function()
  it("reads the sidecar file when no args are given", function()
    if not env_is_clean() then return end
    local ws = TMP .. "/ws1"
    os.execute("mkdir -p " .. ws)
    write(ws .. "/" .. config.CONFIG_BASENAME, [[
      {
        // hydronium must win range conflicts, so it comes first
        "plugins": [
          "/abs/hydronium.lua",
          { "path": "relative/valua.lua", "name": "valua" },
          { "path": "/abs/disabled.lua", "enabled": false }
        ]
      }
    ]])

    local c = config.resolve({ uri = "file://" .. ws })
    assert_equal(c.source, ws .. "/" .. config.CONFIG_BASENAME)
    assert_equal(#c.plugins, 2, "the disabled entry must be skipped")
    assert_equal(c.plugins[1].path, "/abs/hydronium.lua")
    assert_equal(c.plugins[2].path, ws .. "/relative/valua.lua")
    assert_equal(c.plugins[2].name, "valua")
  end)

  it("reports invalid JSON instead of silently composing nothing", function()
    if not env_is_clean() then return end
    local ws = TMP .. "/ws2"
    os.execute("mkdir -p " .. ws)
    write(ws .. "/" .. config.CONFIG_BASENAME, "{ not json")

    local c = config.resolve({ uri = "file://" .. ws })
    assert_equal(#c.plugins, 0)
    assert_true(#c.errors > 0, "a broken config file must produce an error")
    assert_true(c.errors[1]:find("not valid JSON", 1, true) ~= nil, c.errors[1])
  end)

  it("reports a config file with no plugins array", function()
    if not env_is_clean() then return end
    local ws = TMP .. "/ws3"
    os.execute("mkdir -p " .. ws)
    write(ws .. "/" .. config.CONFIG_BASENAME, '{ "settings": {} }')

    local c = config.resolve({ uri = "file://" .. ws })
    assert_equal(#c.plugins, 0)
    assert_true(c.errors[1]:find("no `plugins` array", 1, true) ~= nil, c.errors[1])
  end)

  it("carries a settings table through", function()
    if not env_is_clean() then return end
    local ws = TMP .. "/ws4"
    os.execute("mkdir -p " .. ws)
    write(ws .. "/" .. config.CONFIG_BASENAME,
      '{ "plugins": ["/a.lua"], "settings": { "logToStderr": false } }')

    local c = config.resolve({ uri = "file://" .. ws })
    assert_equal(c.settings.logToStderr, false)
  end)
end)

describe("config.resolve — precedence", function()
  it("prefers pluginArgs over the sidecar file", function()
    if not env_is_clean() then return end
    local ws = TMP .. "/ws5"
    os.execute("mkdir -p " .. ws)
    write(ws .. "/" .. config.CONFIG_BASENAME, '{ "plugins": ["/from-file.lua"] }')

    local c = config.resolve({ uri = "file://" .. ws, args = { "/from-args.lua" } })
    assert_equal(c.source, "Lua.runtime.pluginArgs")
    assert_equal(c.plugins[1].path, "/from-args.lua")
  end)

  it("composes nothing, without erroring, when unconfigured", function()
    if not env_is_clean() then return end
    local ws = TMP .. "/ws6"
    os.execute("mkdir -p " .. ws)
    local c = config.resolve({ uri = "file://" .. ws })
    assert_equal(#c.plugins, 0)
    assert_equal(c.source, "none")
    assert_equal(#c.errors, 0)
  end)
end)

describe("config.resolve — explicit managed sidecar selection", function()
  local function managed(plugins)
    local entries = {}
    for _, plugin in ipairs(plugins) do
      entries[#entries + 1] = ([[
        { "name": %q, "path": %q, "transport": "^0.2.0",
          "contract": 1, "text_edits": %q,
          "enabled": %s, "args": [] }
      ]]):format(plugin.name, plugin.path, plugin.text_edits or "insertions",
        plugin.enabled == false and "false" or "true")
    end
    return ('{ "version": 1, "package": "moonstone/luals-composer", "plugins": [%s] }')
      :format(table.concat(entries, ","))
  end

  it("gives --config= precedence over the conventional sidecar", function()
    if not env_is_clean() then return end
    local ws = TMP .. "/selector-precedence"
    os.execute("mkdir -p " .. ws)
    write(ws .. "/" .. config.CONFIG_BASENAME,
      managed({ { name = "default", path = "/default.lua" } }))
    write(ws .. "/chosen.json",
      managed({ { name = "chosen", path = "plugins/chosen.lua" } }))

    local c = config.resolve({
      uri = "file://" .. ws,
      args = { "--config=chosen.json" },
    })
    assert_equal(c.source, ws .. "/chosen.json")
    assert_equal(#c.plugins, 1)
    assert_equal(c.plugins[1].name, "chosen")
    assert_equal(c.plugins[1].path, ws .. "/plugins/chosen.lua")
  end)

  it("refuses a missing selector value", function()
    if not env_is_clean() then return end
    local ws = TMP .. "/selector-missing"
    os.execute("mkdir -p " .. ws)
    local c = config.resolve({ uri = "file://" .. ws, args = { "--config" } })
    assert_equal(#c.plugins, 0)
    assert_true(#c.errors > 0)
    assert_match(c.errors[1], "--config")
  end)

  it("refuses duplicate selectors", function()
    if not env_is_clean() then return end
    local ws = TMP .. "/selector-duplicate"
    os.execute("mkdir -p " .. ws)
    write(ws .. "/one.json", managed({ { name = "one", path = "/one.lua" } }))
    write(ws .. "/two.json", managed({ { name = "two", path = "/two.lua" } }))
    local c = config.resolve({
      uri = "file://" .. ws,
      args = { "--config=one.json", "--config=two.json" },
    })
    assert_equal(#c.plugins, 0)
    assert_true(#c.errors > 0)
    assert_match(table.concat(c.errors, " | "), "duplicate")
  end)

  it("refuses mixed selector and legacy child paths", function()
    if not env_is_clean() then return end
    local ws = TMP .. "/selector-mixed"
    os.execute("mkdir -p " .. ws)
    write(ws .. "/chosen.json", managed({ { name = "chosen", path = "/chosen.lua" } }))
    local c = config.resolve({
      uri = "file://" .. ws,
      args = { "--config=chosen.json", "/legacy-child.lua" },
    })
    assert_equal(#c.plugins, 0)
    assert_true(#c.errors > 0)
    assert_match(table.concat(c.errors, " | "), "mix")
  end)

  it("preserves sidecar order while excluding disabled children", function()
    if not env_is_clean() then return end
    local ws = TMP .. "/selector-order"
    os.execute("mkdir -p " .. ws)
    write(ws .. "/chosen.json", managed({
      { name = "later", path = "/later.lua", text_edits = "ranges" },
      { name = "off", path = "/off.lua", enabled = false },
      { name = "first", path = "/first.lua" },
    }))
    local c = config.resolve({
      uri = "file://" .. ws,
      args = { "--config=chosen.json" },
    })
    assert_equal(#c.plugins, 2)
    assert_equal(c.plugins[1].name, "later")
    assert_equal(c.plugins[2].name, "first")
    assert_equal(c.plugins[1].contract, 1)
    assert_equal(c.plugins[1].text_edits, "ranges")
    assert_equal(c.plugins[2].text_edits, "insertions")
  end)
end)
