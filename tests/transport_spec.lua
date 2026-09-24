-- End-to-end behaviour of the transport over real (small) child plugins.
--
-- These children are written to disk and loaded through the real loader, so
-- what is under test is the whole path a LuaLS request takes — config through
-- sandboxed load through fan-out through merge — minus only the server itself.

local Transport = require("luals_composer.transport")
local merge = require("luals_composer.merge")
local log = require("luals_composer.log")

log.to_stderr = false

local TMP = os.tmpname()
os.remove(TMP)
os.execute("mkdir -p " .. TMP)

local counter = 0
local function child(source)
  counter = counter + 1
  local path = ("%s/c%d.lua"):format(TMP, counter)
  local fh = assert(io.open(path, "wb"))
  fh:write(source)
  fh:close()
  return { path = path, name = "c" .. counter }
end

local function transport_over(specs)
  return Transport.new({ plugins = specs, source = "test" })
end

local function managed(spec, mode, args)
  spec.transport = "^0.2.0"
  spec.contract = 1
  spec.text_edits = mode or "insertions"
  spec.args = args or {}
  return spec
end

--- A child that inserts `annotation` at byte 1, but only for URIs matching
--- `pattern` — the shape every well-behaved plugin in this ecosystem has.
local function selective_inserter(pattern, annotation)
  return child(([[
    function OnSetText(uri, text)
      if not uri:match(%q) then return nil end
      return { { start = 1, finish = 0, text = %q } }
    end
  ]]):format(pattern, annotation))
end

describe("transport OnSetText — the composition bug, fixed", function()
  it("runs both plugins on a file only one of them claims", function()
    -- Under LuaLS's plugin.dispatch the second plugin's nil would overwrite the
    -- first plugin's diff. This is the core regression.
    local t = transport_over({
      selective_inserter("%.luax$", "--[[luax]]"),
      selective_inserter("%.lua$", "--[[valua]]"),
    })

    local diffs = t:OnSetText("file:///ws/App.luax", "local x = 1")
    assert_diffs(diffs, { { start = 1, finish = 0, text = "--[[luax]]" } })

    local diffs2 = t:OnSetText("file:///ws/plain.lua", "local x = 1")
    assert_diffs(diffs2, { { start = 1, finish = 0, text = "--[[valua]]" } })
  end)

  it("applies both plugins to a file they both claim", function()
    local t = transport_over({
      selective_inserter("%.luax$", "--[[luax]]"),
      child([==[
        function OnSetText(uri, text)
          return { { start = 7, finish = 6, text = "--[[valua]]" } }
        end
      ]==]),
    })

    local text = "local Schema = 1"
    local diffs = t:OnSetText("file:///ws/App.luax", text)
    assert_equal(merge.apply(text, diffs), "--[[luax]]local --[[valua]]Schema = 1")
  end)

  it("scales past two plugins", function()
    local t = transport_over({
      selective_inserter("%.", "--[[a]]"),
      child([==[ function OnSetText(uri, text) return { { start = 2, finish = 1, text = "--[[b]]" } } end ]==]),
      child([==[ function OnSetText(uri, text) return { { start = 3, finish = 2, text = "--[[c]]" } } end ]==]),
    })

    local text = "xyz"
    local diffs = t:OnSetText("file:///ws/f.lua", text)
    assert_equal(#diffs, 3)
    assert_equal(merge.apply(text, diffs), "--[[a]]x--[[b]]y--[[c]]z")
  end)

  it("returns nil when nobody claims the file", function()
    local t = transport_over({
      selective_inserter("%.luax$", "--[[luax]]"),
      selective_inserter("%.tl$", "--[[teal]]"),
    })
    assert_nil(t:OnSetText("file:///ws/plain.lua", "local x = 1"))
  end)
end)

describe("transport OnSetText — containment", function()
  it("a child that throws does not take down the others", function()
    local t = transport_over({
      child([[ function OnSetText(uri, text) error("child exploded") end ]]),
      selective_inserter("%.", "--[[survivor]]"),
    })

    local diffs = t:OnSetText("file:///ws/f.lua", "local x = 1")
    assert_diffs(diffs, { { start = 1, finish = 0, text = "--[[survivor]]" } })
  end)

  it("a child with no OnSetText at all does not abort the event", function()
    -- This is failure mode (A) from script/plugin.lua:34 — the one that made
    -- adding an unrelated plugin silently disable text rewriting entirely.
    local t = transport_over({
      child([[ VM = { OnCompileFunctionParam = function() return false end } ]]),
      selective_inserter("%.", "--[[survivor]]"),
    })

    local diffs = t:OnSetText("file:///ws/f.lua", "local x = 1")
    assert_diffs(diffs, { { start = 1, finish = 0, text = "--[[survivor]]" } })
  end)

  it("a child returning garbage is ignored, not fatal", function()
    local t = transport_over({
      child([[ function OnSetText(uri, text) return 42 end ]]),
      selective_inserter("%.", "--[[survivor]]"),
    })
    local diffs = t:OnSetText("file:///ws/f.lua", "local x = 1")
    assert_diffs(diffs, { { start = 1, finish = 0, text = "--[[survivor]]" } })
  end)

  it("logs an overlap once per file rather than on every keystroke", function()
    log.reset()
    local t = transport_over({
      child([[ function OnSetText(uri, text) return { { start = 1, finish = 5, text = "AAAAA" } } end ]]),
      child([[ function OnSetText(uri, text) return { { start = 3, finish = 8, text = "BBBBBB" } } end ]]),
    })

    for _ = 1, 5 do t:OnSetText("file:///ws/f.lua", "0123456789") end

    local conflicts = 0
    for _, r in ipairs(log.records) do
      if r.message:find("conflict: dropped", 1, true) then conflicts = conflicts + 1 end
    end
    assert_equal(conflicts, 1, "the same conflict should be reported once, not five times")
  end)

  it("still reports the conflict for a different file", function()
    log.reset()
    local t = transport_over({
      child([[ function OnSetText(uri, text) return { { start = 1, finish = 5, text = "AAAAA" } } end ]]),
      child([[ function OnSetText(uri, text) return { { start = 3, finish = 8, text = "BBBBBB" } } end ]]),
    })
    t:OnSetText("file:///ws/a.lua", "0123456789")
    t:OnSetText("file:///ws/b.lua", "0123456789")

    local conflicts = 0
    for _, r in ipairs(log.records) do
      if r.message:find("conflict: dropped", 1, true) then conflicts = conflicts + 1 end
    end
    assert_equal(conflicts, 2)
  end)

  it("drops a replacement from an insertion-only child but keeps siblings", function()
    log.reset()
    local t = transport_over({
      managed(child([[ function OnSetText() return { { start = 1, finish = 1, text = "x" } } end ]]),
        "insertions"),
      managed(selective_inserter("%.", "--[[survivor]]"), "insertions"),
    })
    local diffs = t:OnSetText("file:///ws/f.lua", "abc")
    assert_diffs(diffs, { { start = 1, finish = 0, text = "--[[survivor]]" } })
    local messages = {}
    for _, record in ipairs(log.records) do messages[#messages + 1] = record.message end
    assert_match(table.concat(messages, " | "), "insertion")
  end)

  it("allows a bounded replacement from a range-aware child", function()
    local t = transport_over({
      managed(child([[ function OnSetText() return { { start = 2, finish = 2, text = "X" } } end ]]),
        "ranges"),
    })
    local diffs = t:OnSetText("file:///ws/f.lua", "abc")
    assert_equal(merge.apply("abc", diffs), "aXc")
  end)

  it("passes each child its own descriptor args", function()
    local t = transport_over({
      managed(child([[
        local _, _, args = ...
        local label = args[1]
        function OnSetText() return { { start = 1, finish = 0, text = label } } end
      ]]), "insertions", { "first" }),
      managed(child([[
        local _, _, args = ...
        local label = args[1]
        function OnSetText() return { { start = 2, finish = 1, text = label } } end
      ]]), "insertions", { "second" }),
    })
    local diffs = t:OnSetText("file:///ws/f.lua", "ab")
    assert_equal(merge.apply("ab", diffs), "firstasecondb")
  end)
end)

describe("transport ResolveRequire", function()
  it("takes the first child that resolves", function()
    local t = transport_over({
      child([[ function ResolveRequire(uri, name) return nil end ]]),
      child([[ function ResolveRequire(uri, name) return "file:///ws/" .. name .. ".luax" end ]]),
      child([[ function ResolveRequire(uri, name) return "file:///never" end ]]),
    })
    assert_equal(t:ResolveRequire("file:///ws/a.lua", "Button"), "file:///ws/Button.luax")
  end)

  it("returns nil when nobody resolves", function()
    local t = transport_over({ child([[ function ResolveRequire() return nil end ]]) })
    assert_nil(t:ResolveRequire("file:///ws/a.lua", "Button"))
  end)

  it("survives a child that throws", function()
    local t = transport_over({
      child([[ function ResolveRequire() error("nope") end ]]),
      child([[ function ResolveRequire(uri, name) return "file:///ok" end ]]),
    })
    assert_equal(t:ResolveRequire("file:///ws/a.lua", "Button"), "file:///ok")
  end)
end)

describe("transport OnTransformAst", function()
  it("chains the AST through every child", function()
    local t = transport_over({
      child([[ function OnTransformAst(uri, ast) ast.seen = (ast.seen or "") .. "a" return ast end ]]),
      child([[ function OnTransformAst(uri, ast) ast.seen = (ast.seen or "") .. "b" return ast end ]]),
    })
    local ast = t:OnTransformAst("file:///ws/a.lua", {})
    assert_equal(ast.seen, "ab")
  end)

  it("treats a nil return as no change, not as discarding the tree", function()
    local t = transport_over({
      child([[ function OnTransformAst(uri, ast) return nil end ]]),
      child([[ function OnTransformAst(uri, ast) ast.seen = "b" return ast end ]]),
    })
    local ast = t:OnTransformAst("file:///ws/a.lua", {})
    assert_equal(ast.seen, "b")
  end)
end)

describe("transport VM.OnCompileFunctionParam", function()
  it("is absent entirely when no child provides it", function()
    local t = transport_over({ selective_inserter("%.", "x") })
    assert_nil(t:build_vm(), "exposing a hollow VM table would crash LuaLS's param compiler")
  end)

  it("gives every provider a chance until one claims the parameter", function()
    local t = transport_over({
      child([[ VM = { OnCompileFunctionParam = function(n, f, p) return false end } ]]),
      child([[ VM = { OnCompileFunctionParam = function(n, f, p) return true end } ]]),
    })
    local vm = t:build_vm()
    assert_not_nil(vm)
    assert_equal(vm.OnCompileFunctionParam(nil, nil, nil), true)
  end)

  it("continues past a provider that throws", function()
    local t = transport_over({
      child([[ VM = { OnCompileFunctionParam = function() error("bang") end } ]]),
      child([[ VM = { OnCompileFunctionParam = function() return true end } ]]),
    })
    assert_equal(t:build_vm().OnCompileFunctionParam(nil, nil, nil), true)
  end)

  it("reports no claim when every provider declines", function()
    local t = transport_over({
      child([[ VM = { OnCompileFunctionParam = function() return false end } ]]),
    })
    assert_equal(t:build_vm().OnCompileFunctionParam(nil, nil, nil), false)
  end)
end)

describe("transport:describe", function()
  it("names what got composed", function()
    local t = transport_over({ selective_inserter("%.", "a"), selective_inserter("%.", "b") })
    local d = t:describe()
    assert_true(d:find("composing 2 plugin", 1, true) ~= nil, d)
  end)

  it("says so when nothing is configured", function()
    local t = transport_over({})
    assert_true(t:describe():find("no child plugins", 1, true) ~= nil)
  end)
end)

describe("real ecosystem composition", function()
  it("composes the actual Valua and Clingy insertion plugins", function()
    local valua = "../valua/src/valua/tooling/luals/plugin.lua"
    local clingy = "../clingy/luals/plugin.lua"
    local probe = io.open(valua, "rb")
    if not probe then return end
    probe:close()
    probe = io.open(clingy, "rb")
    if not probe then return end
    probe:close()

    package.path = "../valua/src/?.lua;../valua/src/?/init.lua;" .. package.path
    local t = transport_over({
      managed({ name = "valua", path = valua }, "insertions"),
      managed({ name = "clingy", path = clingy }, "insertions"),
    })
    local text = [[
local c = require("clingy")
local v = require("valua")
local Schema = v.object({ name = v.string() })
return c.create({
  name = "x",
  root = c.node({
    c.arg({ key = "name", schema = v.string() }),
    c.run(function(ctx) return ctx.args.name end),
  }),
})
]]
    local diffs = t:OnSetText("file:///tmp/transport-real-cli.lua", text)
    assert_not_nil(diffs)
    assert_equal(#diffs, 2)
    local composed = merge.apply(text, diffs)
    assert_true(composed:find("---@class tmp.transport_real_cli.Schema", 1, true) ~= nil)
    assert_true(composed:find("---@cast ctx clingy.Context", 1, true) ~= nil)
  end)
end)
