"""Build the native macOS application from this repository only."""
from pathlib import Path
import subprocess,shutil,plistlib,os
root=Path(__file__).resolve().parents[1];out=root/'build/小小造物站.app'
resources=out/'Contents/Resources';binary=out/'Contents/MacOS';binary.mkdir(parents=True,exist_ok=True);resources.mkdir(parents=True,exist_ok=True)
if not (root/'desktop/app/assets/study-garden.wav').exists():subprocess.run(['python3',str(root/'tools/generate_assets.py')],check=True)
sdk=os.environ.get('SDKROOT') or subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
subprocess.run(['swiftc','-swift-version','5','-sdk',sdk,'-target','arm64-apple-macosx14.0','-O','-module-cache-path',os.environ.get('TMPDIR','/tmp')+'/little-companions-swift-cache',str(root/'macos/Source/main.swift'),str(root/'macos/Source/Creator.swift'),'-o',str(binary/'LittleCompanions'),'-framework','AppKit','-framework','SwiftUI','-framework','Security'],check=True)
info={'CFBundleIdentifier':'org.littlecompanions.desktop','CFBundleExecutable':'LittleCompanions','CFBundleName':'小小造物站','CFBundleShortVersionString':'0.8.1','CFBundleVersion':'1','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication'}
(out/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
for src in [root/'macos/UpdateConfig.json',root/'desktop/app/assets/study-garden.wav']:shutil.copy2(src,resources/src.name)
subprocess.run(['codesign','--force','--sign','-',str(out)],check=True);subprocess.run(['codesign','--verify','--deep','--strict',str(out)],check=True)
print(out)
