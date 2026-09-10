-- Pure diff-merge logic. No LuaLS, no I/O.
--
-- `merge.apply` in these tests is a faithful re-implementation of LuaLS's own
-- `script/string-merger.lua:51-76`, so every assertion about resulting text is
-- an assertion about what the real server would produce.

local merge = require("luals_composer.merge")

--- Shorthand: a zero-width insertion of `t` before byte `pos`.
local function ins(pos, t) return { start = pos, finish = pos - 1, text = t } end
--- Shorthand: replace bytes [s,f] with `t`.
local function rep(s, f, t) return { start = s, finish = f, text = t } end

--- Assert the canonical invariant the transport promises: distinct, ascending,
--- non-overlapping spans. Under it, LuaLS's non-stable `table.sort` has exactly
--- one possible outcome.
local function assert_canonical(diffs)
  local prev
  for i, h in ipairs(diffs) do
    if prev then
      assert_true(h.start > prev.finish,
        ("hunk %d starts at %d but the previous hunk ends at %d — ranges must be disjoint and ascending")
        :format(i, h.start, prev.finish))
      assert_true(h.start ~= prev.start,
        ("hunk %d shares start offset %d with its predecessor"):format(i, h.start))
    end
    prev = h
  end
end

describe("merge.normalise", function()
  it("treats nil as no contribution", function()
    local hunks, warnings = merge.normalise(nil, "local x = 1", "quiet")
    assert_equal(#hunks, 0)
    assert_equal(#warnings, 0)
  end)

  it("treats a string identical to the input as no contribution", function()
    -- The `legacy` string-returning shape: clingy's process_text returned
    -- `text` verbatim on every early-out until v0.6.1 (it now returns
    -- insertion diffs). Without this check, every file such a plugin did not
    -- care about would still be claimed whole. "legacy_str" here is a generic
    -- stand-in for any child still in that edit mode.
    local text = "local x = 1"
    local hunks, warnings = merge.normalise(text, text, "legacy_str")
    assert_equal(#hunks, 0)
    assert_equal(#warnings, 0)
  end)

  it("converts a genuinely changed string into one whole-file hunk, and warns", function()
    local text = "local x = 1"
    local hunks, warnings = merge.normalise("local x = 2", text, "legacy_str")
    assert_equal(#hunks, 1)
    assert_equal(hunks[1].start, 1)
    assert_equal(hunks[1].finish, #text)
    assert_true(#warnings > 0, "a whole-file rewrite should be reported")
  end)

  it("drops a no-op whole-file replacement and says why", function()
    -- The exact shape hydronium-luax used to emit for a JSX-free .luax file.
    local text = "local Cfg = 1"
    local hunks, warnings = merge.normalise({ rep(1, #text, text) }, text, "hydronium-luax")
    assert_equal(#hunks, 0, "identity whole-file hunk must not survive")
    assert_true(#warnings > 0)
    assert_true(warnings[1]:find("starved", 1, true) ~= nil, "warning should explain the impact")
  end)

  it("drops malformed hunks but keeps the good ones from the same plugin", function()
    local text = "abcdef"
    local hunks, warnings = merge.normalise({
      { start = "1", finish = 2, text = "x" },
      { start = 1, finish = 2, text = 42 },
      ins(3, "ok"),
    }, text, "sloppy")
    assert_equal(#hunks, 1)
    assert_equal(hunks[1].text, "ok")
    assert_equal(#warnings, 2)
  end)

  it("drops out-of-range hunks", function()
    local text = "abcdef" -- 6 bytes
    local hunks, warnings = merge.normalise({
      rep(0, 2, "x"),   -- start below 1
      rep(1, 99, "y"),  -- finish past end of file
      ins(8, "z"),      -- start past #text + 1
    }, text, "oob")
    assert_equal(#hunks, 0)
    assert_equal(#warnings, 3)
  end)

  it("allows an insertion at exactly #text + 1 (append at end of file)", function()
    local text = "abcdef"
    local hunks = merge.normalise({ ins(#text + 1, "\n-- tail") }, text, "appender")
    assert_equal(#hunks, 1)
    assert_equal(merge.apply(text, hunks), "abcdef\n-- tail")
  end)

  it("ignores non-array fields such as hydronium-luax's vestigial diffs.text", function()
    local text = "abcdef"
    local result = { ins(1, "-- hi\n") }
    result.text = "the whole virtual document"
    local hunks = merge.normalise(result, text, "hydronium-luax")
    assert_equal(#hunks, 1)
  end)

  it("rejects non-finite, fractional, and non-integer byte offsets", function()
    local text = "abcdef"
    local hunks, warnings = merge.normalise({
      { start = 1.5, finish = 1, text = "fraction" },
      { start = math.huge, finish = math.huge, text = "infinite" },
      { start = 0 / 0, finish = 0, text = "nan" },
      ins(2, "valid"),
    }, text, "hostile")
    assert_equal(#hunks, 1)
    assert_equal(hunks[1].text, "valid")
    assert_equal(#warnings, 3)
  end)

  it("rejects sparse numeric diff arrays instead of truncating at the first hole", function()
    local result = { [1] = ins(1, "one"), [3] = ins(3, "three") }
    local hunks, warnings = merge.normalise(result, "abc", "sparse")
    assert_equal(#hunks, 0)
    assert_true(#warnings > 0)
    assert_match(table.concat(warnings, " | "), "dense")
  end)

end)

describe("merge.merge — independent contributions compose", function()
  it("keeps insertions from two different plugins at different offsets", function()
    local text = "local a = 1\nlocal b = 2\n"
    local diffs, report = merge.merge({
      { name = "p1", result = { ins(1, "---@type integer\n") } },
      { name = "p2", result = { ins(13, "---@type string\n") } },
    }, text)

    assert_canonical(diffs)
    assert_equal(#report.dropped, 0, "disjoint insertions must not conflict")
    assert_equal(merge.apply(text, diffs),
      "---@type integer\nlocal a = 1\n---@type string\nlocal b = 2\n")
  end)

  it("keeps an insertion alongside a disjoint replacement", function()
    local text = "aaaa BBBB cccc"
    local diffs = merge.merge({
      { name = "hydronium", result = { rep(6, 9, "xxxx") } },
      { name = "valua", result = { ins(1, "--!\n") } },
    }, text)

    assert_canonical(diffs)
    assert_equal(merge.apply(text, diffs), "--!\naaaa xxxx cccc")
  end)

  it("returns nil when every plugin declines the file", function()
    local diffs, report = merge.merge({
      { name = "p1", result = nil },
      { name = "p2", result = nil },
    }, "local x = 1")
    assert_nil(diffs)
    assert_equal(#report.warnings, 0)
  end)

  it("lets one plugin work while another declines — the composition bug, fixed", function()
    -- Under LuaLS's own dispatch this is exactly what breaks: the plugin that
    -- returns nil for a file it does not own overwrites the other's result.
    local text = "local Cfg = v.object({})"
    local diffs = merge.merge({
      { name = "hydronium-luax", result = nil },       -- not a .luax file
      { name = "valua", result = { ins(1, "---@type valua.BaseSchema\n") } },
    }, text)

    assert_diffs(diffs, { ins(1, "---@type valua.BaseSchema\n") })
    assert_equal(merge.apply(text, diffs), "---@type valua.BaseSchema\nlocal Cfg = v.object({})")
  end)
end)

describe("merge.merge — same-offset coalescing", function()
  it("fuses two insertions at the same byte into one deterministic hunk", function()
    -- LuaLS's mergeDiff sorts with a NON-stable table.sort keyed only on
    -- `start`, so two hunks sharing a start have unspecified order. Emitting a
    -- single fused hunk removes the ambiguity entirely.
    local text = "local x = 1"
    local diffs = merge.merge({
      { name = "first", result = { ins(1, "---@type A\n") } },
      { name = "second", result = { ins(1, "---@type B\n") } },
    }, text)

    assert_equal(#diffs, 1, "same-offset insertions must fuse into one hunk")
    assert_canonical(diffs)
    assert_equal(merge.apply(text, diffs), "---@type A\n---@type B\nlocal x = 1")
  end)

  it("orders the insertion before a replacement that starts at the same byte", function()
    -- Order matters here for correctness, not taste: if the replacement ran
    -- first, mergeDiff's `cur` would jump to finish+1 and then be dragged back
    -- to the insertion's start, re-emitting bytes.
    local text = "OLD tail"
    local diffs = merge.merge({
      { name = "replacer", result = { rep(1, 3, "NEW") } },
      { name = "inserter", result = { ins(1, "--!\n") } },
    }, text)

    assert_equal(#diffs, 1)
    assert_canonical(diffs)
    assert_equal(merge.apply(text, diffs), "--!\nNEW tail")
  end)

  it("survives the raw ordering that would corrupt under LuaLS's own sort", function()
    -- Same inputs as above, handed to mergeDiff unmerged.
    --
    -- mergeDiff sorts with `a.start < b.start`, which is not a strict weak
    -- ordering for equal starts, and table.sort is not stable — so BOTH
    -- orderings below are outcomes LuaLS is entitled to produce. Rather than
    -- depend on which one a given Lua build picks, apply each explicitly and
    -- assert they disagree. That disagreement IS the hazard; coalescing to a
    -- single hunk is what removes it.
    local text = "OLD tail"

    -- mergeDiff's loop verbatim (script/string-merger.lua:63-75), minus the sort.
    local function apply_in_order(diffs)
      local cur, buf = 1, {}
      for _, d in ipairs(diffs) do
        buf[#buf + 1] = text:sub(cur, d.start - 1)
        buf[#buf + 1] = d.text
        cur = d.finish + 1
      end
      buf[#buf + 1] = text:sub(cur)
      return table.concat(buf)
    end

    local insertion_first = apply_in_order({ ins(1, "--!\n"), rep(1, 3, "NEW") })
    local replacement_first = apply_in_order({ rep(1, 3, "NEW"), ins(1, "--!\n") })

    assert_equal(insertion_first, "--!\nNEW tail", "insertion-first happens to be correct")
    assert_equal(replacement_first, "NEW--!\nOLD tail",
      "replacement-first drags cur backward and re-emits the bytes it just replaced")
    assert_true(insertion_first ~= replacement_first,
      "two hunks sharing a start have order-dependent output — this is why they must be fused")
  end)
end)

describe("merge.merge — graceful degradation on genuine conflicts", function()
  it("drops the lower-priority hunk when two replacements overlap, and warns", function()
    local text = "0123456789"
    local diffs, report = merge.merge({
      { name = "winner", result = { rep(3, 7, "AAAAA") } },
      { name = "loser", result = { rep(5, 9, "BBBBB") } },
    }, text)

    assert_diffs(diffs, { rep(3, 7, "AAAAA") })
    assert_equal(#report.dropped, 1)
    assert_equal(report.dropped[1].owner, "loser")
    assert_warned(report, "conflict: dropped loser")
    assert_warned(report, "configured at a higher priority")
    assert_equal(report.dropped[1].conflict_kind, "overlapping-replacement")
    assert_equal(merge.apply(text, diffs), "01AAAAA789", "surviving text must stay coherent")
  end)

  it("resolves by configured priority, not by position in the file", function()
    -- The high-priority plugin's hunk starts LATER. A resolver that simply
    -- walked the file left-to-right would keep the wrong one.
    local text = "0123456789"
    local diffs, report = merge.merge({
      { name = "high", result = { rep(5, 9, "HHHHH") } },
      { name = "low", result = { rep(3, 7, "LLLLL") } },
    }, text)

    assert_diffs(diffs, { rep(5, 9, "HHHHH") })
    assert_equal(report.dropped[1].owner, "low")
  end)

  it("drops an insertion landing strictly inside a surviving replacement", function()
    local text = "0123456789"
    local diffs, report = merge.merge({
      { name = "replacer", result = { rep(3, 7, "XXXXX") } },
      { name = "inserter", result = { ins(5, "!") } },
    }, text)

    assert_diffs(diffs, { rep(3, 7, "XXXXX") })
    assert_equal(#report.dropped, 1)
    assert_equal(report.dropped[1].owner, "inserter")
    assert_equal(report.dropped[1].conflict_kind, "insertion-inside-replacement")
    assert_equal(merge.apply(text, diffs), "01XXXXX789")
  end)

  it("does not blame priority when an insertion is swallowed by a replacement", function()
    -- The losing plugin here is configured HIGHER than the winner. Priority had
    -- nothing to do with it — an insertion inside a wholesale-replaced range is
    -- simply unapplicable — and the warning must not claim otherwise.
    local text = "0123456789"
    local _, report = merge.merge({
      { name = "valua", result = { ins(5, "---@type T\n") } },   -- priority 1
      { name = "legacy_str", result = { rep(1, 10, "REWRITTEN") } }, -- priority 2
    }, text)

    assert_equal(report.dropped[1].owner, "valua")
    assert_warned(report, "falls inside the range [1,10] that legacy_str replaces wholesale")
    assert_warned(report, "valua will contribute nothing to this file")
    for _, w in ipairs(report.warnings) do
      assert_false(w:find("higher priority", 1, true) ~= nil,
        "must not blame priority for an unapplicable insertion: " .. w)
    end
  end)

  it("keeps an insertion at the replacement's own start, and just past its end", function()
    local text = "0123456789"
    local diffs = merge.merge({
      { name = "replacer", result = { rep(3, 7, "XXXXX") } },
      { name = "edges", result = { ins(3, "<"), ins(8, ">") } },
    }, text)

    assert_canonical(diffs)
    assert_equal(merge.apply(text, diffs), "01<XXXXX>789")
  end)

  it("never loses a plugin entirely just because one of its hunks conflicts", function()
    local text = "0123456789"
    local diffs, report = merge.merge({
      { name = "high", result = { rep(1, 4, "HHHH") } },
      { name = "low", result = { rep(3, 6, "DEAD"), ins(9, "kept") } },
    }, text)

    assert_equal(#report.dropped, 1)
    assert_canonical(diffs)
    assert_equal(merge.apply(text, diffs), "HHHH4567kept89",
      "the low-priority plugin's non-conflicting insertion must survive")
  end)

  it("a whole-file rewrite starves the others — and says so rather than corrupting", function()
    local text = "local x = 1"
    local diffs, report = merge.merge({
      { name = "valua", result = { ins(1, "---@type T\n") } },
      { name = "legacy_str", result = "local x = 2" },  -- string return, whole file
    }, text)

    assert_canonical(diffs)
    assert_warned(report, "whole-file string rewrite")
    -- valua's insertion at byte 1 is at the rewrite's own start, so it is not
    -- strictly inside it and both survive; nothing is corrupted either way.
    assert_equal(merge.apply(text, diffs), "---@type T\nlocal x = 2")
  end)
end)

describe("merge.merge — regression: the hydronium-luax whole-file poison", function()
  -- This reproduces, at the diff level, the `Redefined local Cfg` corruption
  -- the design document observed with real plugins on a JSX-free .luax file.
  local text = "local v = require('valua')\nlocal Cfg = v.object({})\n"
  local identity = rep(1, #text, text)      -- what hydronium-luax used to emit
  local schema = ins(28, "---@type valua.BaseSchema\n")

  it("demonstrates the corruption when the poison hunk reaches mergeDiff", function()
    local corrupted = merge.apply(text, { identity, schema })
    assert_true(#corrupted > #text,
      "the identity hunk drags mergeDiff's cursor backward and duplicates the tail")
    local _, occurrences = corrupted:gsub("local Cfg", "")
    assert_equal(occurrences, 2, "`local Cfg` should appear twice — this is the reported bug")
  end)

  it("produces clean text once the transport has merged", function()
    local diffs, report = merge.merge({
      { name = "hydronium-luax", result = { identity } },
      { name = "valua", result = { schema } },
    }, text)

    assert_canonical(diffs)
    local merged = merge.apply(text, diffs)
    local _, occurrences = merged:gsub("local Cfg", "")
    assert_equal(occurrences, 1, "no duplication")
    assert_true(merged:find("---@type valua.BaseSchema", 1, true) ~= nil,
      "valua's annotation must survive")
    assert_warned(report, "no-op whole-file replacement")
  end)
end)

describe("merge helpers", function()
  it("classifies zero-width hunks as insertions", function()
    assert_true(merge.is_insertion(ins(5, "x")))
    assert_false(merge.is_insertion(rep(5, 5, "x")))
    assert_false(merge.is_insertion(rep(5, 9, "x")))
  end)

  it("builds canonical insertions", function()
    local h = merge.insertion(7, "hi")
    assert_equal(h.start, 7)
    assert_equal(h.finish, 6)
    assert_equal(h.text, "hi")
  end)

  it("apply matches LuaLS's mergeDiff on a plain disjoint case", function()
    local text = "abcdefghij"
    assert_equal(merge.apply(text, { rep(1, 3, "XYZ"), rep(8, 10, "QQ") }), "XYZdefgQQ")
  end)
end)
