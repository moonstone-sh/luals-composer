describe("public facade", function()
  it("can be required without installing LuaLS hooks into the process", function()
    local before = {
      OnSetText = rawget(_G, "OnSetText"),
      OnTransformAst = rawget(_G, "OnTransformAst"),
      ResolveRequire = rawget(_G, "ResolveRequire"),
      VM = rawget(_G, "VM"),
    }

    package.loaded["luals_composer"] = nil
    local transport = require("luals_composer")

    assert_true(type(transport.plan) == "function")
    assert_true(type(transport.enroll) == "function")
    assert_equal(rawget(_G, "OnSetText"), before.OnSetText)
    assert_equal(rawget(_G, "OnTransformAst"), before.OnTransformAst)
    assert_equal(rawget(_G, "ResolveRequire"), before.ResolveRequire)
    assert_equal(rawget(_G, "VM"), before.VM)
  end)
end)
