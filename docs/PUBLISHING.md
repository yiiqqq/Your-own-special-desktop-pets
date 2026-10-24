# GitHub 和双端更新发布

项目仓库：https://github.com/yiiqqq/Your-own-special-desktop-pets。签名更新说明固定地址：`https://raw.githubusercontent.com/yiiqqq/Your-own-special-desktop-pets/main/updates/latest.json`。首次发布应先上传程序包，确认下载正常后再上传签名说明。

## 公开源码

1. 在 GitHub 创建自己管理的空仓库，例如 `little-companions`。
2. 只上传本项目源码包中的文件。不要上传本项目上一级工作目录、个人数据、build、node_modules、`.publisher` 或任何私钥。
3. 保留 LICENSE、ASSET_LICENSE.md 和 THIRD_PARTY_NOTICES.md。公开程序包时保留 Electron 的许可文件。
4. 在 Releases 上传本项目生成的 Mac / Windows 压缩包；发布说明写清支持系统、是否实机测试，以及程序未经过开发者正式签名/公证的情况。当前 Mac 为本机临时签名，Windows 没有发布者代码签名。

## 签名自动更新

两个客户端已经包含独立于旧项目的发布公钥，feedURL 已填入本项目固定更新地址。当前维护者的私钥保留在仓库之外，没有打进源码或应用。fork 本项目时自行生成发布密钥，并在首次分发前把对应的公钥放入两个配置文件，重新编译/打包。

```sh
node tools/release.js init /仓库外的私钥目录
```

将生成的 public-config.json 复制到 `macos/UpdateConfig.json` 和 `desktop/app/update-config.json`；私钥不复制到仓库。以后继续沿用私钥，不要每次发布都重生成。

```sh
python3 tools/package_updates.py --mac 'build/小小造物站.app' --win 'build/LittleCompanions-Windows-x64/resources/app' --out release/updates
node tools/release.js sign /仓库外的私钥目录/signing-key.pem release-spec.json release/latest.json
```

release-spec.json 使用工具生成的版本号、两端更新包路径和正式 HTTPS 直链，格式：

```json
{
  "schema": 1,
  "version": "0.8.1",
  "notes": "更新说明",
  "artifacts": {
    "macos-arm64": {"file": "release/updates/little-companions-macos-arm64-0.8.1.zip", "url": "https://YOUR-HOST/mac-update.zip"},
    "win32-x64": {"file": "release/updates/little-companions-windows-app-0.8.1.zip", "url": "https://YOUR-HOST/windows-update.zip"}
  }
}
```

YOUR-HOST 是需要替换的示例，不是实际发布服务。两端版本号和公钥必须一致。先上传更新 ZIP 并验证下载，再上传签名的 latest.json。然后在两端设置填入同一个稳定 HTTPS latest.json 地址。普通分享页面不能代替更新文件直链。

源码中的版本号位于 Mac `UpdatePolicy.version`、Windows `updater.js` 和 `package.json`；同步修改后重新构建。Mac 构建工具的 Info.plist 版本也需要同步修改。Windows 常规更新只替换 app 资源，要求 Electron 45；运行环境大版本升级需另做完整升级方案。

自动更新发布前必须在两台真实设备上测试：下载、签名、替换、重启、学习模式阻止重启和存档保留。工具只准备好了，不代表线上服务已开通。
