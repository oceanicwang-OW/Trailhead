# 行迹 Trailhead

输入城市与偏好，基于**真实 POI** 自动生成可编辑的多日行程（景点 / 餐饮 / 住宿 / 交通）。
macOS + iOS 原生 App，一套 SwiftUI 代码，Local-first，无自建后端。

> 完整产品设计见 [`PDR-行迹.md`](PDR-行迹.md)。开发上手见下文与 [`docs/`](docs/)。

[![CI](https://github.com/oceanicwang-OW/Trailhead/actions/workflows/ci.yml/badge.svg)](https://github.com/oceanicwang-OW/Trailhead/actions/workflows/ci.yml)

---

## 快速开始

```bash
brew install xcodegen swiftlint swiftformat   # 工具链（一次性）
make doctor                                   # 校验工具链
make hooks                                    # 启用提交前机密拦截
make open                                     # 生成工程并打开 Xcode → ⌘R
```

要求：macOS 14+ / Xcode 26.x。详见 [`docs/MACOS_DEV.md`](docs/MACOS_DEV.md)。
首次启动自动播种「关西环游」示例，界面即还原设计稿。

---

## 目录结构与分层

工程按 **MVVM + 服务层**（PDR §3）组织，目录即分层。`.xcodeproj` 由 `project.yml`
经 XcodeGen 生成、**不入库**。

```
Trailhead/
├─ project.yml                     XcodeGen 工程定义（单 target，macOS+iOS）   [T0.1]
├─ Makefile                        doctor / build / lint / format / hooks
├─ .swiftlint.yml .swiftformat     代码规范（SwiftLint 构建期自动跑）
├─ .githooks/pre-commit            提交前机密拦截（密钥/凭据不入库）
├─ docs/                           CODE_STYLE.md · MACOS_DEV.md
├─ Packages/TrailheadCore/         纯逻辑层 Swift Package（无 UI 依赖）
│  ├─ Sources/TrailheadCore/       Models / Services / Stores / Clients   [T1 / T2 / T3]
│  │  ├─ Models.swift              SwiftData 实体 + 枚举                   [T1.1]
│  │  ├─ CachedPOI.swift           POI 缓存实体                            [T1.2]
│  │  ├─ POICache.swift            (adcode,category) 缓存 + TTL            [T1.2]
│  │  ├─ TripRepository.swift      Trip CRUD + 重排                        [T1.4]
│  │  ├─ Services.swift            Keychain + POIDataSource/LLMProvider 协议 + 桩
│  │  ├─ AmapClient.swift          高德 Web 服务（geocode/POI/route + 错误） [T2.1–2.4]
│  │  ├─ POIRecall.swift           缓存优先 POI 召回                        [T2.5]
│  │  ├─ DeepSeekClient.swift      LLM 补全（重试 + jsonMode）             [T2.6]
│  │  ├─ PromptBuilder.swift       行程编排 prompt（候选+偏好+schema）      [T3.2]
│  │  ├─ ItineraryPlan.swift       LLM 输出结构 + 解析（围栏容错/重试）     [T3.3]
│  │  ├─ FactChecker.swift         剔除非候选 poi_id、候选字段为准回填       [T3.4]
│  │  └─ ItineraryEngine.swift     七步流水线 generate() + 进度            [T3.5–3.7]
│  └─ Tests/TrailheadCoreTests/    hostless 单测（XCTest，macOS 秒级，55 个）[T1 T2 T3]
└─ Trailhead/                      App 源码（XcodeGen sources 根；依赖 TrailheadCore）
   ├─ App/                         @main 入口 + SwiftData 容器 + 首启动播种     [T0.1 T0.3]
   ├─ DesignSystem/                颜色/字体/间距 token + ItemKind→色映射       [设计系统]
   ├─ Models/SampleData.swift      首启动播种的「关西环游」示例
   ├─ Features/                    各界面（视图层，按功能分组）
   │  ├─ Root/                     macOS 三栏 / iOS Tab 自适应外壳              [T4.1 T4.2]
   │  ├─ Sidebar/                  行程库侧栏                                   [T4.3]
   │  ├─ Timeline/                 路线时间线 signature + 地图 inspector        [T5.1 T5.5]
   │  ├─ NewTrip/                  新建行程表单                                 [T5.3]
   │  ├─ Generating/              生成中（进度环 + 分步）                       [T5.4]
   │  └─ Settings/                 API / 用量 / 缓存                            [T7.*]
   └─ Assets.xcassets/             AppIcon 占位 + 品牌 AccentColor #1FA67A
└─ TrailheadTests/                 App 单测（Settings Keychain 等 UI 状态逻辑）
```

### 分层职责（数据流：Views → ViewModels → Engine → Services）

| 层 | 位置 | 职责 | PDR 对应 |
|---|---|---|---|
| **App** | `Trailhead/App/` | 入口、`ModelContainer` 注入、首启动播种 | §3 / T0.3 |
| **Models** | `TrailheadCore/Models.swift` | SwiftData 实体（`Trip`/`DayPlan`/`PlanItem`）、枚举 | §4 / T1.1 |
| **Stores** | `TrailheadCore/{POICache,TripRepository}.swift` | POI 缓存 + Trip 仓储/重排 | §4 / T1.2 T1.4 |
| **Services/Engine** | `TrailheadCore/Services.swift` | `KeychainStore`、数据源/LLM 协议 + 桩、`ItineraryEngine` 骨架 | §5 §6 / T1.3 T2 T3 |
| **Views** | `Trailhead/Features/` | SwiftUI 界面，`@Query` 直驱、只读状态、零网络 | §7 / T4 T5 |
| **DesignSystem** | `Trailhead/DesignSystem/` | `Palette`/`Typo`/`Metric` token + `ItemKind` 着色 | §7 组件规范 |

> 纯逻辑（Models/Stores/Services）抽进 **TrailheadCore** 本地 Swift Package：与 SwiftUI 解耦，
> 单测 hostless（`xcodebuild test -scheme TrailheadCore -destination platform=macOS`，秒级、CI 稳定）。

> **架构缝**：视图与引擎只依赖 `POIDataSource` / `LLMProvider` 协议，目前注入 `Stub*`。
> 真实 `AmapClient` / `DeepSeekClient` 落地后只替换注入，**视图层零改动**（PDR §11）。

---

## 开发规范

- **代码规范**：[`docs/CODE_STYLE.md`](docs/CODE_STYLE.md)。提交前 `swiftformat . && make lint`，CI 同样校验。
- **机密**：API key 一律走 Keychain，严禁硬编码/落库；`make hooks` 启用提交前拦截。
- **改工程配置**：改 `project.yml` 后 `xcodegen generate`，不要手改 `.pbxproj`。

## 进度

> 单测：**55 个 Core + 3 个 App 全过**（`make test`）；CI 双端 build + lint 绿。
> **M1 数据闭环达成**：端到端「输入偏好 → 库里出现完整可信行程」已通过（mock 注入）。

| 阶段 | 任务 | 状态 |
|---|---|---|
| 0 脚手架 | T0.1 工程 / T0.2 分层 / T0.3 容器 | ✅ |
| 1 数据/凭据 | T1.1 模型 · T1.2 CachedPOI+TTL · T1.3 Keychain · T1.4 Repository | ✅ |
| 2 API 客户端 | T2.1 geocode · T2.2 searchPOI · T2.3 route · T2.4 错误 · T2.5 缓存优先召回 · T2.6 DeepSeek | ✅ |
| 3 生成引擎 | T3.1 LLMProvider · T3.2 Prompt · T3.3 解析重试 · T3.4 FactChecker · T3.5 路线补全 · T3.6 generate 串联 · T3.7 进度 | ✅ |
| 4–5 UI | 导航骨架 / 路线时间线 / 新建 / 生成中 / 地图（设计还原） | ✅ UI |
| 引擎接线 | NewTrip→`engine.generate()`、GeneratingView 订阅 stage/progress、注入真实 client、错误提示 | ✅ |
| 6 编辑重排 | T6.1 POI 重排已接 / T6.2 删除与替换并重算已接 / T6.3 单日重生成已接 | ✅ |
| 7 设置 | T7.1 key 写入 ✅ / T7.2 用量统计 ✅ / T7.3 清除缓存 + 清除全部数据 ✅ | ✅ |
| 8 打磨 | T8.1 空态✅ / T8.2 配额降级横幅✅ / T8.3 离线可读✅ / T8.4 双端回归 | 🟡 |

引擎已接进 UI：`RootView` 持有 `ItineraryEngine`，「生成行程」→ 生成中（真实分步进度）→ 选中新行程；
无 key / 配额 / 无候选等错误有明确文案。设置页已可把高德 Web 服务 Key 与 DeepSeek Key 写入 Keychain；
填好两把 key 后即可真实生成。后续按顺序做 T7.2 用量、T8 离线降级。详见 [`PDR-行迹.md`](PDR-行迹.md) §11–§12。
