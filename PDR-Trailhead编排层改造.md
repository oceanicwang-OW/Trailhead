# PDR｜Trailhead 编排层改造（LLM 盲排 → 确定性几何）

> 文档类型：增量 Product / Project Design Requirements
> 目标读者：Claude Code（CLI 落地）+ 主程审阅
> 基线：当前 `main`（commit 1d7a978），`Packages/TrailheadCore`
> 范围原则：**只改编排层**。召回（`POIRecall`）、筛选（`CandidateCuration`）、UI、交互（删除/替换/重生成）、缓存、`AmapClient` 一律不动接口。
> 兼容原则：`ItineraryDayBuilder.planStops(prefs:candidates:days:llm:)` 与 `PlannedStop` 结构签名**保持不变**，仅替换内部实现与字段来源语义。

---

## 1. 背景与诊断

现状线路"很一般"的根因不在选点，在**编排**。当前 `planStops` 的实现是：

```
planWithRetry(LLM 生成 days/items/time)  →  FactChecker.reconcile(只校验 poi_id 存在)
```

即：DeepSeek 在只有坐标文本、无地理分组的情况下，**盲排** POI 的顺序、分天与时间；`FactChecker` 只保证「引用的点存在」，从不校验几何与时间。结果可预期：日内东跑西跑、闭馆后到达、跨海误判、时间靠 LLM 拍脑袋。

`5317e28` 已经把「**选哪些点**」从 LLM 收回成确定性规则（`CandidateCuration`）——方向正确，但只走了一半。本 PDR 把剩下一半走完：**把「怎么排」也从 LLM 收回成确定性算法**（聚类分天 → 簇内 2-opt → 营业窗前向模拟），DeepSeek 降级为只写 `note` 文案。

**不需要引入 OR-Tools。** 城市尺度、每天 4–6 点、无酒店锚点的开放路径，贪心 + 2-opt 已足够，且能复用你现成的 `haversineMeters`。

---

## 2. 改造范围与边界

| 改动类型 | 对象 |
|---|---|
| 新增模块 | `StayDuration`、`OpenHoursParser`、`GeoProjection`、`DayClusterer`、`DayRouter`、`MealSlotter`、`TravelEstimator`、`ScheduleSimulator`、`ItineraryFeasibility`、（可选）`NoteWriter` |
| 改写内部实现（签名不变） | `ItineraryDayBuilder.planStops` |
| 小修 | `CandidateCuration.score`（P0 止血）、`ItineraryDayBuilder.mode()`（阈值 bug） |
| 语义变化（结构不变） | `PlannedStop.time` / `.stayMin` 改由**模拟器计算**而非 LLM；`.note` 改由可选 LLM 文案 pass 或留空 |
| **不动** | `POIRecall`、`CandidateCuration.curate` 主体、`AmapClient`、`TripRepository`、`NearbyFood`、UI/交互、`buildItems` 的对外行为 |

`FactChecker.reconcile` 在此路径不再需要（新流程永不离开候选集），保留为空守卫或从 `planStops` 移除，见 T6.2。

---

## 3. 目标编排流水线（新 `planStops` 内部）

签名不变，内部替换为确定性 6 步：

```
输入: prefs, candidates(已 curate), days, llm(仅供可选文案)
 1. 按 kind 拆分： sights(含 other) / food
    ↳ `other`（非景非食非住，curated top-K）**并入 sights 一起参与聚类与排序**（B1）：它们同样占据日内动线时间，不能像餐饮那样后插；`StayDuration` 对 other 给默认 60。若未来要「other 不排进动线」，应在 `CandidateCuration` 就不给 other 留 limit，而非在此静默丢弃。
 2. DayClusterer(sights, days)        → 每天的景点组（空间成团、容量均衡）
 3. 逐天：DayRouter 排序（贪心NN + 2-opt，haversine，开放路径）
 4. 逐天：MealSlotter 插入午/晚餐（就近 + 高分，卡饭点）
 5. 逐天：ScheduleSimulator 前向模拟 → 赋 time/stayMin + 营业窗过滤
 6. 组装 [[PlannedStop]]（Int 分钟 → "HH:mm"）；note 留空或走可选 NoteWriter(P7)
输出: [[PlannedStop]]（time 单调、营业窗内、无回头路）
```

DeepSeek 被彻底移出 2–5 步（几何）。真实交通段仍由既有 `buildItems → source.route` 在其后逐段计算（本流水线的旅行时间只用**估算**排序与卡点，见 §9 风险）。

---

## 4. 模块详设

### 4.1 [P0] `CandidateCuration.score` 止血
- 问题：`(c.rating ?? 0)` 使高德**常缺 rating 的招牌景点**综合分为 0，被有评分的平庸点挤出 top-K，根本进不了编排。`PromptBuilder.unratedScore = 4.0` 的补丁在 curate **之后**才生效，救不回来。
- 改动：`(c.rating ?? neutralRating)`，`neutralRating` 默认 `4.0`，**取值对齐现有 `PromptBuilder.unratedScore = 4.0`**（同一「无评分中性分」语义只应有一个真源，建议后续把两处收敛为同一常量）。取 4.0 而非更低值，是因为 P0 的目标正是保护「有名却常缺评分的招牌点」——4.0 高于多数平庸点的真实评分，能把招牌点顶回 top-K；取 3.5 保护力度不足。取值可配。
- 约束：仅改 `score`，不改 `curate` 的分类/limit 逻辑。
- 独立可先行合入。

### 4.2 `StayDuration`（停留时长先验）
- 职责：`kind` / `subtype`（+ `pace`）→ 默认停留分钟数（LLM 不再给 `stay_min`）。
- 契约：`duration(for candidate, pace:) -> Int`。
- 基准先验（可配）：景点 90、博物馆/展馆 120、公园/自然 120、餐饮 60、其它 60。`subtype` 命中优先于 `kind`。
- **pace 系数（B2）**：`TripPrefs.pace` 缩放基准时长——`tight ×0.8`、`relaxed ×1.0`、`casual ×1.2`（可配）。否则「紧凑」和「随性」排出的每点停留一样，用户偏好落空。
- 纯函数，便于单测。

### 4.3 `OpenHoursParser`（营业时间解析，容错优先）
- 输入：`POICandidate.openHours: String?`（高德 opentime2 原始串，脏且缺失率高）。
- 输出：`[(open: Int, close: Int)]?`，单位为「当日分钟数」；`nil` = 未知。
- 规则：解析 `HH:mm-HH:mm`，多段用 `;,、` 分隔；识别「全天/24 小时」→ 全天；跨夜（close<open）→ 视为全天。
- **保守铁律**：解析失败或缺失一律返回 `nil`，下游**不过滤**（宁可不筛，绝不误杀招牌）。

### 4.4 `GeoProjection` + `DayClusterer`（聚类分天）
- `GeoProjection`：经纬度 → 局部平面米（等距近似，以候选质心为原点），供聚类/距离用。
- `DayClusterer`：
  - 输入：`sights: [POICandidate]`（已含 other）、`days`、`maxSightsPerDay`。
  - 输出：`[[POICandidate]]`，长度 = `days`，每天空间成团、数量均衡。
  - `maxSightsPerDay` 由 pace 决定（B2）：`tight 5 / relaxed 4 / casual 3`（可配），而非写死 4；与 §4.2 停留时长共同表达「紧凑↔随性」。
  - 算法：k-means（k=days，投影坐标，迭代 ~10 取质心）→ **容量约束分配**：每簇容量 = `clamp(ceil(N/days), [2, maxSightsPerDay])`，按「到最近质心距离」升序（或 regret = 次近−最近 降序）逐点分配，满则退最近可用簇。
  - 天序（可选）：对各簇质心跑一次 NN 路径，使相邻两天地理相邻。
  - **景点少于天数的边界（B3）**：当 `sights.count < days` 时 k-means 必产空簇、无法「每天 ≥1」。策略：`k = min(days, sights.count)` 先聚出非空簇，剩余天数留作**轻量天**（仅靠 MealSlotter 的餐饮 + 就近推荐填充，允许「无景点日」），**不抛错**。仅 `sights` 完全为空时才抛 `EngineError.noCandidates`（已有）。
  - 约束：`sights.count ≥ days` 时每天 ≥1 景点、均衡 ±1；`sights.count < days` 时按上条降级。

### 4.5 `DayRouter`（簇内排序）
- 输入：某天景点 `[POICandidate]`、可选 `entryAnchor`（上一天出口坐标，用于天间衔接）。
- 输出：有序 `[POICandidate]`（**开放路径**，无固定起终点）。
- 算法：从锚点（或簇内最西/最高分点）起做**贪心最近邻**建初始序，再 **2-opt** 迭代消交叉至无改进（步数上限兜底）。距离用 `haversineMeters`。
- 复杂度：每天 ≤6 点，可忽略。

### 4.6 `MealSlotter`（餐饮卡点）
- 输入：某天已排序景点、`foodPool`（curated food + 就近，可复用 `NearbyFood.pick` 选源）、午/晚餐时段窗、已用 poi 集合。
- 输出：插入 ≤1 午餐 + ≤1 晚餐后的有序停留序列。
- 算法：按行程进度定位午/晚时刻附近的景点坐标 → 选**就近 + 高分**、未被使用的餐饮候选，插入到对应序号位置。
- 约束：单餐去重；当天时长不足以覆盖某餐窗则跳过该餐（短行程单餐）。

### 4.7 `TravelEstimator` + `ScheduleSimulator`（时间模拟 + 可行性）
- `TravelEstimator`：`haversineMeters` × 模式速度 → 分钟（步行/公交/驾车各一档速度）。用于**排序与卡点**的时间估算，非最终展示（展示仍走真实 `source.route`）。
  - **每段用哪一档速度（B4）**：由**修正后的** `mode()`（见 T6.3，先修好水域误判再复用）对该段选出 `TransitMode`，再取对应速度档。二者共用同一 `mode()`，避免估时与展示两套逻辑各判各的。
- `ScheduleSimulator`：
  - 时间量纲：内部一律用「当日分钟数」Int 运算；**仅在 §3 第 6 步装配 `PlannedStop` 时**转成 `"HH:mm"` 字符串（`PlannedStop.time` 为 `String?`）。§7 的「time 严格递增」在装配前用 Int 比较，避免字符串比较踩格式坑（B5）。
  - 输入：某天有序停留（景点+餐饮）、`dayStart`（默认 09:00，可配）、`dayEnd`（默认 20:00）、`StayDuration`、`OpenHoursParser` 结果、`TravelEstimator`。
  - 算法（前向模拟）：`t = dayStart`；逐点：`arrival = t + travel(prev→cur)`；
    - `openHours` 已知且 `arrival > close` → **不可行**：尝试与相邻点交换前移，仍不可行则**丢弃**该点；
    - `arrival < open` → 等待，`t = open`；
    - 落位：`stop.time = arrival`，`t = arrival + stayMin`；
    - `t > dayEnd` → 截断当天尾部超额点。
  - 输出：赋好 `time` / `stayMin` 且**营业窗内、时间单调**的停留序列。
- 意义：`time` 由此**确定性产出并可行**，取代 LLM 未经校验的时间。

### 4.8 `planStops` 重接线（核心改动，签名不变）
- 保持 `planStops(prefs:candidates:days:llm:) async throws -> [[PlannedStop]]`。
- 内部替换为 §3 六步。`days == 1`（单日重生成，`b58104e`）走同一路径：对该天候选跳过分天、直接 4.5→4.7。
- `llm` 参数在几何步骤**不使用**；仅当启用 P7 时传给 `NoteWriter`。**若 P7 不做本期**（见未决②），签名仍保留 `llm` 以维持对外契约不变，函数体内 `_ = llm` 消除未使用告警（C3）。
- **线程约束（C2）**：`planStops` 与所有新增几何模块保持**纯函数、不触碰 `ModelContext`/`@MainActor`**，延续 `e3ef60c` 修复的「ModelContext 跨线程」崩溃；建 `PlanItem` 仍只在既有 `buildItems(@MainActor)` 内进行。

### 4.9 [可选] `NoteWriter`（LLM 降级为文案）
- 输入：**已定稿**的 `[[PlannedStop]]`（选点/顺序/时间已锁死）。
- 输出：每个 stop 的一句 `note` + 每天主题标题。
- 铁律：LLM **不得**改选点、顺序、时间；输出若引用当天集合外的点，忽略；`note` 仅作展示文本。畸形输出重试 1 次后留空，不阻塞。

---

## 5. 参数与约束（可配置汇总）

| 参数 | 默认 | 说明 |
|---|---|---|
| `neutralRating` | 4.0 | 无评分中性分（P0，对齐 `PromptBuilder.unratedScore`） |
| `dayStart` / `dayEnd` | 09:00 / 20:00 | 每日活动窗（TripPrefs 目前无此字段，见未决①） |
| `maxSightsPerDay` | 按 pace：tight 5 / relaxed 4 / casual 3 | 分天容量上限（B2） |
| 停留先验 | 见 §4.2 | 按 kind/subtype，再乘 pace 系数（B2） |
| 午/晚餐窗 | 11:30–13:30 / 17:30–19:30 | MealSlotter |
| 步行阈值 | 见 §6 mode 修正（水域兜底） | 直线阈值对短距离跨海不可靠，需改（A1） |
| 速度档 | 步行 5 / 公交 18 / 驾车 30 km/h | TravelEstimator 估算 |

硬约束（出口必须满足）：每日 `time` 严格递增；已知 `openHours` 的点到达在窗内；`sights.count ≥ days` 时每日景点数 ∈ [1, maxSightsPerDay]、无空天（不足则按 §4.4 B3 允许轻量天）。
软约束（尽量满足，缺料可跳过）：跨越餐窗且**存在可用餐饮候选**时含对应餐——因 MealSlotter 允许缺料/时长不足时跳过（§4.6），此项不作硬门（A3）。

---

## 6. 与现有代码的契约对齐

- `PlannedStop` 结构不变；语义变化：`time`/`stayMin` 来源 = 模拟器；`note` 来源 = 可选 NoteWriter。
- `buildItems(from:source:city:)` 行为不变，继续逐段补真实交通段。**顺带修 `mode()` 阈值 bug（A1，方向已订正）**：真实代码是 `guard haversineMeters > 1500 else { return .walk }`，即**「≤1500m → 步行」**。跨海/跨江（如陆地↔鼓浪屿）直线距离往往 **< 1500m**，于是被判「步行」，而实际需轮渡——**误判方向是「短距离跨水被判步行」**。因此**不能抬高阈值**（那会让更多短跨水段落入步行，放大 bug）；正确做法是加**「同城水域/需摆渡」兜底**：命中水域分隔（或改由真实 `route` 的模式回填）时强制非步行。（T6.3）
- `ItineraryEngine.generate` 调用点不变（仍 `curate → planStops → buildDays`）。
- 单日重生成复用 `planStops(days:1)`，无需新增入口。
- `FactChecker` 在此路径退役（T6.2）。**连带测试清理（C1）**：`FactCheckerTests`、`ItineraryParserTests` 中断言 LLM 编排结果的用例需删除或改造为「几何流水线」用例，避免退役代码留下悬空测试。

---

## 7. 验证与验收门

新增 `ItineraryFeasibility` 自检器，接在 `planStops` 出口（每次生成强制过）：
1. （硬）每天 `time` 严格递增（时间单调，用 Int 分钟比较，见 §4.7 B5）。
2. （硬）每个 `openHours` 已知的点：到达 ∈ 营业窗。
3. （硬）`sights.count ≥ days` 时每天景点数 ∈ [1, maxSightsPerDay]、无空天；`sights.count < days` 时允许轻量天（§4.4 B3），不判失败。
4. （软，A3）跨越午/晚餐窗**且存在可用餐饮候选**的天：含对应餐饮 stop——MealSlotter 因缺料/时长不足跳过时不判失败。
5. （软）日内 2-opt 已收敛（无明显回头路）——以路径总长 ≤ 初始贪心序为通过近似。

失败处理：硬约束失败 → 记录 warning 并返回当前最优可行子集（丢弃违规点），不抛错中断；软约束不满足仅记 info，不影响出行。

---

## 8. 任务拆解（P0–P8 · 原子任务）

> 每任务含验收；依赖只列直接前置。P0 可独立先合。P1–P5 为纯函数模块，可并行开发，各带单测。

**P0 止血（独立）**
- **P0.1** `CandidateCuration.score` 改中性分 `?? 4.0`（对齐 `PromptBuilder.unratedScore`）+ 单测（无评分招牌景点不再沉底）。依赖：无。

**P1 基础设施**
- **P1.1** `StayDuration`（kind/subtype→分钟）+ 单测。
- **P1.2** `OpenHoursParser`（多段/全天/跨夜/脏数据；失败→nil）+ 单测（覆盖缺失与畸形串）。
- **P1.3** `GeoProjection`（经纬↔米，等距近似）+ 单测。

**P2 聚类分天**
- **P2.1** `DayClusterer`：k-means + 容量约束分配（`maxSightsPerDay` 按 pace）+ 天序链接 + 单测（每天非空、数量均衡±1、空间成团、**`sights.count < days` 降级为轻量天不抛错**）。依赖：P1.3。

**P3 簇内排序**
- **P3.1** `DayRouter`：贪心NN + 2-opt（开放路径，haversine）+ 单测（4 点方形用例消除交叉、总长单调下降）。

**P4 餐饮卡点**
- **P4.1** `MealSlotter`：午/晚餐就近高分插入 + 单测（≤1午+≤1晚、不与已用重复、短行程单餐）。依赖：P3.1。

**P5 时间模拟**
- **P5.1** `TravelEstimator`（haversine×速度→分钟；每段速度档由修正后的 `mode()` 决定，B4）+ 单测。
- **P5.2** `ScheduleSimulator`：前向模拟赋 time/stayMin + 营业窗（等待/丢弃/末尾截断）+ 单测（构造闭馆点被丢、早到等待、超 dayEnd 截断）。依赖：P1.1、P1.2、P5.1。

**P6 编排层接线**
- **P6.1** 重写 `planStops` 为 §3 六步（签名不变；`days==1` 复用）。依赖：P2.1、P3.1、P4.1、P5.2。
- **P6.2** 从该路径移除 LLM 几何调用与 `FactChecker.reconcile`（降为空守卫或删除）。依赖：P6.1。
- **P6.3** 修 `mode()` 短距离跨水域误判（A1：加水域/摆渡兜底，**不抬阈值**）+ 对齐 `buildItems`（time 来自模拟）+ 单日重生成路径回归。依赖：P6.1。

**P7 LLM 降级为文案（可选）**
- **P7.1** `NoteWriter`：对定稿 stops 只生成 note + 每日主题；越界忽略、畸形留空。依赖：P6.1。

**P8 验收与回归**
- **P8.1** `ItineraryFeasibility` 自检器 + 接入 `planStops` 出口。依赖：P6.1。
- **P8.2** 端到端回归：厦门/鼓浪屿用例（跨海不误判步行、日内不回头、营业窗内），Core 全部单测通过。依赖：P6.3、P8.1。

---

## 9. 风险与未决项

| 风险 | 影响 | 缓解 |
|---|---|---|
| haversine ≠ 路网（鼓浪屿跨海尤甚） | 排序/估时与真实 route 段有偏差 | 本期用直线代理排序，展示走真实 route；未决③决定是否上真实矩阵；顺带修 mode() 短距离跨水误判、加水域兜底（A1/T6.3）|
| 无酒店锚点 | 日内开放路径无固定起终点，天序为启发式 | 个人自用可接受；未来接入用户选定酒店作锚点 |
| `openHours` 脏/缺 | 可行性过滤覆盖有限 | 解析失败→不过滤（保守）；缺失点不参与营业窗判定 |
| 停留先验粗糙 | `time` 为近似 | 比 LLM 拍脑袋可控；先验可配、后续可按真实反馈校准 |
| 小 N / 奇数天聚类不均 | 某天点过少 | 容量 clamp + 兜底再平衡；每天保底 1 点 |

**未决（需拍板）**——每项附本期倾向建议，最终以主程拍板为准：

1. `dayStart`/`dayEnd` 让用户在 `TripPrefs` 里配（需加字段 + 老数据容错解码），还是先写死默认 09:00–20:00？
   - **倾向：本期先写死 09:00–20:00。** 加字段属独立增量（`TripPrefs` 已有 `init(from:)` 容错解码范式，`Models.swift:75`，后续补低成本），不该拖住编排主线。做成可配常量，等确定性几何验证稳定后再开放到 UI/`TripPrefs`。
2. `NoteWriter`（P7）本期做，还是先留空 `note`、只上确定性几何？
   - **倾向：本期先留空 `note`，只上确定性几何。** 先验证"排得对"，文案是锦上添花；留空还能让本期**完全去掉 LLM 依赖**，便于把新老编排做干净的 A/B 回归对比。P7 留作紧随其后的独立增量。
3. 排序/估时先用 haversine 代理，还是直接上真实 route 距离矩阵（多 API 调用、需扩缓存）？
   - **倾向：本期用 haversine 代理排序/估时，展示仍走真实 `source.route`。** 真实矩阵要扩缓存 + N² 量级 API 调用，收益集中在跨水域场景，而该场景已由 A1 修好的 `mode()` + 水域兜底覆盖。矩阵留待有真实反馈显示"直线代理排序明显不如路网"时再上。

---

*落地建议顺序：P0.1（立即止血）→ P1 三个纯函数并行 → P2/P3/P4/P5 逐个带测 → P6 接线 → P8 回归。P7 视未决②决定。做完 P0+P2+P3+P5+P6，线路质量的提升应显著大于过去几版——因为首次动到了真正的瓶颈（编排）。*
