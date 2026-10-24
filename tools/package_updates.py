from pathlib import Path
import plistlib,zipfile,json,argparse,subprocess,sys
p=argparse.ArgumentParser();p.add_argument('--mac',required=True);p.add_argument('--win',required=True);p.add_argument('--out',required=True);a=p.parse_args()
mac=Path(a.mac);win=Path(a.win);out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
m=plistlib.loads((mac/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'];w=json.loads((win/'package.json').read_text())['version']
assert m==w,'Mac / Windows versions differ; refusing an unsynchronized release'
assert json.loads((mac/'Contents/Resources/UpdateConfig.json').read_text())['publicKey']==json.loads((win/'update-config.json').read_text())['publicKey'],'Publishing keys differ'
if sys.platform=='darwin':subprocess.run(['codesign','--verify','--deep','--strict',str(mac)],check=True)
def archive(source,target,root):
 with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED) as z:
  for f in sorted(source.rglob('*')):
   if f.is_file() and f.name not in ['.DS_Store','state.json','keys.json'] and not f.name.startswith('._'):
    if f.suffix in ['.pem','.pfx'] or f.name.startswith('.env'):raise ValueError('Private file found in app')
    z.write(f,Path(root)/f.relative_to(source))
 with zipfile.ZipFile(target) as z:assert z.testzip() is None
archive(mac,out/f'little-companions-macos-arm64-{m}.zip','小小造物站.app');archive(win,out/f'little-companions-windows-app-{w}.zip','app')
print('Both platform update archives created for version',m)
