# LuaLS Composer

LuaLS Composer registers and composes language-server plugins such as Hydronium
LUAX, Valua, and Clingy. LuaLS loads one Composer entry; Composer gives each
child the original document and merges their edits in a defined order.

LuaLS's plugin dispatcher retains only the final `OnSetText` return value and
can stop dispatch when a plugin lacks a hook. Composer owns that dispatch so
plugins handling different syntax can share a workspace.

## Enrollment API

Install `moonstone/luals-composer` in the consuming project. Its runtime
dependencies include Alter and Alter JSONC for configuration edits. The LuaLS
bootstrap itself loads only Composer modules and requires neither Alter nor
the project's runtime dependencies.

Libraries expose their plugin through the public module:

```lua
local transport = require("luals_composer")
local plan, err = transport.plan({
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
assert(plan, err and err.message)
print(plan.summary)
print(plan:preview().config)
local result, commit_error = plan:commit()
assert(result, commit_error and commit_error.message)
```

`transport.enroll(options)` plans and commits in one call. Both functions return
`nil, { code, message, ... }` on failure. `plan()` and `preview()` perform no
writes. Plans expose `config`, `registry`, `changes`, `warnings`, and `changed`.
Repeated enrollment of the same descriptor leaves file bytes unchanged.

### Enrolling by name

A plugin package may instead describe itself, so a consumer supplies only a
name:

```lua
transport.enroll({ root = project_root, plugin = "valua" })
transport.enroll({ root = project_root, plugin = { name = "hydronium-luax", priority = "first" } })
```

Composer reads the named package's manifest from the root of its installed Lua
module tree — `.moonstone/env/share/lua/<abi>/<module>/luals-plugin.lua`, where
`<module>` is the package name with any `scope/` prefix dropped and `-` replaced
by `_` — and fills in the descriptor. The manifest is a Lua module returning the
descriptor table, loaded in an empty environment so it can reach no global:

```lua
return {
  name       = "valua",
  path       = "tooling/luals/plugin.lua",  -- relative to this file
  transport  = "^0.2.0",
  contract   = 1,
  text_edits = "insertions",
  args       = {},
}
```

`path` is relative to the manifest, so it describes the installed layout rather
than the package's source repository. `priority` is not read from a manifest:
ordering belongs to the consuming workspace, and no package may promote itself
above its neighbours in someone else's project.

The two modes are one code path. `path` is the discriminator — supply one and
nothing changes; omit one and the named package is asked. Any field the caller
does supply overrides the manifest, and both modes are validated by the same
`contract.validate`, so a manifest cannot smuggle in a descriptor an explicit
caller would be refused for. A name whose package ships no manifest fails with
code `plugin_undescribed` and a message naming the expected file and both
remedies; a package whose manifest is wrong fails as an ordinary bad descriptor.

`root` names the Moonstone project. Plugin paths are relative to it or absolute;
paths inside the project are stored relative. The installed runtime determines
Composer's entry path: Lua 5.4 uses `share/lua/5.4`, LuaJIT uses `share/lua/5.1`.
Enrollment reads the installed `PACKAGE`, `VERSION`, and `CONTRACT` metadata
without executing the version module. Versions must be complete SemVer strings;
constraints support exact, comparison, caret, tilde, and conjunction forms.

## Configuration ownership

Enrollment maintains the project-root `.luarc.json` and `luals-composer.json`:

```json
{
  "runtime": {
    "plugin": [".moonstone/env/share/lua/5.4/luals_composer/init.lua"],
    "pluginArgs": ["--config=luals-composer.json"]
  }
}
```

```json
{
  "version": 1,
  "package": "moonstone/luals-composer",
  "plugins": [{
    "name": "clingy",
    "path": ".moonstone/env/share/lua/5.4/clingy/luals/plugin.lua",
    "transport": "^0.2.0",
    "contract": 1,
    "text_edits": "insertions",
    "args": []
  }]
}
```

Libraries enroll a descriptor; they must not write `runtime.plugin` themselves.
Unrelated LuaLS settings and JSONC comment text survive enrollment. Alter JSONC
may move comments when rendering a changed document.

Array order is priority. New descriptors append unless enrollment receives
`priority = "first"`; `"last"` makes the default explicit. Existing descriptors
keep their position. Place LUAX before annotation plugins when it must win an
overlapping syntax replacement. `enabled = false` keeps a descriptor in the
registry without loading it. Each child receives only its own `args` array.

A `--config=path` selector resolves against the LuaLS workspace root. Child paths
resolve against the selected sidecar's directory. The selector is authoritative,
including an empty plugin array. Mixed child paths, duplicate selectors, and
conflicting environment overrides produce errors instead of selecting a source
silently. Legacy unmanaged configuration still supports direct `pluginArgs`
paths, `LUALS_COMPOSER_PLUGINS`, and conventional sidecar discovery.

Enrollment migrates direct plugins when their `pluginArgs` is empty. Nonempty
direct-plugin arguments require explicit migration into child descriptors.
Existing sidecars competing with legacy lists, differing Composer
installations, duplicate names/paths, and dotted/nested setting conflicts are
refused. Unknown migrated children receive the explicit `legacy` edit mode and
a warning. Enrolling that library later upgrades its descriptor in place.

Commit checks the files and installed identity against planning snapshots, then
writes the sidecar before activating `.luarc.json`. Each Alter write is atomic;
the pair is not. If activation fails after the first write, the structured error
reports `partial` and `written`. Existing Composer users may already observe
the new registry. A changed snapshot returns `stale_plan` and requires replanning.

## Child contract

Descriptors require `name`, `path`, `transport`, `contract = 1`, and `text_edits`:

| Mode | Allowed `OnSetText` result |
| --- | --- |
| `insertions` | `nil` or zero-width diffs (`finish == start - 1`) |
| `ranges` | `nil` or precise insertion/replacement diffs |
| `legacy` | Existing LuaLS string/diff behavior; migration compatibility only |

Offsets are integer, 1-based byte positions in the original document. Whole
document strings and whole document replacements violate the managed contract.
A violating child's contribution is dropped and logged; other children continue.
Original text is never replaced between children. Conflicting hunks favor the
earlier child; same-position insertions are coalesced deterministically.

`OnTransformAst` chains in child order, `ResolveRequire` uses the first answer,
and `VM.OnCompileFunctionParam` forwards to children that implement it. Child
errors are contained and logged. The loader isolates hook globals but shares
`package.loaded`, matching LuaLS's loading model.

## Source and checks

- `src/luals_composer.lua`: public facade; no LuaLS hooks or eager Alter load.
- `src/luals_composer/enrollment.lua`: planning, migration, Alter commits.
- `src/luals_composer/manifest.lua`: plugin self-description lookup by name.
- `src/luals_composer/init.lua`: executable LuaLS entry.
- `config.lua`, `contract.lua`, `loader.lua`, `transport.lua`, `merge.lua`:
  configuration, validation, loading, dispatch, and diff composition.
- `tests/`: unit tests and real LuaLS composition fixtures.

Run `moon run test`, `moon run test-e2e`, `moon run test-e2e-named`, and
`moon run package`. Packaging must retain both the public `luals_composer.lua` file and executable
`luals_composer/init.lua` file. See [REGISTRY_README.md](REGISTRY_README.md) for
the installable package instructions.
