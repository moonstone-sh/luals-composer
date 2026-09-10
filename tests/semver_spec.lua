local semver = require("luals_composer.semver")

describe("semver.parse", function()
  it("accepts complete SemVer versions and build metadata", function()
    local stable = semver.parse("1.2.3")
    assert_same(stable, { major = 1, minor = 2, patch = 3 })

    local pre = semver.parse("0.1.0-rc.2+build.9")
    assert_equal(pre.major, 0)
    assert_equal(pre.minor, 1)
    assert_equal(pre.patch, 0)
    assert_equal(pre.prerelease, "rc.2")
  end)

  it("rejects partial, malformed, and trailing versions", function()
    for _, value in ipairs({
      "1", "1.2", "1.2.3wat", "1.2.3-", "1.2.3+", "1.2.3+ok!",
      "01.2.3", "1.02.3", "1.2.03", "1.2.3-rc..1", "1.2.3-01",
      "1.2.3+build..1", "", "v", "v1.2.3 trailing",
    }) do
      assert_nil(semver.parse(value), "should reject " .. string.format("%q", value))
    end
  end)
end)

describe("semver ordering and constraints", function()
  it("implements SemVer prerelease precedence", function()
    local ordered = {
      "1.0.0-alpha",
      "1.0.0-alpha.1",
      "1.0.0-alpha.beta",
      "1.0.0-beta",
      "1.0.0-beta.2",
      "1.0.0-beta.11",
      "1.0.0-rc.1",
      "1.0.0",
    }
    for i = 1, #ordered - 1 do
      assert_equal(semver.compare(ordered[i], ordered[i + 1]), -1,
        ordered[i] .. " should sort before " .. ordered[i + 1])
    end
    assert_equal(semver.compare("1.2.3+one", "1.2.3+two"), 0)
  end)

  it("supports exact, caret, tilde, and conjunctive constraints", function()
    assert_true(semver.satisfies("1.4.2", "^1.2.3"))
    assert_false(semver.satisfies("2.0.0", "^1.2.3"))
    assert_true(semver.satisfies("0.1.9", "^0.1.2"))
    assert_false(semver.satisfies("0.2.0", "^0.1.2"))
    assert_true(semver.satisfies("1.2.9", "~1.2.3"))
    assert_false(semver.satisfies("1.3.0", "~1.2.3"))
    assert_true(semver.satisfies("1.5.0", ">=1.0.0, <2.0.0"))
  end)

  it("returns a structured failure signal for malformed inputs", function()
    local ok, err = semver.satisfies("1.2", "^1.0.0")
    assert_nil(ok)
    assert_match(err, "unparseable")

    ok, err = semver.satisfies("1.2.3", "^1.0")
    assert_nil(ok)
    assert_match(err, "unparseable")

    ok, err = semver.satisfies("1.2.3", "=>1.0.0")
    assert_nil(ok)
    assert_not_nil(err)
  end)
end)
