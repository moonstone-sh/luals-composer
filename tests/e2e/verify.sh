#!/usr/bin/env bash
# End-to-end verification of luals-composer against a REAL headless
# lua-language-server. Builds throwaway workspaces under $OUT and drives each
# with a real LSP client (initialize -> didOpen -> hover/completion/diagnostics).
#
# Nothing here is mocked. If this script prints the expected output, the
# transport genuinely works inside the real server.
#
#   usage: bash tests/e2e/verify.sh [workbench-root]
#
# Requires: python3, and lua-language-server installed via Mason at
#   ~/.local/share/nvim/mason/packages/lua-language-server/
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${1:-$HOME/Workbench/user}"
OUT="${OUT:-/tmp/luals-composer-e2e}"

LT="$W/luals-composer/src/luals_composer/init.lua"
HYD="$W/hydronium/luax/src/hydronium_luax/luals/init.lua"
VAL="$W/valua/src/valua/tooling/luals/plugin.lua"
CLI="$W/clingy/luals/plugin.lua"

for f in "$LT" "$HYD" "$VAL" "$CLI"; do
  [ -f "$f" ] || { echo "MISSING: $f"; exit 1; }
done

rm -rf "$OUT"; mkdir -p "$OUT"/{ws-2plug,ws-2plug-direct,ws-3plug,ws-overlap}

# A file exercising BOTH plugins at once: real JSX and a real valua schema.
cat > "$OUT/App.luax" <<'EOF'
local d = require("hydronium.dom")
local v = require("valua")

local FormSchema = v.object({
  email = v.string(),
  age = v.integer(),
})

local function App()
  return <d.button onClick={submit}>Send</d.button>
end

local _probe = d.b

return App
EOF
for ws in ws-2plug ws-2plug-direct ws-3plug; do cp "$OUT/App.luax" "$OUT/$ws/App.luax"; done

LIBS="\"$W/hydronium/luax/src\",\"$W/hydronium/luax/types\",\"$W/valua/src\""

# 1. transport, 2 plugins, configured via Lua.runtime.pluginArgs
cat > "$OUT/ws-2plug/.luarc.json" <<EOF
{ "runtime": { "version": "LuaJIT", "path": ["?.lua","?/init.lua","?.luax"],
    "plugin": "$LT", "pluginArgs": ["$HYD", "$VAL"] },
  "workspace": { "library": [$LIBS], "checkThirdParty": false, "useGitIgnore": false },
  "files.associations": { "*.luax": "lua" } }
EOF

# 2. control: both plugins listed directly. Expected to FAIL (last plugin wins).
cat > "$OUT/ws-2plug-direct/.luarc.json" <<EOF
{ "runtime": { "version": "LuaJIT", "path": ["?.lua","?/init.lua","?.luax"],
    "plugin": ["$HYD", "$VAL"] },
  "workspace": { "library": [$LIBS], "checkThirdParty": false, "useGitIgnore": false },
  "files.associations": { "*.luax": "lua" } }
EOF

# 3. transport, 3 plugins, configured via the luals-composer.json sidecar
cat > "$OUT/ws-3plug/.luarc.json" <<EOF
{ "runtime": { "version": "LuaJIT", "path": ["?.lua","?/init.lua","?.luax"],
    "plugin": ["$LT"], "pluginArgs": ["--config=luals-composer.json"] },
  "workspace": { "library": [$LIBS,"$W/clingy/luals/library"], "checkThirdParty": false, "useGitIgnore": false },
  "files.associations": { "*.luax": "lua" } }
EOF
cat > "$OUT/ws-3plug/luals-composer.json" <<EOF
{
  "version": 1,
  "package": "moonstone/luals-composer",
  // hydronium-luax first: it owns whole regions of .luax and must win conflicts
  "plugins": [
    { "path": "$HYD", "name": "hydronium-luax", "transport": "^0.2.0",
      "contract": 1, "text_edits": "ranges", "args": [] },
    { "path": "$VAL", "name": "valua", "transport": "^0.2.0",
      "contract": 1, "text_edits": "insertions", "args": [] },
    { "path": "$CLI", "name": "clingy", "transport": "^0.2.0",
      "contract": 1, "text_edits": "insertions", "args": [] }
  ]
}
EOF
# A real clingy CLI written against the CURRENT clingy API (v0.6.1).
#
# `c.root(...)` was DELETED by clingy commit 62a91a7 ("feat!: simplify command
# routing"); `c.create` now takes the root grammar as the named field
# `root = c.node({...})`. Verified against the real source: `c.root` is absent
# from `src/clingy/dsl.lua` and `src/clingy/init.lua`, and
# `luals/library/clingy.lua:222` declares `config` as `{ root: clingy.CommandNode, ... }`.
# The old form is now a hard runtime error ("attempt to call a nil value
# (field 'root')") and LuaLS flags it against clingy's own declared library,
# which would pollute this run's diagnostics with a fixture bug.
cat > "$OUT/ws-3plug/cli.lua" <<'EOF'
local c = require("clingy")
local v = require("valua")

local ArgSchema = v.object({
  name = v.string(),
})

local CLI = c.create({
  name = "hello",
  version = "0.1.0",
  root = c.node({
    c.flag({ key = "shout", aliases = { "--shout" } }),
    c.arg({ key = "name", schema = v.string() }),
    c.run(function(ctx)
      return ctx.args.name
    end),
  }),
})

return CLI
EOF

# 4. deliberate overlap: A and B replace intersecting ranges, C inserts disjointly.
cat > "$OUT/ws-overlap/plugA.lua" <<'EOF'
function OnSetText(uri, text)
  if not uri:match("target%.lua$") then return nil end
  local s = text:find("AAAAAAAAA", 1, true)
  if not s then return nil end
  return { { start = s, finish = s + 8, text = "from_A___" } }
end
EOF
cat > "$OUT/ws-overlap/plugB.lua" <<'EOF'
function OnSetText(uri, text)
  if not uri:match("target%.lua$") then return nil end
  local s = text:find("AAAAAAAAA", 1, true)
  if not s then return nil end
  return { { start = s + 4, finish = s + 12, text = "_from_B__" } }
end
EOF
cat > "$OUT/ws-overlap/plugC.lua" <<'EOF'
function OnSetText(uri, text)
  if not uri:match("target%.lua$") then return nil end
  return { { start = 1, finish = 0, text = "---@type integer\n" } }
end
EOF
cat > "$OUT/ws-overlap/target.lua" <<'EOF'
local AAAAAAAAA_tail = 1
return AAAAAAAAA_tail
EOF
cat > "$OUT/ws-overlap/.luarc.json" <<EOF
{ "runtime": { "version": "Lua 5.4", "plugin": "$LT",
    "pluginArgs": ["$OUT/ws-overlap/plugA.lua","$OUT/ws-overlap/plugB.lua","$OUT/ws-overlap/plugC.lua"] },
  "workspace": { "checkThirdParty": false, "useGitIgnore": false } }
EOF

LUAX_SPEC='{"hovers":[[3,8,"FormSchema"],[9,14,"d.button"]],"completions":[[12,18,"d.b"]]}'

echo "=========== CONTROL: plugins listed directly — EXPECTED TO FAIL ==========="
echo "expect: valua alive, hydronium DEAD (JSX syntax errors)"
python3 "$HERE/drive.py" "$OUT/ws-2plug-direct" "$OUT/ws-2plug-direct/App.luax" "$LUAX_SPEC"

echo; echo "=========== 2-PLUGIN via pluginArgs — EXPECTED TO PASS ==========="
echo "expect: FormSchema typed per-file, and NO JSX syntax errors"
python3 "$HERE/drive.py" "$OUT/ws-2plug" "$OUT/ws-2plug/App.luax" "$LUAX_SPEC"

echo; echo "=========== 3-PLUGIN via sidecar, App.luax — EXPECTED TO PASS ==========="
echo "expect: identical to the 2-plugin case; adding clingy breaks nothing"
python3 "$HERE/drive.py" "$OUT/ws-3plug" "$OUT/ws-3plug/App.luax" "$LUAX_SPEC"

echo; echo "=========== 3-PLUGIN via sidecar, cli.lua — clingy AND valua BOTH alive ==========="
echo "expect: two disjoint zero-width insertions compose, so BOTH plugins land:"
echo "        ArgSchema keeps its per-file synthesized class"
echo "        (valua.BaseSchema<ws_3plug.cli.ArgSchema, ...>, NOT the degraded"
echo "        <table,table>), and clingy's ---@cast lands on ctx."
echo
echo "        READ THE COMPLETION, NOT THE HOVER. The hover probe sits on the"
echo "        parameter's own declaration site — before the injected cast, which"
echo "        clingy places just after the closing ')' — so it correctly still"
echo "        reports the DECLARED library type clingy.Context<table<string,any>>."
echo "        The completion probe sits on the NEXT line, after the cast, and"
echo "        must list 'name, shout'. A table<string,any> has no known keys, so"
echo "        those two names can ONLY come from the injected"
echo "        clingy.Context<{name: string, shout: boolean}> — and they are read"
echo "        off THIS file's own c.arg/c.flag declarations, so they cannot have"
echo "        come from clingy's declared library on workspace.library either."
echo "        That completion is the proof that clingy's OnSetText ran."
echo "        No conflict warnings should appear in the log for this file."
python3 "$HERE/drive.py" "$OUT/ws-3plug" "$OUT/ws-3plug/cli.lua" \
  '{"hovers":[[13,20,"ctx"],[3,8,"ArgSchema"]],"completions":[[14,22,"ctx.args."]]}'

echo; echo "=========== OVERLAP: graceful degradation — EXPECTED TO PASS ==========="
echo "expect: plugA wins, plugB dropped with ONE warning, no corruption"
python3 "$HERE/drive.py" "$OUT/ws-overlap" "$OUT/ws-overlap/target.lua" \
  '{"hovers":[[0,10,"line1 ident"]]}'

echo; echo "=========== transport messages from the LuaLS log ==========="
LOG="$HOME/.local/share/nvim/mason/packages/lua-language-server/libexec/log"
grep -hF '[luals-composer]' "$LOG"/*luals-composer-e2e*.log 2>/dev/null \
  | sed 's/^\[[0-9:.]*\]\[info\] \[#0\]: //;s/^\[[0-9:.]*\]\[warn\] \[#0\]: //' \
  || echo "(no log lines found; check $LOG)"
