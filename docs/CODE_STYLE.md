# 代码规范 · 行迹 Trailhead

面向人类与 AI coding agent 的统一规范。提交前应满足：`make lint` 零告警、`make build` 双端通过。

---

## 1. 工具链（强制）

| 工具 | 作用 | 配置文件 |
|---|---|---|
| **SwiftLint** | 静态规范检查（构建期自动跑，见 `project.yml` 脚本阶段） | `.swiftlint.yml` |
| **SwiftFormat** | 自动格式化 | `.swiftformat` |
| **EditorConfig** | 编辑器层缩进/换行统一 | `.editorconfig` |
| **XcodeGen** | 由 `project.yml` 生成工程，`.xcodeproj` 不入库 | `project.yml` |

安装见 [`MACOS_DEV.md`](MACOS_DEV.md)。提交前：`swiftformat . && make lint`。

---

## 2. 格式约定

- **缩进 4 空格**，禁用 Tab；行宽软上限 **140**。
- 文件以单个换行结尾，无行尾空白（EditorConfig 保证）。
- `import` 置于文件头注释之后，按字母序；`@testable` 放最后。
- 不写多余的 `self.`（闭包捕获等必要场景除外）。
- 设计系统中**刻意对齐的冒号**（`Theme.swift` 调色板）被保留——`colon` 规则已关闭，可读性优先。

## 3. 命名

- 类型 `UpperCamelCase`；方法/属性/枚举 case `lowerCamelCase`。
- SwiftData 实体用名词（`Trip` / `DayPlan` / `PlanItem`）；持久化枚举以 `String` 原始值存储（`statusRaw` + 计算属性 `status`），便于调试与迁移。
- 协议表能力：数据源 `POIDataSource`、能力 `LLMProvider`；桩实现前缀 `Stub*`。
- 布尔以 `is/has/should` 起头。

## 4. 架构分层（与 PDR §3 对应）

```
Views ──▶ ViewModels ──▶ Engine ──▶ Services(Client)
  └──────────── 依赖抽象协议，不依赖具体实现 ──────────┘
```

- 目录即分层：`App/ DesignSystem/ Models/ Services/ Features/`。
- **视图层零网络**：UI 只读 `@Query` / 绑定，不直接发请求。
- **依赖倒置**：引擎与视图依赖 `POIDataSource` / `LLMProvider` 协议，真实 client 落地后只换注入（PDR 架构缝）。
- 跨端差异用 `#if os(macOS)` / `#if os(iOS)` 局部隔离，共享主体代码。

## 5. SwiftUI

- 视图小而纯，复杂子视图拆成独立 `View` 或 `@ViewBuilder`，单个 `body` 表达式不堆叠到编译器无法及时类型推断。
- 颜色/字体/间距**只用** `Palette` / `Typo` / `Metric`，禁止散落魔法值。
- 状态最小化：`@State` 私有、`@Binding` 传递、`@Query` 直驱列表。

## 6. 并发与错误

- 现按 Swift 5 语言模式 + `SWIFT_STRICT_CONCURRENCY=minimal`；触及 UI 的类型标 `@MainActor`（如 `ItineraryEngine`）。
- 网络/IO 用 `async/await`；错误抛**领域错误**（如 `AmapError.quotaExceeded`），由上层决定降级/提示，**不静默吞错**。
- 失败要可恢复、可解释（对应设计文案原则：错误明确可恢复）。

## 7. 安全红线

- **API key 一律走 Keychain**（`KeychainStore`），严禁硬编码或明文落库；`Secrets.swift`、`.env`、`*.xcconfig.local` 已在 `.gitignore`。
- 不提交任何真实密钥、凭据文件或坐标外的个人数据。
- **提交前机密拦截**：首次克隆后执行 `make hooks`（= `git config core.hooksPath .githooks`），`pre-commit` 会扫描暂存内容、拦截密钥值（`sk-…`/`gh*_…`/私钥/AWS/Slack token 等）与凭据文件（`.env`/`*.pem`/`*.p12`/`*.mobileprovision`/`*.key`）。误报时 `git commit --no-verify`（谨慎）。

## 8. 注释与 TODO

- 文件头用简短注释说明职责与对应 PDR 任务号（沿用现有风格）。
- 未完成项写 `// TODO(PDR T3.2): …`，带任务号便于追踪；`todo` lint 规则已豁免。

## 9. 提交规范

- 信息用祈使句，建议 `类型: 摘要`，类型取 `feat/fix/refactor/docs/chore/test`。
- 一次提交一件事，可对应一个 PDR 任务号（如 `feat(T0.1): 多平台工程脚手架`）。
- `.xcodeproj` 由 XcodeGen 生成，**不提交**；改工程配置改 `project.yml`。
