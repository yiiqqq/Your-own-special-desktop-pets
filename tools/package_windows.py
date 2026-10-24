"""Package with an official Electron 45.0.0 Windows x64 ZIP after SHA-256 validation."""
from pathlib import Path
import argparse,hashlib,zipfile,shutil
p=argparse.ArgumentParser();p.add_argument('--runtime',type=Path,required=True);p.add_argument('--checksums',type=Path,required=True);a=p.parse_args()
expected=next(line.split()[0]for line in a.checksums.read_text().splitlines()if line.endswith('electron-v45.0.0-win32-x64.zip'))
assert hashlib.sha256(a.runtime.read_bytes()).hexdigest()==expected,'Official runtime hash mismatch'
root=Path(__file__).resolve().parents[1];out=root/'build/LittleCompanions-Windows-x64'
if out.exists():shutil.rmtree(out)
out.mkdir(parents=True)
with zipfile.ZipFile(a.runtime)as z:z.extractall(out)
(out/'electron.exe').rename(out/'LittleCompanions.exe');(out/'electron_wer.dll').rename(out/'LittleCompanions_wer.dll')
shutil.copytree(root/'desktop/app',out/'resources/app',ignore=shutil.ignore_patterns('node_modules','*.tmp','.env*'))
assert (out/'LICENSE').is_file() and (out/'LICENSES.chromium.html').is_file()
print(out)
