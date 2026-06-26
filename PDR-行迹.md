# PDR · 行迹 Trailhead — AI 旅行行程生成器

> 个人自用的多平台 App：输入城市与偏好，基于**真实 POI** 自动生成可编辑的多日行程（景点 / 餐饮 / 住宿 / 交通）。
> 优先 macOS，复用到 iOS。Local-first，无自建后端。
>
> **文档用途**：本 PDR 同时面向你本人与 AI coding agent（Claude Code / Codex）。第 8 节的任务为原子化拆解，可逐条派给 agent 执行，每条带验收标准与依赖。
> **配套**：UI 设计稿见 `travel-app-ui.svg`（① macOS 主界面 ② 新建行程 ③ iOS 行程页 ④ 生成中 ⑤ 设置 ⑥ 组件规范）。

---

## 1. 产品概述

| 项 | 内容 |
|---|---|
| 一句话定位 | 输入城市+偏好，一键生成可编辑、可保存、可微调的多日行程 |
| 核心价值 | 把"做攻略"从数十分钟的跨平台检索，压缩到几十秒的结构化产出，且每个地点**有据可依**（高德真实 POI 兜底） |
| 目标用户 | 你自己（单用户） |
| 形态 | macOS + iOS 原生 App，一套 SwiftUI 代码 |
| 范围（MVP） | 本机运行、本机存储、本机直连 API；不分发、不上架、无账号体系 |
| 明确非目标 | ❌ 多用户/账号 ❌ 社交/UGC ❌ 在线预订支付 ❌ 自建服务端 ❌ 实时协同 |

### 设计原则
1. **真实优先，AI 编排**：LLM 只负责"怎么把这些地点排成一天"，不负责"凭空想出地点"——所有 POI 必须来自高德返回的候选集，从根上压制幻觉。
2. **可编辑 > 一次成型**：生成只是起点，行程要能拖动、增删、替换、重排，并持久化。这是相对夸克/秘塔等"一次性生成"产品的差异点。
3. **Local-first**：无网络也能看已生成的行程；API 只在生成/刷新时调用，结果落本地。
4. **零成本运行**：高德个人免费配额 + 本地缓存，自用永远在免费额度内。

---

## 2. 技术栈决策

| 层 | 选型 | 理由 | 备选 / 取舍 |
|---|---|---|---|
| UI 框架 | **SwiftUI**（macOS 14+ / iOS 17+） | 一套代码双端原生；`NavigationSplitView` 天然适配 mac 三栏、iOS 导航栈 | Flutter：你已熟，但 macOS 桌面观感弱于原生，地图/钥匙串需插件，无必要 |
| 语言 | Swift 5.9+ | 配合 SwiftData 宏、async/await | — |
| 持久化 | **SwiftData** | SwiftUI 原生、声明式、@Query 直驱 UI，适合 local-first | Core Data（更老更重）；GRDB（更可控但更多样板代码） |
| 网络 | URLSession + async/await | 标准库够用，无需第三方 | Alamofire（过度） |
| 凭据存储 | **Keychain** | API key 必须进钥匙串，不可硬编码/明文落库 | — |
| 地图显示 | **MapKit** | 系统原生、免费、双端一致；中国大陆同为 GCJ-02 坐标系，与高德 POI 坐标**直接兼容** | 高德 iOS SDK（更重，无必要） |
| POI / 路线数据 | **高德 Web 服务 API** | POI 丰富度国内最佳；个人免费配额；纯 HTTP，端无关 | 天地图（免费但 POI 弱）；OSM（海外才有优势） |
| 行程生成 | **DeepSeek API**（chat completions，JSON 输出） | 中文行程质量好、便宜；结构化输出稳定 | 通义/Kimi 等可平替，引擎层抽象为 `LLMProvider` |
| 架构模式 | MVVM + 服务层 | ViewModel 持有引擎，引擎编排各 Client | — |

### 关键技术注记
- **坐标系**：高德返回 **GCJ-02**；MapKit 在中国大陆也是 GCJ-02 → **境内 POI 坐标可直接打点，无需偏移纠正**。一旦未来引入海外/WGS-84 数据源，需在数据层做转换（预留 `CoordinateSystem` 标记字段）。
- **Key 安全边界**：自用、不分发，API key 由 Keychain 保管、客户端直连，可接受。**若日后要分发给他人**，必须在中间加一个轻代理（你现成的 Go 网关栈即可）替客户端持有 key，否则 key 会随 App 泄露。本 PDR 范围为自用，直连。
- **创建 Key 时"服务平台"必须选「Web 服务」**（非 JS API / SDK），否则 HTTP 接口调不通。Web 服务 key 用 `key` 参数即可，无需安全密钥。

---

## 3. 系统架构与数据流

```
┌─────────────────────────── SwiftUI App (macOS / iOS) ───────────────────────────┐
│                                                                                  │
│  Views ──▶ ViewModels ──▶ ItineraryEngine ─┬─▶ AmapClient   (POI/地理/路线)       │
│    ▲           │                            ├─▶ DeepSeekClient (行程编排)         │
│    │           ▼                            └─▶ FactChecker  (用高德数据校验 LLM)  │
│    └──── SwiftData (@Query) ◀── Repository ◀──────────── 落库 / 缓存              │
│                                                                                  │
│  KeychainStore (API keys)   ·   AmapClient 命中本地缓存优先                        │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### 生成流水线（核心，7 步）
1. **地理编码**：城市名 → `adcode` + 中心坐标（高德 `geo` / `config/district`）。
2. **POI 召回**：按兴趣标签分类调高德 POI 搜索（`place/text`、`place/around`），拉取景点/餐饮/住宿候选，带坐标、评分、营业时间、价格、类型。每类取 Top-N，去重。
3. **LLM 编排**：把**候选 POI 列表（含稳定 id）+ 用户偏好** 喂给 DeepSeek，要求输出结构化 JSON 行程；**硬约束：只能引用候选集里的 `poi_id`，不得新造地点**。
4. **路线补全**：对相邻 POI 调高德路径规划（`direction/transit|walking|driving`），填充交通方式、时长、距离、费用。
5. **事实校验**（FactChecker）：用高德原始字段覆盖 LLM 可能编造的坐标/营业时间/评分；丢弃任何 `poi_id` 不在候选集中的条目。
6. **落库**：组装成 `Trip → DayPlan → PlanItem / TransitSegment`，写入 SwiftData。
7. **渲染 + 编辑**：UI 用 @Query 直驱；用户的增删改重排实时写回。

> 第 3 步的"只能从候选集选"是整套设计的反幻觉支点。Prompt 约定见第 6 节。

---

## 4. 数据模型（SwiftData）

```swift
@Model final class Trip {
    var id: UUID
    var city: String
    var adcode: String
    var startDate: Date
    var nights: Int
    var prefs: TripPrefs            // 见下，@Model 或 Codable 内嵌
    var status: TripStatus          // draft / generating / ready / failed
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var days: [DayPlan]
}

@Model final class DayPlan {
    var id: UUID
    var dayIndex: Int               // 0-based
    var date: Date
    @Relationship(deleteRule: .cascade) var items: [PlanItem]   // 含 POI 与交通段，按 order 排序
}

@Model final class PlanItem {
    var id: UUID
    var order: Int
    var kind: ItemKind              // sight / food / lodging / transit
    // —— POI 字段（kind != transit 时）——
    var poiId: String?              // 高德 POI id（稳定引用）
    var name: String?
    var category: String?
    var lat: Double?
    var lng: Double?                // GCJ-02
    var rating: Double?
    var openHours: String?
    var address: String?
    var avgPrice: Int?
    var plannedTime: String?        // "09:00"
    var stayMinutes: Int?
    var note: String?               // LLM 给的一句话理由 / 贴士
    // —— 交通字段（kind == transit 时）——
    var transitMode: TransitMode?   // walk / metro / bus / taxi / drive
    var transitMinutes: Int?
    var transitMeters: Int?
    var transitCost: Int?
    var transitDesc: String?        // "地铁4号线 → 中医大省医院"
}

struct TripPrefs: Codable {
    var tags: [String]              // ["美食","历史"]
    var pace: Pace                  // tight / relaxed / casual
    var budgetPerDay: Int
    var freeText: String            // 补充要求
}
```
枚举：`TripStatus`、`ItemKind`、`TransitMode`、`Pace` 均为 `String` 原始值，便于持久化与调试。

POI 候选召回后先进**本地缓存表**（可单独 `@Model CachedPOI`，按 `adcode + category` 索引，TTL 例如 7 天），同城再次生成直接命中，省配额。

---

## 5. 外部接口规约

### 5.1 高德 Web 服务（base：`https://restapi.amap.com`）

| 用途 | 端点 | 关键参数 | 取用字段 |
|---|---|---|---|
| 城市定位 | `/v3/config/district` | `keywords=城市` | `adcode`、`center` |
| 关键字 POI | `/v5/place/text` | `keywords`、`region=adcode`、`types`、`page_size` | `id`、`name`、`location`、`type`、`address`、`business`(营业时间/评分/价格) |
| 周边 POI | `/v5/place/around` | `location`、`radius`、`types` | 同上 |
| 公交路线 | `/v5/direction/transit/integrated` | `origin`、`destination`、`city1`、`city2` | `duration`、`distance`、`segments`、`cost` |
| 步行/驾车 | `/v5/direction/walking`、`/driving` | `origin`、`destination` | `duration`、`distance` |

约定：所有请求带 `key`（取自 Keychain）；`output=json`；`place/text` 用 v5 并显式列 `show_fields=business,navi` 拿评分/营业时间。失败（含 `QUOTA_EXCEEDED`）→ 降级到缓存，UI 给明确提示，**不静默失败**。

### 5.2 DeepSeek（base：`https://api.deepseek.com`）
- `POST /chat/completions`，`model=deepseek-chat`，`response_format={"type":"json_object"}`。
- system prompt 强约束输出 schema 与"只能用候选 poi_id"。
- 超时 30s；失败重试 1 次；二次失败 → `status=failed`，UI 提示可重试。

---

## 6. 行程生成引擎（`ItineraryEngine`）

**输入**：`TripPrefs` + 候选 POI 列表（每条含 `poi_id, name, category, rating, openHours, lat, lng, avgPrice`）。

**LLM 约定（核心 prompt 要点）**：
- 角色：资深本地向导，按用户偏好把候选地点编排成 N 天行程。
- **硬规则**：① 只能引用给定候选集中的 `poi_id`，禁止杜撰；② 每天 4–6 个点，符合 `pace`；③ 同片区聚合，减少折返；④ 餐饮卡在饭点；⑤ 输出严格 JSON，结构为 `{ "days": [ { "day": 1, "items": [ { "poi_id": "...", "time": "09:00", "stay_min": 90, "note": "..." } ] } ] }`。
- 不在候选集的 `poi_id` 一律丢弃（FactChecker 兜底）。

**后处理**：
1. JSON 解析失败 → 重试一次（附上"仅返回 JSON"提醒）。
2. 校验每个 `poi_id` ∈ 候选集；非法项剔除。
3. 用候选集原始字段回填坐标/评分/营业时间（**以高德为准**，不信 LLM 的事实字段）。
4. 相邻 POI 调路径规划生成 `TransitSegment` 插入。
5. 组装实体落库。

---

## 7. UI 设计

> 全部界面见 `travel-app-ui.svg`。设计语言：Apple 原生中性灰 + **路线绿 `#1FA67A`** 作为唯一强调色；signature = **路线时间线**（行程即一条贯穿的路线，POI 为节点，节点间为交通段）。

### 信息架构
- **macOS**：`NavigationSplitView` 三栏 — 侧栏（行程库 + 新建 + 设置入口） / 中栏（选中行程的按天路线时间线） / 右栏 inspector（MapKit 地图 + 选中 POI 详情）。
- **iOS**：`TabView`（行程 / 新建 / 设置）+ `NavigationStack`；行程页为路线时间线，地图作为可推入的全屏页。

### 各界面（对应 SVG 编号）
1. **主界面**：左行程库（选中态蓝条），中路线时间线（POI 卡片串在绿色脊线上，卡片含 时间·名称·类型色点·停留时长·评分·营业），右地图（route polyline + 编号 pin）+ 底部 POI 详情卡（"在高德地图打开"）。
2. **新建行程**：目的地 / 天数 / 兴趣标签（chips 多选）/ 节奏（三段）/ 人均预算（slider）/ 补充要求（自由文本）→「生成行程」。
3. **iOS 行程页**：窄屏单列时间线 + 顶部天数 + 底部 tab bar。
4. **生成中**：进度环 + 分步状态（拉取 POI → 核验 → 编排），状态可见、可解释。
5. **设置**：高德 key / DeepSeek key（钥匙串、掩码显示）、本月配额进度、离线缓存开关与清除。
6. **组件规范**：POI 类型色（景点绿/餐饮橙/住宿紫/交通蓝灰/选中蓝）、POI 卡片、交通段、字体、圆角间距 token。

### 文案原则（取自设计规范）
- 动词即行为：「生成行程」「在高德地图打开」「清除全部数据」。
- 空态是邀请，不是装饰：行程库空时显示"还没有行程，从右上角新建一个吧"。
- 错误明确可恢复：配额耗尽显示"本月高德额度已用完，下月恢复；当前展示缓存数据"，而非泛泛报错。

---

## 8. 任务拆解（原子化，供 AI agent 执行）

> 约定：每个任务**单一职责、可独立验收**。`依赖` 指必须先完成的任务号。建议执行顺序即编号顺序。每完成一个，运行其验收标准再进入下一个。

### 阶段 0 · 脚手架
| # | 任务 | 产出 / 验收 | 依赖 |
|---|---|---|---|
| T0.1 | 创建多平台 Xcode 工程（macOS+iOS 双 target，共享 SwiftUI 代码） | 工程在两端均能空跑起来 | — |
| T0.2 | 建立目录结构：`Models/ Services/ Engine/ Views/ Stores/ Utils/` | 目录就位，README 注明分层 | T0.1 |
| T0.3 | 配置 SwiftData `ModelContainer`，注入 App 环境 | App 启动无报错，可写一条临时数据 | T0.1 |

### 阶段 1 · 数据与凭据层
| # | 任务 | 产出 / 验收 | 依赖 |
|---|---|---|---|
| T1.1 | 定义全部 `@Model` 实体与枚举（第 4 节） | 编译通过，关系与级联删除正确 | T0.3 |
| T1.2 | `CachedPOI` 缓存模型 + TTL 逻辑 | 写入/读取/过期单测通过 | T1.1 |
| T1.3 | `KeychainStore`：读写/删除两个 API key | 单测：写入后能读出，删除后为空 | T0.2 |
| T1.4 | `Repository`：Trip 的增删改查 + 重排封装 | CRUD 单测通过 | T1.1 |

### 阶段 2 · API 客户端
| # | 任务 | 产出 / 验收 | 依赖 |
|---|---|---|---|
| T2.1 | `AmapClient.geocodeCity()` → adcode+center | 输入"成都"返回正确 adcode | T1.3 |
| T2.2 | `AmapClient.searchPOI(types, region)`（v5 text/around，解析 business 字段） | 返回带评分/营业时间的候选数组 | T2.1 |
| T2.3 | `AmapClient.route(from,to,mode)`（transit/walking/driving） | 返回时长/距离/费用 | T2.1 |
| T2.4 | 统一错误处理：识别 `QUOTA_EXCEEDED` 等，抛领域错误 | 配额错误能被上层捕获并区分 | T2.2 |
| T2.5 | POI 召回命中 `CachedPOI` 优先，未命中再请求并回填缓存 | 二次同城请求 0 次网络调用 | T2.2, T1.2 |
| T2.6 | `DeepSeekClient.complete(messages, jsonMode)` | 返回可解析 JSON 字符串 | T1.3 |

### 阶段 3 · 生成引擎
| # | 任务 | 产出 / 验收 | 依赖 |
|---|---|---|---|
| T3.1 | `LLMProvider` 协议 + DeepSeek 实现（便于平替通义/Kimi） | 协议抽象清晰，可注入 mock | T2.6 |
| T3.2 | Prompt 构造器：拼接候选 POI + 偏好 + schema 约束（第 6 节） | 生成的 prompt 含全部硬规则 | T3.1 |
| T3.3 | JSON 解析 + 失败重试一次 | 故意坏 JSON 时能重试并恢复 | T3.2 |
| T3.4 | `FactChecker`：剔除非候选 poi_id，用高德字段回填事实 | 注入伪造 poi_id 被剔除 | T3.3, T2.2 |
| T3.5 | 路线补全：相邻 POI 调 `route()` 生成 `TransitSegment` | 每两个 POI 间有交通段 | T3.4, T2.3 |
| T3.6 | `ItineraryEngine.generate(prefs)` 串联全流程并落库 | 端到端：输入偏好→库里出现完整 Trip | T3.5, T1.4 |
| T3.7 | 引擎进度回调（拉取/核验/编排三阶段） | UI 能订阅到阶段变化 | T3.6 |

### 阶段 4 · UI 骨架与导航
| # | 任务 | 产出 / 验收 | 依赖 |
|---|---|---|---|
| T4.1 | macOS `NavigationSplitView` 三栏骨架 | 三栏可见、可选中切换 | T1.1 |
| T4.2 | iOS `TabView` + `NavigationStack` 骨架 | 三 tab 可切换 | T1.1 |
| T4.3 | 侧栏行程库（@Query 列表 + 选中态 + 删除） | 列表随数据更新 | T1.4, T4.1 |

### 阶段 5 · 核心界面
| # | 任务 | 产出 / 验收 | 依赖 |
|---|---|---|---|
| T5.1 | **路线时间线**组件（脊线+节点+POI卡片+交通段，类型色） | 对照 SVG①③ 还原，复用于双端 | T4.1, T4.2 |
| T5.2 | 天数切换（D1–Dn tab） | 切换显示对应 DayPlan | T5.1 |
| T5.3 | 新建行程表单（标签/节奏/预算/文本）→ 调 `engine.generate` | 对照 SVG②，提交触发生成 | T3.6, T4.3 |
| T5.4 | 生成中状态页（进度环 + 分步） | 对照 SVG④，订阅 T3.7 进度 | T3.7, T5.3 |
| T5.5 | 右栏/iOS 全屏 MapKit：route polyline + 编号 pin + 选中联动 | 点节点地图高亮对应 pin | T5.1 |
| T5.6 | POI 详情卡 + "在高德地图打开"（URL scheme） | 跳转高德 App/网页正确 | T5.5 |

### 阶段 6 · 编辑与持久化
| # | 任务 | 产出 / 验收 | 依赖 |
|---|---|---|---|
| T6.1 | 时间线内重排 POI，写回 order | ✅ 已接编辑态保存；重排后重启仍保持 | T5.1, T1.4 |
| T6.2 | 删除 / 替换某 POI（替换时从候选集再选） | ✅ 删除/替换后重算当天路线已接 | T6.1, T3.5 |
| T6.3 | 单日重新生成（仅重排当天，不动其他天） | 只有当天变化 | T3.6, T6.2 |

### 阶段 7 · 设置与凭据 UI
| # | 任务 | 产出 / 验收 | 依赖 |
|---|---|---|---|
| T7.1 | 设置页：两个 key 输入（掩码）写入 Keychain | 对照 SVG⑤，重启后仍在 | T1.3 |
| T7.2 | 配额用量展示（读高德返回的额度信息或本地计数） | 进度条反映调用量 | T2.4 |
| T7.3 | 缓存开关 + 清除缓存 + 清除全部数据 | 清除后库为空、缓存空 | T1.2, T7.1 |

### 阶段 8 · 打磨
| # | 任务 | 产出 / 验收 | 依赖 |
|---|---|---|---|
| T8.1 | 空态 / 加载态 / 错误态文案（第 7 节原则） | 三态均有明确文案 | T5.* |
| T8.2 | 配额耗尽降级到缓存 + 横幅提示 | 模拟配额错误时仍可看缓存行程 | T2.4, T8.1 |
| T8.3 | 无网可读已生成行程（local-first 验证） | 断网启动能浏览历史行程 | T1.4 |
| T8.4 | 双端布局自适应回归（mac 缩窗 / iPhone 小屏） | 无截断、无重叠 | 全部 UI |

---

## 9. 里程碑

- **M1（数据闭环）**：T0–T3.6 完成 → 命令行/单测能"输入成都偏好 → 库里出现完整可信行程"。
- **M2（可用 App）**：+ 阶段 4–5 → macOS 上完整走通"新建→生成→查看（时间线+地图）"。
- **M3（自用就绪）**：+ 阶段 6–8 → 可编辑、可保存、可离线、设置完善；iOS 端跑通。

**MVP 验收场景**：钥匙串填好两个 key → 新建"成都/4天/美食+历史/慢节奏/¥600" → 数十秒生成 4 天路线时间线，每点可在地图定位、可"在高德打开" → 拖动重排某天 → 重启后行程仍在 → 断网仍可浏览。

---

## 10. 风险与待定决策

| 项 | 说明 | 当前取向 |
|---|---|---|
| LLM 幻觉 | 即便约束 poi_id，仍可能排出不合理顺序/时间 | FactChecker 兜底 + 可编辑修正；后续可加"营业时间冲突检测" |
| 高德 v5 字段差异 | `business` 字段在不同 POI 类型下完整度不一 | 解析做容错，缺失字段不阻塞生成 |
| 评分/价格数据 | 高德 POI 的评分/人均不如大众点评全 | MVP 接受；③层 UGC 不在自用范围，必要时人工补 |
| key 分发风险 | 仅当未来分发才需代理 | 自用直连；分发再上 Go 网关 |
| LLM 供应商 | DeepSeek 可能限流 | 引擎已抽象 `LLMProvider`，可热切通义/Kimi |
| 海外城市 | 高德海外 POI 弱、坐标系不同 | MVP 限国内；海外另议（OSM/Wikivoyage + 坐标转换） |

---

## 11. 实施进度（设计稿落地后）

已基于 Claude Design handoff(`Trailhead.dc.html`)完成 SwiftUI 设计还原切片,代码见同目录 `Trailhead/`。

| 阶段 | 任务 | 状态 | 说明 |
|---|---|---|---|
| 0 | T0.1–T0.3 脚手架 / 容器 | ✅ 完成 | 多平台工程、目录分层、SwiftData 容器 + 首启动播种 |
| 1 | T1.1 数据模型 | ✅ 完成 | Trip/DayPlan/PlanItem + 枚举 + 类型→色映射 |
| 1 | T1.3 Keychain | ✅ 完成 | 真实读写实现 |
| 1 | T1.2 CachedPOI / T1.4 Repository | ⬜ 待办 | 接入引擎时补 |
| 2 | T2.* 高德 Client | 🟡 占位 | `POIDataSource` 协议 + `StubPOISource`;真实实现见 §12 |
| 3 | T3.* 生成引擎 | 🟡 占位 | `ItineraryEngine` 骨架 + `LLMProvider` 协议;流水线见 §12 |
| 4 | T4.1–T4.3 导航骨架 | ✅ 完成 | macOS 三栏 / iOS Tab 自适应 + 侧栏 |
| 5 | T5.1–T5.6 核心界面 | ✅ 完成 | 路线时间线 signature、天数切换、新建表单、生成中、地图+详情 |
| 6 | T6.* 编辑/重排 | 🟡 部分 | T6.1 POI 重排已写回;T6.2 删除/替换并重算已接;T6.3 单日重生成待补 |
| 7 | T7.* 设置 | 🟡 部分 | API/用量/缓存 UI 已完成;T7.1 两把 key 已写入 Keychain;T7.2 用量与 T7.3 清理待接入 |
| 8 | T8.* 打磨 | 🟡 部分 | 空态已做;离线降级/回归待补 |

**架构缝**:`POIDataSource` / `LLMProvider` 为协议,视图与引擎均依赖抽象。真实 client 落地后只替换注入,视图层零改动。

## 12. 下一阶段详化（可直接交给 Claude Code 执行）

### 12.1 AmapClient(实现 `POIDataSource`,PDR T2)

```swift
struct AmapClient: POIDataSource {
    private let base = URL(string: "https://restapi.amap.com")!
    private var key: String { KeychainStore.get(KeychainStore.Account.amap) ?? "" }
}
```

| 方法 | 端点 | 关键参数 | 解析 |
|---|---|---|---|
| `geocodeCity` | `/v3/config/district` | `keywords`,`subdistrict=0` | `districts[0].adcode` / `.center`("lng,lat") |
| `searchPOI` | `/v5/place/text` | `keywords`(按 tag 映射类目),`region=adcode`,`city_limit=true`,`show_fields=business,navi`,`page_size=25` | `pois[].{id,name,location,type,business.{rating,opentime2,cost}}` |
| `route` | `/v5/direction/{transit/integrated,walking,driving}` | `origin`,`destination`(GCJ-02 "lng,lat") | `route.{distance,duration,cost}` |

实现要点:① 所有请求带 `key` + `output=json`;② 解析 `business` 字段做容错(缺失不阻塞);③ 识别 `infocode == "10044"/状态非 1` 抛 `AmapError.quotaExceeded`,上层降级缓存;④ tag→amap 类目码用一张静态映射表(美食=050000、景点=110000、住宿=100000…)。

**验收**:`searchPOI(adcode:"110100", tags:["美食","历史古迹"])` 返回非空且每条含坐标。

### 12.2 ItineraryEngine 真实流水线(PDR T3)

`generate(prefs:destination:)` 按 PDR §3 七步实现,并驱动 `@Published var stage/progress`(`GeneratingView` 已可绑定):

1. `geocodeCity` → adcode/center,`stage=.analyzing`
2. `searchPOI` 按 tag 召回候选,去重取 Top-N(命中 `CachedPOI` 优先)
3. 构造 prompt:候选 POI(含稳定 id)+ 偏好 + JSON schema,**硬约束只能引用候选 `poi_id`**;调 `LLMProvider.planItinerary`,`stage=.routing`
4. 解析 JSON;失败重试一次(追加"仅返回 JSON")
5. **FactChecker**:剔除非候选 `poi_id`;用高德原始字段回填 name/坐标/营业时间(以高德为准),`stage=.dining`
6. 相邻 POI 调 `route` 生成 `PlanItem(kind:.transit)` 插入,`stage=.transit`
7. 组装 `Trip→DayPlan→PlanItem` 落 SwiftData,`stage=.budgeting`→`.done`

**Prompt schema(LLM 必须严格输出)**
```json
{ "days": [ { "day": 1, "items": [
  { "poi_id": "B0FF...", "time": "09:00", "stay_min": 90, "note": "千本鸟居 早到" }
] } ] }
```

**验收**:输入"成都/4天/美食+历史/慢节奏" → 库中出现 ≥4 天、每天 4–6 点、每个 `poi_id` 均 ∈ 候选集、相邻点间有交通段的完整 Trip;期间 `GeneratingView` 分步推进。

### 12.3 之后

T6.3 单日重新生成、T7.2 真实用量统计、T8.2 配额降级横幅。顺序仍按 §8 编号推进。
