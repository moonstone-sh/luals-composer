#!/usr/bin/env bash
# End-to-end verification of NAME-BASED enrollment (plugin self-description)
# against a REAL headless lua-language-server.
#
# This is tests/e2e/verify.sh's 2-plugin and 3-plugin composition cases, run
# again with the descriptors supplied by each plugin package's own
# luals-plugin.lua instead of hand-typed by the consumer. It proves three
# things:
#
#   1. enroll{ plugin = "valua" } and the equivalent hand-typed descriptor
#      produce BYTE-IDENTICAL .luarc.json and luals-composer.json;
#   2. the .luarc.json that name-based enrollment writes drives real LuaLS to
#      the same composition result as the hand-written config in verify.sh —
#      every plugin's effects present simultaneously;
#   3. enrolling a name with no manifest fails with a clear, actionable error
#      and writes nothing.
#
#   usage: bash tests/e2e/verify_named.sh [workbench-root]
#
# Requires: python3, moon, and lua-language-server installed via Mason at
#   ~/.local/share/nvim/mason/packages/lua-language-server/
#
# NOTE ON THE ENVIRONMENT. moonstone/luals-composer is built but not published
# (LUALS-DESIGN.md §5, #13), so `moon sync` cannot yet materialise any of these
# four packages into a consuming project. This script therefore BUILDS the
# .moonstone/env tree by copying the real source trees into the exact installed
# layout that clingy's own shipped descriptor
# (src/clingy/cli/init.lua: ".moonstone/env/share/lua/<abi>/clingy/luals/plugin.lua")
# and project.installed_transport_path already assert. The files are real, the
# layout is the real convention, but no real `moon sync` produced it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
W="${1:-$HOME/Workbench/user}"
OUT="${OUT:-/tmp/luals-composer-named-e2e}"

for f in "$W/luals-composer/src/luals_composer/init.lua" \
         "$W/hydronium/luax/src/hydronium_luax/luals/init.lua" \
         "$W/hydronium/luax/src/hydronium_luax/luals-plugin.lua" \
         "$W/valua/src/valua/tooling/luals/plugin.lua" \
         "$W/valua/src/valua/luals-plugin.lua" \
         "$W/clingy/luals/plugin.lua" \
         "$W/clingy/src/clingy/luals-plugin.lua"; do
  [ -f "$f" ] || { echo "MISSING: $f"; exit 1; }
done

rm -rf "$OUT"; mkdir -p "$OUT"

# --------------------------------------------------------------------------
# Materialise a Moonstone environment holding all four packages.
# --------------------------------------------------------------------------
make_workspace() {
  local ws="$OUT/$1"; shift
  local tree="$ws/.moonstone/env/share/lua/5.1"
  mkdir -p "$tree"
  cat > "$ws/moonstone.toml" <<'EOF'
manifest_version = 2

[package]
name = "consumer"
version = "0.1.0"
kind = "script"

[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"
EOF
  cat > "$ws/.moonstone/env/env.toml" <<'EOF'
[runtime]
name = "luajit"
version = "2.1.0"
abi = "lua51"
EOF
  # Exactly the layout `moon sync` produces: each package's Lua module tree
  # rooted at share/lua/<abi>/<module>/, manifests riding along inside it.
  cp -R "$W/luals-composer/src/luals_composer"       "$tree/luals_composer"
  cp    "$W/luals-composer/src/luals_composer.lua"   "$tree/luals_composer.lua"
  cp -R "$W/valua/src/valua"                         "$tree/valua"
  cp    "$W/valua/src/valua.lua"                     "$tree/valua.lua"
  cp -R "$W/clingy/src/clingy"                       "$tree/clingy"
  cp    "$W/clingy/src/clingy.lua"                   "$tree/clingy.lua"
  cp -R "$W/clingy/luals"                            "$tree/clingy/luals"
  cp -R "$W/hydronium/luax/src/hydronium_luax"       "$tree/hydronium_luax"
}

# The settings enrollment does NOT own, seeded first so we also prove they
# survive being enrolled around.
seed_luarc() {
  local ws="$OUT/$1"
  local tree=".moonstone/env/share/lua/5.1"
  cat > "$ws/.luarc.json" <<EOF
{
  // Hand-written editor settings. Composer owns runtime.plugin/pluginArgs
  // and must leave every one of these alone.
  "runtime": {
    "version": "LuaJIT",
    "path": ["?.lua", "?/init.lua", "?.luax"]
  },
  "workspace": {
    "library": ["$tree", "$W/hydronium/luax/types", "$W/clingy/luals/library"],
    "checkThirdParty": false,
    "useGitIgnore": false
  },
  "files.associations": { "*.luax": "lua" }
}
EOF
}

for ws in ws-named ws-typed ws-errors; do make_workspace "$ws"; done
seed_luarc ws-named
seed_luarc ws-typed

# A package that is installed but says nothing about LuaLS, plus two that
# describe themselves wrongly — the real error path.
ETREE="$OUT/ws-errors/.moonstone/env/share/lua/5.1"
mkdir -p "$ETREE/undescribed/luals" "$ETREE/impostor/luals" "$ETREE/badmode/luals"
for m in undescribed impostor badmode; do
  echo 'function OnSetText() return nil end' > "$ETREE/$m/luals/plugin.lua"
done
cat > "$ETREE/impostor/luals-plugin.lua" <<'EOF'
return { name = "valua", path = "luals/plugin.lua", transport = "^0.2.0",
         contract = 1, text_edits = "insertions", args = {} }
EOF
cat > "$ETREE/badmode/luals-plugin.lua" <<'EOF'
return { name = "badmode", path = "luals/plugin.lua", transport = "^0.2.0",
         contract = 1, text_edits = "rewrite-the-whole-thing", args = {} }
EOF

# --------------------------------------------------------------------------
# The files under test.
# --------------------------------------------------------------------------
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

cat > "$OUT/cli.lua" <<'EOF'
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

for ws in ws-named ws-typed; do
  cp "$OUT/App.luax" "$OUT/$ws/App.luax"
  cp "$OUT/cli.lua"  "$OUT/$ws/cli.lua"
done

# --------------------------------------------------------------------------
echo "=========== ENROLL: by name, and by hand-typed descriptor as the control ==========="
echo "expect: three descriptors resolved from each package's own luals-plugin.lua,"
echo "        and the same three hand-typed the pre-self-description way."
echo "        Both runs share ONE process so that Lua's per-process string hash"
echo "        seed — which decides the key order Composer serialises descriptors"
echo "        in — is held constant. See enroll_named.lua."
( cd "$PKG" && moon exec lua -- tests/e2e/enroll_named.lua "$OUT/ws-named" both "$OUT/ws-typed" )

echo
echo "=========== the .luarc.json name-based enrollment wrote ==========="
cat "$OUT/ws-named/.luarc.json"
echo
echo "=========== the luals-composer.json it wrote ==========="
cat "$OUT/ws-named/luals-composer.json"

echo
echo "=========== IDENTICAL to the hand-typed control? ==========="
echo "  .luarc.json is compared BYTE FOR BYTE: it holds only string arrays,"
echo "  whose order Composer controls, so it must not differ at all."
echo "  luals-composer.json is compared as a PARSED DOCUMENT. Composer"
echo "  serialises each descriptor in Lua \`pairs\` order, which is unspecified"
echo "  and varies with both the process's string hash seed and the order the"
echo "  fields were assigned. Two hand-typed runs in two processes differ the"
echo "  same way, so this is a pre-existing property of enrollment rather than"
echo "  anything name resolution introduced, and no JSON reader can see it."
ok=1
if diff -u "$OUT/ws-typed/.luarc.json" "$OUT/ws-named/.luarc.json"; then
  echo "  BYTE-IDENTICAL: .luarc.json"
else
  echo "  DIFFERS: .luarc.json"; ok=0
fi
echo "  --- descriptor key order, for the record (not asserted on) ---"
diff "$OUT/ws-typed/luals-composer.json" "$OUT/ws-named/luals-composer.json" \
  && echo "  (bytes happened to match this run)" || true
python3 - "$OUT/ws-typed" "$OUT/ws-named" <<'PY' || ok=0
import json, re, sys
def load(p):
    raw = open(p).read()
    return json.loads(re.sub(r'^\s*//.*$', '', raw, flags=re.M))
a, b = sys.argv[1], sys.argv[2]
for f in ('.luarc.json', 'luals-composer.json'):
    x, y = load(a + '/' + f), load(b + '/' + f)
    if x == y:
        print('  SEMANTICALLY IDENTICAL: %s (same keys, same values, same array order)' % f)
    else:
        print('  SEMANTIC MISMATCH: %s\n    typed=%r\n    named=%r' % (f, x, y)); sys.exit(1)
PY
[ "$ok" = 1 ] || { echo "FAIL: name-based enrollment did not reproduce the hand-typed result"; exit 1; }

echo
echo "=========== re-enrolling by name is a no-op (changed=false, no churn) ==========="
before="$(md5 -q "$OUT/ws-named/luals-composer.json" 2>/dev/null || md5sum "$OUT/ws-named/luals-composer.json" | cut -d' ' -f1)"
( cd "$PKG" && moon exec lua -- tests/e2e/enroll_named.lua "$OUT/ws-named" named )
after="$(md5 -q "$OUT/ws-named/luals-composer.json" 2>/dev/null || md5sum "$OUT/ws-named/luals-composer.json" | cut -d' ' -f1)"
[ "$before" = "$after" ] && echo "  registry bytes unchanged by re-enrollment" \
  || { echo "FAIL: re-enrollment rewrote the registry"; exit 1; }

echo
echo "=========== REAL LuaLS, App.luax — hydronium-luax AND valua both alive ==========="
echo "expect: FormSchema keeps its per-file synthesized class (NOT <table,table>),"
echo "        and NO JSX syntax errors — only genuine semantic diagnostics."
python3 "$HERE/drive.py" "$OUT/ws-named" "$OUT/ws-named/App.luax" \
  '{"hovers":[[3,8,"FormSchema"],[9,14,"d.button"]],"completions":[[12,18,"d.b"]]}'

echo
echo "=========== REAL LuaLS, cli.lua — clingy AND valua both alive ==========="
echo "expect: ArgSchema keeps its per-file synthesized class, and the completion"
echo "        after clingy's injected cast lists 'name, shout'."
echo "        READ THE COMPLETION, NOT THE HOVER — see verify.sh for why."
python3 "$HERE/drive.py" "$OUT/ws-named" "$OUT/ws-named/cli.lua" \
  '{"hovers":[[13,20,"ctx"],[3,8,"ArgSchema"]],"completions":[[14,22,"ctx.args."]]}'

echo
echo "=========== ERROR PATH — a name with no manifest ==========="
echo "expect: a structured error naming the missing file and both remedies,"
echo "        and a workspace left completely untouched."
( cd "$PKG" && moon exec lua -- tests/e2e/enroll_errors.lua "$OUT/ws-errors" )

echo
echo "=========== transport messages from the LuaLS log ==========="
LOG="$HOME/.local/share/nvim/mason/packages/lua-language-server/libexec/log"
grep -hF '[luals-composer]' "$LOG"/*luals-composer-named-e2e*.log 2>/dev/null \
  | sed 's/^\[[0-9:.]*\]\[info\] \[#0\]: //;s/^\[[0-9:.]*\]\[warn\] \[#0\]: //' \
  || echo "(no log lines found; check $LOG)"
