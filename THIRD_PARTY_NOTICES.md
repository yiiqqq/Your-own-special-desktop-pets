# 第三方组件

- macOS 原生程序：使用系统提供的 AppKit、SwiftUI、Security、CryptoKit、ImageIO、AVFoundation 和 UniformTypeIdentifiers，源码包不包含 Apple SDK 或系统字体。
- Windows 桌面程序：运行环境为 Electron 45.0.0。Electron 采用 MIT，其内含 Chromium、Node.js、FFmpeg 等组件。分发运行环境时必须保留官方 Electron 压缩包中的 `LICENSE`、`LICENSES.chromium.html` 及其他许可文件。源码包不包含 Electron 运行环境或 node_modules。
- 本项目自定义角色、动作及配乐生成代码没有新增第三方代码依赖。
- emoji 由运行设备系统字体渲染；项目未复制字体文件。
- OpenAI / DeepSeek 接口属于可选的联网服务。源码许可不包含服务额度或服务商的授权，用户自行配置自己的密钥。
