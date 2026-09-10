#!/usr/bin/env python3
"""Drive a real headless lua-language-server against a workspace and report
hover / completion / diagnostics. Real LSP, real Mason binary, no mocking."""
import sys, time, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lspclient import LSP

BIN = os.path.expanduser(
    '~/.local/share/nvim/mason/packages/lua-language-server/libexec/bin/lua-language-server')
WS = sys.argv[1]
FILE = sys.argv[2]
SPEC = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}

c = LSP([BIN], WS)
c.initialize()
time.sleep(6)
uri = c.open(FILE)
time.sleep(7)

src = open(FILE).read().split('\n')

def hover(line, char, label):
    r = c.hover(uri, line, char)
    res = r.get('result')
    val = ''
    if res and res.get('contents'):
        val = res['contents'].get('value', '') if isinstance(res['contents'], dict) else str(res['contents'])
    lines = [l for l in val.split('\n') if l.strip() and not l.startswith('```')]
    print('  HOVER %-14s => %s' % (label, lines[0] if lines else '(nothing)'))

def completion(line, char, label, limit=14):
    r = c.completion(uri, line, char)
    res = r.get('result') or {}
    items = res.get('items', res if isinstance(res, list) else [])
    labels = [i['label'] for i in items]
    print('  COMPL %-14s => %d items: %s' % (
        label, len(labels), ', '.join(labels[:limit]) + (' ...' if len(labels) > limit else '')))
    return labels

print('### %s' % os.path.basename(WS))
for h in SPEC.get('hovers', []):
    hover(h[0], h[1], h[2])
for k in SPEC.get('completions', []):
    completion(k[0], k[1], k[2])

print('  --- diagnostics ---')
found = False
for d in c.diags(uri):
    for it in d['params']['diagnostics']:
        found = True
        print('    DIAG line %d: %s' % (it['range']['start']['line'], it['message'].split('\n')[0]))
if not found:
    print('    (none)')
c.shutdown()
