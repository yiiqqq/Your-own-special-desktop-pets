# 0.8.1 上线验证

仓库：https://github.com/yiiqqq/Your-own-special-desktop-pets

公开下载：https://github.com/yiiqqq/Your-own-special-desktop-pets/releases/tag/v0.8.1

固定更新地址：https://raw.githubusercontent.com/yiiqqq/Your-own-special-desktop-pets/main/updates/latest.json

## 已完成

- 公开源码、原创配乐、图标、许可文件和测试文件均已上传。
- 六个 Release 附件已公开，包括 Mac / Windows 完整程序、源码备份、发布工具以及两端更新包。GitHub 返回的六份 SHA-256 和文件大小均与本机一致。
- 从 GitHub 公网重新下载两端更新 ZIP，检查签名、平台、版本、大小和 SHA-256，通过。
- Mac 原生 CryptoKit 使用应用内固定公钥验证实际下载的 Mac 更新包，通过。
- 从原 0.8.0 程序包中提取的更新客户端，在隔离目录读取真实固定地址，实际返回“发现新版本 0.8.1”；继续验证公网 Windows 更新 ZIP，通过。
- Windows 完整程序公开下载地址最终返回 HTTP 200、attachment 与正确的 160036603 字节长度。
- 公开仓库全部 54 个文件在更新本报告前逐个与本机 Git blob SHA 核对，一致。签名私钥、个人存档、聊天和导入素材不在公开包中。

## 使用方式

0.8.1 新版已预填地址，启动会检查；发现以后发布的新版本时，由玩家确认“更新并重启”。正在学习时不重启。

0.8.0 用户在设置中填写一次上面的固定更新地址，然后检查更新。更早、属于其他项目身份的程序不可直接使用本更新通道。

## 尚未完成的验收

没有替换或重启用户当前正在使用的程序。本机不是 Windows，Windows 桌面透明窗口、系统加密和 PowerShell 更新替换/重启尚未实机验证。公网更新检查与下载成功，不等于所有设备都已完成自动安装测试。

Release 中的源码 ZIP 和 Git 标签是更新入口发布前的代码快照；main 分支包含上线后的签名入口和本验证报告。程序及更新包没有因为文档更新而改变。
