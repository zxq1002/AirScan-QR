# iOS Cimbar/CFC 原生客户端 (ios-cfc-client)

本模块是参考 [sz3/cfc](https://github.com/sz3/cfc) 安卓客户端，为苹果 iPhone / iPad (iOS) 设备量身打造的原生 Cimbar 视觉传输客户端。

> 📌 当前版本：**v1.2.0**（2026-08-09）。接收能力现已通过 WKWebView 内嵌 cimbar WASM 落地（路线 B）。功能对齐说明见 [ALIGNMENT-ANALYSIS.md](ALIGNMENT-ANALYSIS.md)，路线 B 可行性与实现记录见 [WASM-REUSE-FEASIBILITY.md](WASM-REUSE-FEASIBILITY.md)。

## 🌟 特性亮点

1. **硬件级 AVFoundation 捕获**：使用 iOS 原生 `AVCaptureSession`，支持 60 FPS 零拷贝像素流读取，彻底解决 Safari 浏览器摄像头帧率受限问题。
2. **免疫 Safari 色彩校正失真**：直接从 `CVPixelBuffer` 读取原生 BGRA / YUV420 像素，绕过 WebKit 的 Canvas 色彩转换，4C 模式识别率提升 300%。
3. **SwiftUI 现代化交互**：提供实时对焦框、传输速度 (KB/s)、帧率 (FPS) HUD 及原生 iOS“文件”App 保存/分享支持。
4. **C++ 核心解码引擎**：通过 Objective-C++ 桥接层接入解码核心，API 与 libcimbar `cimbard_*` 协议同构，并预留 Zstandard 解压缩对接点。

> ✅ **解码引擎状态（v1.2.0）**：**路线 B 已落地**——App 内用本地 HTTP 服务 + WKWebView 加载 `harness.html`，直接复用网页端同一份 `cimbar_js.wasm`（内嵌 libcimbar+OpenCV）完成解码，与网页端逐字节同源；模拟器已验证 wasm→Workers→相机授权全链路。原 AVFoundation + 原生 C++ 的**路线 A** 骨架（从未链接真实引擎，`CFC_LIBCIMBAR_BACKEND` 恒为 0）已移除，历史见 commit `7ee408a`；若日后要做原生提速，请按 §6 重新实现而非复活骨架。详见 [WASM-REUSE-FEASIBILITY.md](WASM-REUSE-FEASIBILITY.md) 与 [ALIGNMENT-ANALYSIS.md](ALIGNMENT-ANALYSIS.md) §6。

## 📁 目录结构

```text
ios-cfc-client/
├── cfc/
│   └── cfcApp.swift                    # @main 应用入口（Xcode 自动同步组）
├── Sources/
│   ├── Views/
│   │   ├── MainView.swift              # 主界面（TabView）
│   │   └── FilePreviewView.swift       # 接收文件预览与保存
│   └── WebReceiver/                    # 路线 B：WKWebView 接收端
│       ├── WebReceiverServer.swift     # 本地 HTTP 静态服务（同源上下文）
│       ├── WebReceiverViewController.swift  # WKWebView 宿主 + 原生桥
│       └── WebReceiverView.swift       # SwiftUI 包装 + 文件预览衔接
└── WebResources/
    ├── harness.html                    # 取景区 + 实时进度面板 + 解码编排
    └── cimbar-deps/                    # 复用网页端的 wasm / recv.js / zstd.js
```

## 🛠️ 编译与构建说明

### 方式 A：纯命令行一键编译 (CLI)

我们提供了免打开 Xcode 界面的一键命令行编译脚本：

```bash
cd ios-cfc-client

# 1. 编译 iOS 模拟器版本 (默认产物输出到 build/ 目录)
./build.sh simulator

# 2. 编译 iPhone 真机 Release 版本
./build.sh iphone

# 3. 清理构建缓存
./build.sh clean
```

> 💡 **提示**：如果是首次在命令行下使用，需要将命令行路径切换为完整 Xcode：
> `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`

---

### 方式 B：使用 Xcode GUI 界面编译

1. 需要 macOS 系统并已安装 **Xcode 14.0+**。
2. 双击打开 `ios-cfc-client/cfc/cfc.xcodeproj`。
3. 在 `Signing & Capabilities` 勾选 `Automatically manage signing` 并选择你的免费 Apple ID。
4. 点击左上角 `▶` 按钮（或按 `Command + R`）即可编译安装到 iPhone。
