-- Loading children the way lua-language-server does.
--
-- These tests write real plugin files to disk and load them, because the whole
-- point of the loader is fidelity to LuaLS's real loading contract
-- (`script/plugin.lua:130-162`) — a mocked loader would prove nothing.

local loader = require("luals_composer.loader")
local log = require("luals_composer.log")

log.to_stderr = false -- keep expected-failure noise out of the test output

local TMP = os.tmpname()
os.remove(TMP)
os.execute("mkdir -p " .. TMP)

local counter = 0
local function plugin_file(source)
  counter = counter + 1
  local path = ("%s/p%d.lua"):format(TMP, counter)
  local fh = assert(io.open(path, "wb"))
  fh:write(source)
  fh:close()
  return { path = path, name = "p" .. counter }
end

describe("loader.load_child", function()
  it("picks up hooks assigned as globals, the canonical LuaLS style", function()
    local spec = plugin_file([[
      function OnSetText(uri, text) return { { start = 1, finish = 0, text = "x" } } end
      function ResolveRequire(uri, name) return "resolved:" .. name end
    ]])
    local child, err = loader.load_child(spec)
    assert_nil(err)
    assert_true(type(child.hooks.OnSetText) == "function")
    assert_true(type(child.hooks.ResolveRequire) == "function")
    assert_equal(child.hooks.ResolveRequire("uri", "mod"), "resolved:mod")
  end)

  it("also picks up hooks from the chunk's return value", function()
    -- hydronium-luax's entry file both assigns globals and returns a table;
    -- accepting either shape costs nothing and removes a class of surprise.
    local spec = plugin_file([[
      local M = {}
      function M.OnSetText(uri, text) return nil end
      return M
    ]])
    local child, err = loader.load_child(spec)
    assert_nil(err)
    assert_true(type(child.hooks.OnSetText) == "function")
  end)

  it("passes LuaLS's own vararg shape to the chunk", function()
    -- LuaLS calls the chunk as f(f, uri, args) — script/plugin.lua:157 — which
    -- is why real plugins start `local _, uri, args = ...`. The child reports
    -- what it saw back through its own hook.
    local spec = plugin_file([[
      local chunk, uri, args = ...
      local saw = ("%s|%s|%s"):format(type(chunk), tostring(uri), tostring(args and args[1]))
      function OnSetText() return saw end
    ]])
    spec.args = { "hello" }
    local child, err = loader.load_child(spec, "file:///ws", { "ignored-shared-args" })
    assert_nil(err)
    assert_equal(child.hooks.OnSetText(), "function|file:///ws|hello")
  end)

  it("isolates each child's globals from the others", function()
    local a = plugin_file([[ SHARED = "from-a"  function OnSetText() return nil end ]])
    local b = plugin_file([[
      LEAKED = SHARED
      function OnSetText() return nil end
    ]])
    loader.load_child(a)
    local child_b = loader.load_child(b)
    assert_not_nil(child_b)
    -- If sandboxes leaked, `SHARED` would have been visible to b. It is not
    -- observable from here by design; what we can assert is that neither
    -- child's assignment reached the real global table.
    assert_nil(rawget(_G, "SHARED"), "a child's global escaped into _G")
    assert_nil(rawget(_G, "LEAKED"), "a child's global escaped into _G")
  end)

  it("returns an error for a missing file rather than throwing", function()
    local child, err = loader.load_child({ path = TMP .. "/nope.lua", name = "nope" })
    assert_nil(child)
    assert_true(err:find("not found", 1, true) ~= nil, err)
  end)

  it("returns an error for a syntax error rather than throwing", function()
    local spec = plugin_file([[ function OnSetText( ]])
    local child, err = loader.load_child(spec)
    assert_nil(child)
    assert_true(err:find("failed to compile", 1, true) ~= nil, err)
  end)

  it("returns an error when a child throws at load time", function()
    local spec = plugin_file([[ error("boom at load") ]])
    local child, err = loader.load_child(spec)
    assert_nil(child)
    assert_true(err:find("boom at load", 1, true) ~= nil, err)
  end)

  it("refuses a VM table that lacks OnCompileFunctionParam", function()
    -- script/vm/compiler.lua:1537 calls interface.VM.OnCompileFunctionParam
    -- with no type check and no xpcall, so exposing a hollow VM table would
    -- crash parameter compilation for every plugin in the workspace.
    local spec = plugin_file([[ VM = {}  function OnSetText() return nil end ]])
    local child = loader.load_child(spec)
    assert_not_nil(child)
    assert_nil(child.vm, "a VM table without the hook must not be adopted")
  end)

  it("accepts a well-formed VM table", function()
    local spec = plugin_file([[
      VM = { OnCompileFunctionParam = function() return true end }
      function OnSetText() return nil end
    ]])
    local child = loader.load_child(spec)
    assert_not_nil(child.vm)
    assert_true(type(child.vm.OnCompileFunctionParam) == "function")
  end)
end)

describe("loader.load_all", function()
  it("skips children that fail and keeps the rest — in order", function()
    local good1 = plugin_file([[ function OnSetText() return nil end ]])
    local broken = { path = TMP .. "/missing.lua", name = "missing" }
    local good2 = plugin_file([[ function OnSetText() return nil end ]])

    local children = loader.load_all({ good1, broken, good2 })
    assert_equal(#children, 2, "one bad child must not stop the others")
    assert_equal(children[1].name, good1.name)
    assert_equal(children[2].name, good2.name)
  end)

  it("loads a child that exposes no hooks at all without failing", function()
    -- This is the case that kills LuaLS's own dispatch: a plugin without
    -- OnSetText aborts the event for everybody. Here it is simply inert.
    local hookless = plugin_file([[ local M = {} return M ]])
    local real = plugin_file([[ function OnSetText() return { } end ]])
    local children = loader.load_all({ hookless, real })
    assert_equal(#children, 2)
    assert_nil(children[1].hooks.OnSetText)
    assert_true(type(children[2].hooks.OnSetText) == "function")
  end)

  it("adds each child's directory to package.path so it can require siblings", function()
    local dir = TMP .. "/withdeps"
    os.execute("mkdir -p " .. dir)
    local fh = assert(io.open(dir .. "/helper.lua", "wb"))
    fh:write("return { value = 'from-helper' }")
    fh:close()
    fh = assert(io.open(dir .. "/main.lua", "wb"))
    fh:write([[
      local helper = require("helper")
      function OnSetText() return { { start = 1, finish = 0, text = helper.value } } end
    ]])
    fh:close()

    local child, err = loader.load_child({ path = dir .. "/main.lua", name = "withdeps" })
    assert_nil(err)
    local diffs = child.hooks.OnSetText("uri", "x")
    assert_equal(diffs[1].text, "from-helper")
  end)
end)
