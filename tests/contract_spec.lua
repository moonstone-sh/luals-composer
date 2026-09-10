local contract = require("luals_composer.contract")

local function ins(pos, text)
  return { start = pos, finish = pos - 1, text = text }
end

local function rep(first, last, text)
  return { start = first, finish = last, text = text }
end

describe("runtime edit contract", function()
  it("accepts nil and dense original-document insertion diffs", function()
    assert_true(contract.check_edits(nil, "abc", "insertions"))
    assert_true(contract.check_edits({ ins(1, "--!\n"), ins(4, "-- tail") },
      "abc", "insertions"))
  end)

  it("rejects strings for managed insertion and range plugins", function()
    for _, mode in ipairs({ "insertions", "ranges" }) do
      local ok, err = contract.check_edits("rewritten", "abc", mode)
      assert_nil(ok)
      assert_match(err, "diff")
    end
  end)

  it("rejects sparse arrays", function()
    local result = { [1] = ins(1, "a"), [3] = ins(3, "b") }
    local ok, err = contract.check_edits(result, "abc", "insertions")
    assert_nil(ok)
    assert_match(err, "sparse")
  end)

  it("requires finite integer byte offsets and canonical bounds", function()
    for _, hunk in ipairs({
      { start = 1.5, finish = 0, text = "x" },
      { start = math.huge, finish = 0, text = "x" },
      { start = 0 / 0, finish = 0, text = "x" },
      { start = 0, finish = -1, text = "x" },
      { start = 5, finish = 4, text = "x" },
      { start = 2, finish = 9, text = "x" },
      { start = 1, finish = 0, text = 9 },
    }) do
      local ok, err = contract.check_edits({ hunk }, "abc", "ranges")
      assert_nil(ok)
      assert_not_nil(err)
    end
  end)

  it("forbids consuming ranges in insertion-only mode", function()
    local ok, err = contract.check_edits({ rep(2, 2, "x") }, "abc", "insertions")
    assert_nil(ok)
    assert_match(err, "insertion")
  end)

  it("allows bounded replacements in range mode but rejects whole-document claims", function()
    assert_true(contract.check_edits({ rep(2, 2, "x") }, "abc", "ranges"))
    local ok, err = contract.check_edits({ rep(1, 3, "xyz") }, "abc", "ranges")
    assert_nil(ok)
    assert_match(err, "whole%-document")
  end)

  it("allows legacy results only for migrated descriptors", function()
    assert_true(contract.check_edits("rewritten", "abc", "legacy"))
    assert_true(contract.check_edits(42, "abc", "legacy"))
  end)
end)
