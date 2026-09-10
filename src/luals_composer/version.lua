--[[
  luals-composer / version

  The single source of truth for this package's version at RUNTIME.

  `moonstone.toml` is the source of truth for packaging, but it is not
  reachable from an installed copy under `.moonstone/env/share/lua/...` — only
  the Lua tree is. So the version is mirrored here, and
  `tests/version_spec.lua` asserts the two never drift apart.
--]]

return {
  PACKAGE = 'moonstone/luals-composer',
  VERSION = '0.1.0',
  CONTRACT = 1,

  --- Module path of the plugin entry point, relative to a Lua tree root.
  --- Used to locate an installed transport inside `.moonstone/env`.
  ENTRY_RELPATH = 'luals_composer/init.lua',
}
