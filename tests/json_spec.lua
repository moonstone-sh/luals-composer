local json = require("luals_composer.json")

describe("json.decode", function()
  it("decodes objects, arrays and scalars", function()
    local v = json.decode('{"a":1,"b":[true,false,"x"],"c":-2.5}')
    assert_equal(v.a, 1)
    assert_equal(v.b[1], true)
    assert_equal(v.b[2], false)
    assert_equal(v.b[3], "x")
    assert_equal(v.c, -2.5)
  end)

  it("decodes escapes", function()
    local v = json.decode('{"s":"a\\nb\\t\\"c\\"\\\\d\\u0041"}')
    assert_equal(v.s, 'a\nb\t"c"\\dA')
  end)

  it("accepts line and block comments, like .luarc.json does", function()
    local v = json.decode([[
      {
        // the plugin list
        "plugins": [
          "a.lua", /* inline */ "b.lua"
        ]
      }
    ]])
    assert_equal(#v.plugins, 2)
    assert_equal(v.plugins[1], "a.lua")
    assert_equal(v.plugins[2], "b.lua")
  end)

  it("accepts trailing commas", function()
    local v = json.decode('{"plugins":["a.lua","b.lua",],}')
    assert_equal(#v.plugins, 2)
  end)

  it("reports an error rather than throwing", function()
    local v, err = json.decode('{"a":}')
    assert_nil(v)
    assert_true(type(err) == "string" and #err > 0, "expected an error message")
  end)

  it("rejects trailing content", function()
    local v, err = json.decode('{"a":1} garbage')
    assert_nil(v)
    assert_true(err:find("trailing", 1, true) ~= nil, "got: " .. tostring(err))
  end)
end)
