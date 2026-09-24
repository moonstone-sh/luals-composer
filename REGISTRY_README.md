# LuaLS Composer

Compose Hydronium LUAX, Valua, Clingy, and other LuaLS plugins through one
registered entry point.

```sh
moon add moonstone/luals-composer
```

Libraries register their installed plugin with the wrapper:

```lua
local transport = require("luals_composer")
local result, err = transport.enroll({
  root = "/absolute/path/to/project",
  plugin = {
    name = "clingy",
    path = ".moonstone/env/share/lua/5.4/clingy/luals/plugin.lua",
    transport = "^0.2.0",
    contract = 1,
    text_edits = "insertions",
    args = {},
  },
})
assert(result, err and err.message)
```

The plugin must already be installed. Use its actual Lua ABI directory: `5.4`
for Lua 5.4, `5.1` for LuaJIT. The wrapper verifies the installed Composer's
identity and version, preserves existing children and unrelated LuaLS settings,
and safely migrates unambiguous direct-plugin configurations.

It produces `.luarc.json` with one Composer entry and
`runtime.pluginArgs = ["--config=luals-composer.json"]`. The named child
descriptors live in `luals-composer.json`, in priority order. Each child receives
only its own arguments. Set `priority = "first"` when initially enrolling LUAX
if its syntax edits must win overlaps; subsequent enrollments preserve order.

Use `transport.plan(options)` to inspect `plan.summary`, `plan.changes`, and
`plan.warnings`; `plan:preview()` returns rendered `config` and `sidecar` text.
`plan:commit()` applies it. Planning writes nothing, repeated enrollment is
idempotent, and concurrent file changes return `stale_plan`. The sidecar and
LuaLS activation are two atomic file writes, not one atomic transaction; an
activation failure reports any completed write in the structured error.

New descriptors require `contract = 1` and `text_edits = "insertions"` for
annotation-only plugins or `"ranges"` for syntax plugins. Return `nil` or precise
diffs with integer byte offsets into the original document. Whole-file rewrites
violate the contract. Composer rejects incompatible descriptors and drops
invalid contributions while keeping other children running.

The LuaLS bootstrap has no external dependencies. Enrollment uses Alter and
Alter JSONC, included as package dependencies. See the repository README for
migration rules, error behavior, and the complete child contract.
