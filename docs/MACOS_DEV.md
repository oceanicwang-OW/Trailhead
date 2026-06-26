# macOS 开发环境要求 · 行迹 Trailhead

本工程为 **macOS + iOS 双端原生 App**（单 application target，共享 SwiftUI 代码，PDR T0.1）。

---

## 1. 前置要求

| 项 | 版本 | 说明 |
|---|---|---|
| macOS | 14 (Sonoma) 及以上 | 运行 / 开发宿主 |
| **Xcode** | **26.x**（含 iOS 26 / macOS 26 SDK） | `xcode-select -p` 确认指向 Xcode |
| Swift | 5.9+（工程语言模式 5.0） | 随 Xcode 附带 |
| Homebrew | 最新 | 安装下列命令行工具 |
| XcodeGen | 2.4x | 由 `project.yml` 生成工程 |
| SwiftLint | 0.6x | 规范检查（构建期自动跑） |
| SwiftFormat | 0.6x | 自动格式化 |

### 部署目标
- **iOS 17.0+ / macOS 14.0+**（见 `project.yml`）。
- `TARGETED_DEVICE_FAMILY = 1,2`（iPhone + iPad）。

### 一键安装命令行工具
```bash
brew install xcodegen swiftlint swiftformat
make doctor   # 校验工具链
```

---

## 2. 打开与运行

工程文件 `.xcodeproj` **由 `project.yml` 生成、不入库**。每次拉取代码或改了工程配置后需重新生成：

```bash
make open          # = xcodegen generate && open Trailhead.xcodeproj
# 或手动
xcodegen generate
open Trailhead.xcodeproj
```

在 Xcode 中选 `Trailhead` scheme，目标选 “My Mac” 或任一 iOS 模拟器，⌘R 运行。
首次启动自动播种「关西环游」示例（`SampleData`），界面即还原设计稿。

### 命令行构建 / 运行
```bash
make build         # 双端编译
make build-mac
make build-ios
make lint          # SwiftLint
make format        # SwiftFormat
```

> CI / 无签名场景加 `CODE_SIGNING_ALLOWED=NO`（Makefile 已内置）。

---

## 3. 代码签名

- 本机开发：`CODE_SIGN_STYLE = Automatic`。首次在 Xcode 选 target → Signing & Capabilities，登录 Apple ID 并选个人 Team；macOS 可用 “Sign to Run Locally”。
- 自用、不分发，无需付费开发者账号即可在本机 / 模拟器运行。
- **API key 不进签名/工程**，运行时由用户在设置页填入并存 Keychain。

---

## 4. 权限与能力

- **Keychain**：`KeychainStore` 用 `kSecClassGenericPassword` 存高德 / LLM key（service `app.trailhead.keys`）。沙盒 App 默认可读写自身钥匙串项，无需额外 entitlement。
- **网络**：真实 client 落地后（PDR T2/T3）需出站网络；App Sandbox 开启时给 macOS target 勾选 `com.apple.security.network.client`。当前桩实现不联网。
- **MapKit / 定位**：地图仅展示，不取用户定位；如未来加“当前位置”，再补 `NSLocationWhenInUseUsageDescription`。

---

## 5. 工程结构与生成式 Info.plist

- 不维护物理 `Info.plist`；用 `GENERATE_INFOPLIST_FILE = YES` + `project.yml` 里的 `INFOPLIST_KEY_*`（显示名「行迹」、类目 travel、iOS 启动屏等）。
- 资源在 `Trailhead/Assets.xcassets`（`AppIcon` 占位 + 品牌 `AccentColor #1FA67A`）。
- 改名/改版本/加 target/改构建设置 → 改 `project.yml` 后 `xcodegen generate`，**不要在 Xcode 里直接改再依赖 .pbxproj**（会被下次生成覆盖）。

---

## 6. 常见问题

| 现象 | 处理 |
|---|---|
| 打开工程报 “unsupported Swift version” | `SWIFT_VERSION` 必须是语言模式（`5.0`/`6.0`），非编译器版本号 |
| 构建期 SwiftLint 报错 “command not found” | `brew install swiftlint`；未装时脚本只告警不阻断 |
| `.xcodeproj` 改动丢失 | 工程由 `project.yml` 生成，改配置改 yml 后重新 generate |
| 模拟器跑不起来 | `xcrun simctl list devices available` 选已安装的 iPhone 机型 |
