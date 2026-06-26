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
└─ Trailhead/                      源码（XcodeGen sources 根）
   ├─ App/                         @main 入口 + SwiftData 容器 + 首启动播种     [T0.1 T0.3]
   ├─ DesignSystem/                颜色/字体/间距 token（Theme）                [设计系统 / Utils]
   ├─ Models/                      SwiftData 实体 + 枚举 + 示例数据             [T1.1]
   ├─ Services/                    Keychain(真实) + POIDataSource/LLMProvider
   │                               协议桩 + ItineraryEngine 骨架               [T1.3 / T2 / T3]
   ├─ Features/                    各界面（视图层，按功能分组）
   │  ├─ Root/                     macOS 三栏 / iOS Tab 自适应外壳              [T4.1 T4.2]
   │  ├─ Sidebar/                  行程库侧栏                                   [T4.3]
   │  ├─ Timeline/                 路线时间线 signature + 地图 inspector        [T5.1 T5.5]
   │  ├─ NewTrip/                  新建行程表单                                 [T5.3]
   │  ├─ Generating/              生成中（进度环 + 分步）                       [T5.4]
   │  └─ Settings/                 API / 用量 / 缓存                            [T7.*]
   └─ Assets.xcassets/             AppIcon 占位 + 品牌 AccentColor #1FA67A
```

### 分层职责（数据流：Views → ViewModels → Engine → Services）

| 层 | 位置 | 职责 | PDR 对应 |
|---|---|---|---|
| **App** | `App/` | 入口、`ModelContainer` 注入、首启动播种 | §3 / T0.3 |
| **Models** | `Models/` | SwiftData 实体（`Trip`/`DayPlan`/`PlanItem`）、枚举 | §4 / T1.1 |
| **Services** | `Services/` | `KeychainStore`（凭据）、`POIDataSource`/`LLMProvider` 协议 + 桩 | §5 / T1.3 T2 |
| **Engine** | `Services/Services.swift` | `ItineraryEngine` 生成流水线（骨架） | §6 / T3 |
| **Views** | `Features/` | SwiftUI 界面，`@Query` 直驱、只读状态、零网络 | §7 / T4 T5 |
| **DesignSystem** | `DesignSystem/` | `Palette`/`Typo`/`Metric` 设计 token | §7 组件规范 |

> **架构缝**：视图与引擎只依赖 `POIDataSource` / `LLMProvider` 协议，目前注入 `Stub*`。
> 真实 `AmapClient` / `DeepSeekClient` 落地后只替换注入，**视图层零改动**（PDR §11）。

---

## 开发规范

- **代码规范**：[`docs/CODE_STYLE.md`](docs/CODE_STYLE.md)。提交前 `swiftformat . && make lint`，CI 同样校验。
- **机密**：API key 一律走 Keychain，严禁硬编码/落库；`make hooks` 启用提交前拦截。
- **改工程配置**：改 `project.yml` 后 `xcodegen generate`，不要手改 `.pbxproj`。

## 进度

脚手架与设计还原已完成（T0–T1.1/T1.3、T4、T5、T7 UI）；真实 `AmapClient`、
`ItineraryEngine` 流水线为下一阶段（PDR §12）。详见 [`PDR-行迹.md`](PDR-行迹.md) §11。
