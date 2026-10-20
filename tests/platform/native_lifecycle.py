"""Exercise Composer enrollment and installed plugin dispatch on each host."""
import os
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile
import tarfile

sys.stdout.reconfigure(encoding='utf-8')

repo = Path(__file__).resolve().parents[2]
moon = os.environ.get('MOONSTONE_BIN') or shutil.which('moon')
ballad = Path(os.environ.get('BALLAD_SOURCE', repo/'.ci/ballad')).resolve()
alter = Path(os.environ.get('ALTER_SOURCE', repo/'.ci/alter')).resolve()
os.environ['PATH'] = str(Path(moon).resolve().parent) + os.pathsep + os.environ.get('PATH', '')
assert moon and (ballad/'src/main.lua').is_file() and (alter/'host/src/alter.lua').is_file()
with tempfile.TemporaryDirectory(prefix='composer lifecycle ') as directory:
    root = Path(directory)/'composer'
    shutil.copytree(repo, root, ignore=shutil.ignore_patterns('.git', '.ci', '.moonstone', '.ballad', 'dist', 'node_modules'))
    def run(project, *args):
        result = subprocess.run([moon, '-C', str(project), *args], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600)
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        print(result.stdout)
    for name, source, tool in [('moonstone/ballad',ballad,True), ('moonstone/alter',alter/'host',False), ('moonstone/alter-jsonc',alter/'jsonc-backend',False)]:
        run(root, 'remove', name, '--no-sync')
        run(root, 'add', 'path:'+source.as_posix(), *(['--tool'] if tool else []), '--no-sync')
    run(root, 'sync')
    run(root, 'exec', '--', 'lua', 'tests/runner.lua')
    run(root, 'exec', '--', 'ballad', 'play', 'partiture.lua')
    with tarfile.open(next((root/'dist/registry').glob('*.tar.gz'))) as bundle:
        assert any(name.endswith('luals_composer/init.lua') for name in bundle.getnames())
    consumer = Path(directory)/'user project'
    run(root, 'init', str(consumer), '--name', 'composer-user', '--interpreter', 'lua@5.4', '--no-git', '--no-sync')
    run(consumer, 'add', 'path:'+root.as_posix())
    (consumer/'plugin.lua').write_text('OnSetText=function() return {{start=1,finish=0,text="-- composed\\n"}} end\n')
    (consumer/'verify.lua').write_text('''local composer=require("luals_composer")
local project=require("luals_composer.project")
local root=arg[1]
local opts={root=root,plugin={name="fixture",path="plugin.lua",contract=1,transport="^0.2.0",text_edits="insertions"}}
local first,err=composer.enroll(opts); assert(first,err and err.message)
local again,err=composer.enroll(opts); assert(again,err and err.message); assert(not again.changed)
local entry=assert(project.installed_transport_path(root))
local env=setmetatable({}, {__index=_G})
local file=assert(io.open(root.."/"..entry,"rb")); local source=file:read("*a"); file:close()
local chunk=assert(load(source,"@"..root.."/"..entry,"t",env))
local uri="file://"..(root:sub(1,1)=="/" and "" or "/")..root.."/main.lua"
chunk(chunk,uri,{"--config="..root.."/luals-composer.json"})
local edits=assert(env.OnSetText(uri,"return 1")); assert(edits[1].text=="-- composed\\n")
print("PASS: fresh installed enrollment, idempotence, and LuaLS child dispatch")
''')
    run(consumer,'exec','--','lua','verify.lua',consumer.as_posix())
print('PASS: Composer source export and installed lifecycle')
