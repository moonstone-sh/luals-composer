local identity = require("luals_composer.version")

local function read(path)
  local fh = assert(io.open(path, "rb"))
  local text = fh:read("a")
  fh:close()
  return text
end

describe("package identity", function()
  it("keeps runtime identity aligned with the manifest and shipped entry", function()
    local manifest = read("moonstone.toml")
    local package_block = manifest:match("%[package%](.-)\n%[")
      or manifest:match("%[package%](.*)$")
    assert_not_nil(package_block)
    assert_equal(identity.PACKAGE, package_block:match('name%s*=%s*"([^"]+)"'))
    assert_equal(identity.VERSION, package_block:match('version%s*=%s*"([^"]+)"'))
    assert_equal(identity.CONTRACT, 1)
    local entry = io.open("src/" .. identity.ENTRY_RELPATH, "rb")
    assert_not_nil(entry, "declared LuaLS entry must be shipped")
    entry:close()
  end)
end)
