# 小小造物站 · Little Companions

玩家自己创造角色的开源桌宠。macOS 原生 SwiftUI 程序 + Windows Electron 程序，共用可交换的角色文件格式。

## 角色由玩家创造

打开主页的「创造角色」：选择圆团 / 豆豆 / 水滴身体、圆耳 / 叶芽 / 无装饰，调整两种颜色、眼睛、小尾巴和性格。名字可在主页修改，八个角色槽均可独立编辑。

也可导入自己的透明 PNG，为普通、开心、生气、委屈、惊喜、侧面、背面分别设图。图片保留宽高比；每张最大 1 MB、2048 × 2048，导入时缩至不超过 512 像素。缺少表情时使用普通图；缺少侧面或背面时使用程序化造型。

程序化角色的手脚随动作活动。导入的完整立绘使用整体运动，不会自动推断或切割四肢；完整图片模式的自定义衣服骨骼编辑尚未实现。角色编辑器不是 AI 绘图服务，不需要消耗 API 额度。

导出 `.littlepet.json` 时只包含名字、外观、性格和导入的图片，不包含聊天、日程、养成记录或 API 密钥。两个平台可互相导入。

## 陪伴功能

- 近距离互动、拥抱、安慰、喂食与亲密度。
- 学习、野餐、音乐会和六种小游戏。
- 学习期间拖动时整组移动，仅到时或主动结束才退出学习。
- 安静小屋与各自的小房间，回家后不自行外出。
- 可选 API 聊天；密钥仅存本机系统保护的存储。
- 内置本项目原创轻音乐，也可导入自己有权使用的音乐。没有预置外部音乐页面。
- 签名自动更新；默认读取项目固定更新地址，不包含发布者私钥。

## 源码运行

macOS 14+ / Apple Silicon，安装 Xcode Command Line Tools 后：

```sh
python3 tools/build_macos.py
open 'build/小小造物站.app'
```

Windows 10/11 x64，安装 Node.js / npm 后：

```sh
cd desktop/app
npm install
npm start
```

Windows 玩家可直接使用完整解压后的发布包，无需安装 Node.js。`tools/package_windows.py` 用已下载的官方 Electron 45.0.0 win32-x64 压缩包及配套校验清单打包，不会在打包时下载程序。

生成原创素材：`python3 tools/generate_assets.py`（Python 标准库，无第三方素材）。

## 存档、隐私与发布

新应用使用独立的 LittleCompanions 数据目录，不自动读取其他桌宠的图片、旧角色、聊天或密钥。Mac 保存外观到 Application Support/LittleCompanions/designs.json；Windows 外观保存在独立 userData 的 state.json。两端不自动同步存档；可用角色导入导出迁移外观。

角色 PNG 和 JSON 在本机处理，不上传。API 聊天仅在玩家主动发送时把最近对话、性格和学习卡交给所选服务。启动更新检查只在配置更新服务后发生。

请勿将 `.env`、私钥、个人存档、聊天或自定义素材目录上传到仓库。`LICENSE` 为 MIT；内置原创素材见 `ASSET_LICENSE.md`；第三方运行环境见 `THIRD_PARTY_NOTICES.md`。导入他人的角色不会自动获得其许可。

## 发布状态与验证范围

源码仓库：https://github.com/yiiqqq/Your-own-special-desktop-pets

程序下载：https://github.com/yiiqqq/Your-own-special-desktop-pets/releases/latest

0.8.1 已预填更新地址；0.8.0 用户可在设置里填写一次 `https://raw.githubusercontent.com/yiiqqq/Your-own-special-desktop-pets/main/updates/latest.json`。固定更新地址已上线；0.8.0 客户端已实际联网发现 0.8.1，并完成公网下载的签名和完整性校验。详细记录见 `docs/ONLINE_RELEASE.md`。Windows 原生桌面和更新替换/重启仍需实机验收。
