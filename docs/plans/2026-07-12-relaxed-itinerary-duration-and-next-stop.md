# Trailhead 轻松行程：弹性停留时长与动态下一站推荐优化方案

> 文档类型：可直接交给 AI 编码代理执行的算法与实施规格
> 状态：待实施
> 日期：2026-07-12
> 适用范围：`Packages/TrailheadCore`、iOS/macOS 行程时间线与当天动态调整体验

## 0. AI 执行说明

实现本方案的 AI 编码代理必须遵守以下规则：

1. 先阅读本文件及下列现有实现，再修改代码：
   - `Packages/TrailheadCore/Sources/TrailheadCore/StayDuration.swift`
   - `Packages/TrailheadCore/Sources/TrailheadCore/DayClusterer.swift`
   - `Packages/TrailheadCore/Sources/TrailheadCore/ScheduleSimulator.swift`
   - `Packages/TrailheadCore/Sources/TrailheadCore/ItineraryDayBuilder.swift`
   - `Packages/TrailheadCore/Sources/TrailheadCore/SpillRepair.swift`
   - `Packages/TrailheadCore/Sources/TrailheadCore/NearbyFood.swift`
   - `Packages/TrailheadCore/Sources/TrailheadCore/Services.swift`
2. 先实现 Core 纯函数和单元测试，再接入 UI；不得把核心排程判断写进 SwiftUI View。
3. 保持确定性：相同输入必须产生相同输出；所有平手使用 `poi_id` 升序破平。
4. 几何排程、时长选择和下一站可行性必须由确定性算法完成。运行时 LLM 只能补文案，不能修改顺序、时间、营业约束或可行性结论。
5. 不删除当前真实路线校准、跨水域轮渡兜底、营业时间检查、spill 跨天重插能力。
6. 新增持久化字段必须兼容老数据，使用 `decodeIfPresent` 和合理默认值。
7. 每完成一个阶段，运行 `make test`；若仓库实际测试命令已经变化，以 `Makefile` 为准。
8. 不为通过测试而降低本文的硬约束。若现有架构与本文冲突，优先做最小范围重构，并在代码注释中说明。

## 1. 背景与问题

当前停留时长模型只有单一整数：普通景点 90 分钟，博物馆/自然类 120 分钟，再乘节奏系数。该模型无法区分“小型观景点”和“大型自然景区、古镇、主题乐园”等综合景区。

这会导致以下连锁问题：

1. 大型景区被压缩成 1.5～2 小时。
2. 分天聚类使用错误的停留时长，继续向当天塞入其他景点。
3. 行程看似丰富，但实际无法舒适完成。
4. 父景区与内部子景点可能重复计算时长。
5. 当前只有附近美食推荐，缺少基于实际进度的下一站推荐。
6. “轻松慢节奏”只是把单点时长略微拉长，仍然以填满一天为目标，没有真正预留休息和临时变化空间。

## 2. 产品目标

### 2.1 核心目标

将行程生成原则改为：

> 先保证核心景点玩得舒服，再判断是否增加下一站；允许留白，不以填满一天为目标。

系统必须做到：

- 停留时长是范围，不是假装精确的单值。
- 主行程默认使用“舒适时长”。
- 轻松模式每天只安排 1～2 个核心景点，最多 3 个普通景点。
- 每天只占用约 70%～75% 的可活动时间，其余作为休息、排队、找路和临时变化缓冲。
- 大型综合景区可以独占半天或一天。
- 下一站只有在时间、营业、交通、区域和返程均可行时才推荐。
- 其他可能去的地方进入“可选推荐”，不强制写入主时间线。
- 用户提前结束、延长、跳过后，只重排当天尚未开始的内容。

### 2.2 非目标

本次不做：

- 用 LLM 直接生成时长或直接决定路线。
- 建立覆盖全国全部景区的在线知识图谱。
- 用用户画像替代明确的节奏选择。
- 强制每天必须安排相同数量的景点。
- 为追求景点覆盖率而压缩合理游玩时长。

## 3. 核心概念与数据结构

### 3.1 景点范围类型 `POIScope`

新增：

```swift
public enum POIScope: String, Codable, Sendable {
    case point       // 小型单点：雕塑、观景台、小寺庙
    case venue       // 场馆：博物馆、美术馆、纪念馆
    case park        // 公园、植物园、自然景区
    case district    // 街区、古镇、历史文化片区
    case complex     // 主题乐园、大型综合景区
    case island      // 需登岛游览的岛屿景区
}
```

### 3.2 弹性停留时间 `VisitDurationRange`

```swift
public struct VisitDurationRange: Equatable, Sendable {
    public let minimum: Int       // 快速游览仍合理的下限
    public let comfortable: Int   // 默认主行程使用值
    public let extended: Int      // 深度游览参考上限
    public let confidence: Double // 0...1
    public let source: DurationSource
}

public enum DurationSource: String, Codable, Sendable {
    case userOverride
    case providerMetadata
    case featureModel
    case scopeRule
    case categoryRule
    case fallback
}
```

必须满足：

```text
minimum > 0
minimum <= comfortable
comfortable <= extended
confidence ∈ [0, 1]
```

### 3.3 景点访问画像 `VisitProfile`

```swift
public struct VisitProfile: Equatable, Sendable {
    public let scope: POIScope
    public let duration: VisitDurationRange
    public let isDayAnchor: Bool
    public let parentScopeID: String?
    public let accessBufferMin: Int
    public let exitBufferMin: Int
}
```

字段含义：

- `isDayAnchor`：景点是否因完整访问成本较高而占据当天主要时间；只能由通用阈值计算，不能按景点名称硬编码。
- `parentScopeID`：数据源或空间包含算法推断出的父景区 ID。
- `accessBufferMin`：排队、安检、换乘、候船等进入成本。
- `exitBufferMin`：离场、出岛等成本。

### 3.4 通用特征向量 `VisitFeatureVector`

所有景点统一通过同一组特征计算，不允许建立具体景点白名单：

```swift
public struct VisitFeatureVector: Equatable, Sendable {
    public let scope: POIScope
    public let areaScore: Double              // 空间范围 0...1
    public let contentDensityScore: Double    // 可游览内容量 0...1
    public let accessComplexityScore: Double  // 进入/离开复杂度 0...1
    public let internalMobilityScore: Double  // 内部移动成本 0...1
    public let queueRiskScore: Double         // 排队/安检风险 0...1
    public let parentConfidence: Double       // 父子归属置信度 0...1
    public let evidenceCount: Int             // 有效特征来源数
}
```

特征来源按可靠性排列：

1. 地图数据源明确提供的父 POI、景区边界、占地面积、入口、内部 POI 数。
2. 景区 polygon/bounding box 与候选 POI 的空间包含关系。
3. 一定半径内同类子 POI 的数量和内容密度。
4. `subtype`、标签、营业信息等分类元数据。
5. 名称关键词只能作为弱信号，不能单独把景点判为全天景区。

缺失特征必须使用类别中性值并降低 `confidence`，不能把缺失值当成 0，也不能因为数据不足生成极端时长。

类别中性值统一取 `0.5`。只有明确观测到低值时才能使用 `< 0.5`；“字段不存在”和“观测值为低”必须在数据模型中区分。

### 3.5 行程层级

主行程中的点增加角色：

```swift
public enum StopRole: String, Codable, Sendable {
    case anchor      // 当天核心景点
    case primary     // 正式安排的普通景点
    case optional    // 可选，不预占主行程时间
}
```

首期若不修改持久化模型，可先在 Core 中以计算结果表达，装配 UI 时再映射；不得为了赶进度把 `optional` 当成普通 `PlanItem` 塞入主时间线。

## 4. 停留时长算法

### 4.1 默认时长先验

单位均为分钟：

| 范围/类别 | minimum | comfortable | extended |
|---|---:|---:|---:|
| 小型单点 `point` | 30 | 60 | 90 |
| 普通景点 fallback | 60 | 105 | 180 |
| 场馆 `venue` | 90 | 165 | 240 |
| 公园/自然 `park` | 90 | 210 | 360 |
| 街区/古镇 `district` | 120 | 270 | 420 |
| 大型综合景区 `complex` | 240 | 390 | 480 |
| 岛屿景区 `island` | 240 | 390 | 480 |
| 餐饮 | 45 | 75 | 105 |

注意：这是首版先验，后续可根据真实使用数据调整；测试应验证相对关系和重点案例，不要把所有数值散落硬编码到多个模块。

### 4.2 通用时长解析流程

实现 `VisitProfileResolver.resolve(candidate:context:prefs:override:)`，所有景点严格走相同流程：

1. 用户覆盖值：最高优先级。
2. 读取地图数据源的结构化元数据。
3. `VisitFeatureExtractor` 计算范围、内容密度、进入复杂度、内部移动和排队风险。
4. `ScopeClassifier` 由结构化特征确定 `POIScope`。
5. 从 scope/category 先验取得基础时长范围。
6. 使用特征模型调整基础时长范围。
7. 数据不足时退回类别中性值并降低置信度。

禁止按 POI ID、标准化名称或城市建立特例表。名称只参与 subtype 缺失时的弱分类，权重不得超过最终 scope 判定证据的 20%。

### 4.3 特征归一化与时长计算

连续特征统一归一化为 `0...1`：

```text
areaScore = normalizeLog(areaSquareMeters, categoryAreaP20, categoryAreaP90)
contentDensityScore = normalizeLog(1 + childPOICount, categoryChildP20, categoryChildP90)
accessComplexityScore = weighted(需预约, 安检, 单一入口, 特殊接驳, 跨水/索道)
internalMobilityScore = weighted(内部路程, 高差, 多片区, 内部接驳)
queueRiskScore = weighted(热门度, 时段拥挤度, 预约/排队元数据)
```

无城市统计分位数时，使用按 `POIScope` 配置的全局分位数。时长调整系数：

```text
scale = clamp(
    0.75,
    1.45,
    0.625
    + 0.25 × areaScore
    + 0.25 × contentDensityScore
    + 0.15 × internalMobilityScore
    + 0.10 × queueRiskScore
)
```

对基础 range 的三个值同时乘 `scale`，再执行以下限制：

- `minimum` 最大增幅不超过 35%，避免把最低游览门槛推得过高。
- `comfortable` 和 `extended` 使用完整 scale；类别中性特征 `0.5` 对应 scale `1.0`。
- 三个值都四舍五入到最接近的 5 分钟。
- 结果必须保持 `minimum <= comfortable <= extended`。
- `accessComplexityScore` 不进入停留时长 scale，而是转成 access/exit buffer，避免重复计时。

置信度：

```text
confidence = clamp(0.25, 0.95,
    0.25 + 0.12 × evidenceCount + 0.25 × structuredMetadataCoverage)
```

低置信度不应自动缩短时长；使用类别中性舒适值，并在 UI 表达“预计”。

### 4.4 节奏选择

`Pace` 不再简单使用 `0.8 / 1.0 / 1.2` 乘法。改为在时长范围中取位置：

```text
tight:
  minimum + 0.35 × (comfortable - minimum)

relaxed:
  comfortable

casual:
  comfortable + 0.60 × (extended - comfortable)
```

结果四舍五入到最接近的 5 分钟。

硬约束：

- 任何模式不得低于 `minimum`。
- `isDayAnchor == true` 时，紧凑模式也不能低于 `minimum`。
- 用户明确选择的自定义时长可以覆盖算法，但 UI 应在低于 `minimum` 时给出“不建议”的提示，不应静默改回。

### 4.5 完整访问成本

聚类和当天排程使用的成本不再只有 `stayMin`：

```text
visitCost = accessBuffer + selectedStay + exitBuffer
```

交通仍作为边成本单独计算：

```text
stopCost(i) = travel(previous, i) + visitCost(i)
```

禁止把同一段特殊接驳时间同时计入 `accessBuffer` 和真实交通边。`accessBuffer` 只表达排队、安检、候车和上下客等路线 API 难以覆盖的固定成本。

## 5. 通用景区规模与父子层级识别

### 5.1 `isDayAnchor` 判定

`isDayAnchor` 完全由计算结果判定，满足任一条件：

1. 完整访问成本达到当天可活动窗口的 55%。
2. 舒适停留时间达到 300 分钟，且交通隔离/进入复杂度高于 0.6。
3. 舒适停留时间达到 360 分钟。

半天核心景点可以设置 `isDayAnchor = true`，但允许同一区域再安排一个轻量 `primary`；全天景区只能增加餐饮、景区内部子点和可选收尾活动。

### 5.2 父景区与子景点去重

父子关系按以下证据加权推断：

```text
providerParentID                 置信度 1.00
父 polygon 包含子坐标           置信度 0.90
父 bounding box 包含 + 类型匹配  置信度 0.75
距离阈值 + 内容类型匹配          置信度最高 0.55
仅名称相似                       不建立父子关系
```

置信度达到 `0.75` 才自动归并；`0.55...0.75` 只可作为候选关系，不改变主排程。父景区与内部子景点同时进入候选池时：

- 主时间预算只计算父景区整体时长。
- 子景点作为父景区内部路线建议，不作为平级主行程点重复计时。
- 若用户明确只选择某个子景点而没有选择父景区，则按子景点自身时长规划。
- 若无法可靠判断父子关系，保持平级，不允许仅凭名称相似强行合并。

### 5.3 通用进入与离开缓冲

缓冲由访问复杂度计算，而不是按景点名称配置：

```text
accessBuffer = roundTo5(10 + 25 × accessComplexityScore + 15 × queueRiskScore)
exitBuffer   = roundTo5( 5 + 15 × accessComplexityScore)
```

范围限制：

- `accessBuffer`: 10～50 分钟。
- `exitBuffer`: 5～25 分钟。
- 真实交通边已经包含的时间不得重复计入缓冲。
- 特殊接驳只提高复杂度；具体航行、索道、接驳行驶时间仍走路线边。

## 6. 轻松行程的每日预算

### 6.1 日窗口

保留系统现有可配置/默认日窗口，但轻松模式不应使用全部窗口。

新增：

```swift
public struct DayComfortPolicy: Sendable {
    let scheduledLoadRatio: Double
    let maxPrimarySights: Int
    let continuousActivityLimitMin: Int
    let restBufferMin: Int
    let minimumFreeBufferMin: Int
    let latestLargeAttractionStart: Int
    let maxPreferredTransferMin: Int
}
```

默认策略：

| Pace | 主行程负载率 | 正式景点上限 | 连续活动上限 | 休息缓冲 | 最小自由余量 |
|---|---:|---:|---:|---:|---:|
| tight | 0.85 | 4 | 180 | 15 | 45 |
| relaxed | 0.72 | 2；小型点可放宽到 3 | 150 | 25 | 90 |
| casual | 0.62 | 2 | 120 | 30 | 120 |

`relaxed` 是本方案默认产品方向。

### 6.2 负载计算

一天的正式负载：

```text
scheduledLoad =
  Σ舒适停留时间
  Σ访问缓冲
  Σ正式交通时间
  Σ强制休息时间
  Σ正式餐饮时间
```

必须满足：

```text
scheduledLoad <= activeWindow × scheduledLoadRatio
```

同时满足：

```text
dayEnd - finalRequiredEnd >= minimumFreeBufferMin
```

特殊情况：一个 `isDayAnchor` 本身超过负载率时允许独占当天，但不能因此被缩短或再添加其他大型景点。

### 6.3 分天聚类改造

当前 `DayClusterer` 的容量判断从“点数 + 停留分钟”改为：

```text
点数容量
+ 访问成本容量
+ 全天主景区排他约束
```

规则：

1. 含全天主景区的 bucket 默认不接受其他 `anchor/primary`。
2. 半天主景区只接受同区域、低交通成本且总负载可行的一个轻量点。
3. 所有 bucket 满时，不应强行塞进最近 bucket；进入 spill，交由跨天修复或最终可选推荐。
4. 不以“每天数量均衡”为硬目标，轻松行程允许某天 1 个核心景点、另一天 2 个景点。

### 6.4 强制休息

当连续活动时间达到策略上限时，在下一正式景点之前加入休息缓冲。首期可以只影响模拟时间，不必创建可见 POI；UI 可在时间线显示“自由活动 / 休息 25 分钟”。

连续活动包括：

- 景点停留。
- 步行超过 15 分钟的交通。
- 排队/进入缓冲。

正餐可重置连续活动计时；短交通不能重置。

## 7. 主行程与可选推荐

### 7.1 主行程

主行程只包含：

- 当天 1 个 anchor。
- 0～2 个时间和区域均合理的 primary。
- 必要餐饮。
- 必要交通和休息。

主行程必须在生成时通过完整可行性检查。

### 7.2 可选池

未进入主行程但质量足够的候选不应直接丢弃，建立当天 `optionalCandidates`：

- 与当天路线相近。
- 营业时间有可能满足。
- 未与父景区重复。
- 未被其他天主行程使用。
- 对轻松模式优先保留短时长、低交通、低强度地点。

可选池不预占正式时间，不显示确定到达时刻，只显示：

```text
建议游玩 45～60 分钟
从当前位置约 12 分钟
适合：时间充足时 / 轻松收尾
```

## 8. 动态下一站推荐算法

### 8.1 触发时机

以下事件触发当天剩余行程重算：

- 用户完成当前景点。
- 用户提前结束。
- 用户延长停留。
- 用户跳过景点。
- 用户选择“今天早点结束”。
- 当前时间偏离计划 20 分钟以上。

不得自动修改已经完成或正在游玩的内容。

### 8.2 输入

```swift
public struct NextStopContext: Sendable {
    let now: Date
    let currentLocation: Coordinate
    let currentRegionID: String?
    let completedPOIIDs: Set<String>
    let remainingRequiredStops: [POICandidate]
    let optionalCandidates: [POICandidate]
    let lodgingOrExitAnchor: POICandidate?
    let fatigueMinutes: Int
    let prefs: TripPrefs
    let weekday: Int?
    let dayEnd: Int
}
```

### 8.3 硬过滤

候选下一站必须全部满足：

1. 未完成、未跳过、未在其他天使用。
2. 与已选父景区不重复。
3. 到达后能在营业窗口内完成至少 `minimum` 时长。
4. 能保留返回住宿/结束点的时间。
5. 能保留策略规定的最小安全余量。
6. 不触发不合理跨水、跨岛或跨城区移动。
7. 当天已有全天主景区时，只允许同一父区域内子点、餐饮或轻量收尾活动。

完整可行性公式：

```text
now
+ travelToCandidate
+ candidate.accessBuffer
+ candidate.minimumStay
+ candidate.exitBuffer
+ travelToExitAnchor
+ safetyBuffer
<= dayEnd
```

其中轻松模式 `safetyBuffer` 默认至少 45 分钟；若真实交通可靠性为 estimated，额外增加 15 分钟。

### 8.4 推荐评分

通过硬过滤后计算：

```text
score =
    0.30 × interestMatch
  + 0.20 × quality
  + 0.20 × routeFit
  + 0.15 × timeFit
  + 0.10 × diversity
  + 0.05 × openingSafety
  - crossRegionPenalty
  - fatiguePenalty
  - uncertaintyPenalty
```

所有分量归一化到 `0...1`。惩罚项：

- 跨父区域：`0.30`。
- 轻松模式交通超过 45 分钟：从 0 开始线性惩罚，60 分钟时达到 `0.25`。
- 已连续活动超过上限：非休息型候选惩罚 `0.25`。
- 只有估算交通且余量不足 60 分钟：惩罚 `0.15`。

平手按：

1. 交通时间短。
2. 舒适时长更适配剩余时间。
3. 评分高。
4. `poi_id` 升序。

### 8.5 输出分组

不得只返回一个候选。输出最多三类：

```swift
public struct NextStopSuggestions: Sendable {
    let continueExploring: NextStopOption?
    let easyFinish: NextStopOption?
    let endDay: EndDayOption
}
```

- `continueExploring`：仍有充足时间和体力时的最佳景点。
- `easyFinish`：咖啡馆、公园、街区、观景点、晚餐等低强度选择。
- `endDay`：返回住宿/结束当天，始终存在。

每个推荐必须包含可解释理由：

```text
仍在当前景区范围内，步行约 12 分钟；建议游玩 45～60 分钟，闭园前余量充足。
```

文案可以模板化；LLM 可润色但不得改变数字或可行性。

## 9. 当天动态重排

动态重排只处理尚未开始的部分：

```text
固定前缀 = 已完成 + 正在进行
可变后缀 = 尚未开始的 required + optional
```

流程：

```text
1. 读取实际当前时间和位置
2. 固定已完成前缀
3. 更新疲劳/连续活动时间
4. 对剩余 required 做真实交通和营业可行性重放
5. 不可行 required 降级到 optional，而不是缩短至 minimum 以下
6. 生成三类下一站建议
7. 仅在用户确认后替换当天后缀
```

如果用户只是延长当前景点，不应弹出大量错误；给出简短状态：

```text
已为当前景点延长 60 分钟。原计划中的 X 时间不足，已移到可选推荐。
```

## 10. 通用端到端示例

### 10.1 输入

```text
城市：任意城市
节奏：轻松慢节奏
候选：大型景区 A、A 内部子景点 A1/A2、独立大型景区 B、附近街区 C
住宿：当天结束锚点 H
```

### 10.2 父子归并

```text
大型景区 A（父景区，经通用特征计算为全天 anchor）
├── 子景点 A1（内部建议）
└── 子景点 A2（内部建议）

独立大型景区 B（不能排进同一天）
附近街区 C（可选收尾）
```

### 10.3 合理输出

```text
09:00  出发，计入真实交通与进入缓冲
10:00  抵达大型景区 A
10:00–12:30  景区上午路线
12:30–13:45  午餐与休息
13:45–16:30  景区下午路线
16:30–17:30  离场并返程

可选：
- 体力充足：附近街区 C，60～90 分钟
- 轻松收尾：附近晚餐
- 结束行程：返回住宿
```

独立大型景区 B 必须安排到其他天。这里的 A/B/C 是算法类别示例，不代表任何 POI 特例。

### 10.4 动态场景

如果用户 15:00 提前结束大型景区 A：

- 不推荐跨城大型景点。
- 优先推荐当前父景区内短点、咖啡馆、提前返程。
- 街区 C 可作为返程后的 `easyFinish`，必须重新计算交通和营业余量。

如果用户 17:30 才离开大型景区 A：

- 不再推荐正式景点。
- 只推荐晚餐、短距离夜景或返回住宿。

## 11. 与现有模块的改造映射

### 11.1 新增文件建议

```text
Packages/TrailheadCore/Sources/TrailheadCore/
├── VisitDurationRange.swift
├── VisitFeatureExtractor.swift
├── VisitProfileResolver.swift
├── ScopeClassifier.swift
├── DayComfortPolicy.swift
├── OptionalStopSelector.swift
├── NextStopRecommender.swift
└── RemainingDayReplanner.swift
```

### 11.2 修改现有文件

#### `StayDuration.swift`

- 保留兼容入口 `duration(for:pace:)`，内部改为调用 `VisitProfileResolver`。
- 新增返回完整 range/profile 的入口。
- 移除单纯通过 pace 乘数缩放的核心逻辑。

#### `Services.swift`

- 为 `POICandidate` 增加可选的结构化特征字段，包括 provider parent、边界/面积、入口和内部内容数量；字段不可用时保持 `nil`，不能写 0。
- scope/parent 由通用解析器产出，不在 API 解析层按名称硬判。
- 若增加字段，为所有构造调用提供默认值，避免大范围破坏测试。

#### `AmapClient.swift`

- 优先解析地图服务实际提供的结构化父子、边界、类型和业务元数据。
- 若单次搜索结果不足以计算空间范围，允许通过可缓存的详情/周边查询补充；必须有调用上限，不能产生无界 N² 请求。
- 外部数据不可用时走中性回退，不能阻断行程生成。

#### `DayClusterer.swift`

- 使用完整访问成本。
- 加入 day anchor 排他约束。
- 放松“数量均衡”，优先舒适负载。
- 全满时进入 spill，不强塞最近 bucket。

#### `ScheduleSimulator.swift`

- 支持 access/exit buffer。
- 支持连续活动与休息缓冲。
- 禁止为塞入下一站而低于 `minimum`。
- 保持营业窗、真实交通和 dayEnd 硬约束。

#### `ItineraryDayBuilder.swift`

- 生成主行程和可选池。
- 使用 `DayComfortPolicy` 计算每日预算。
- 全天主景区当天只插入必要餐饮，不插入跨区域正式景点。

#### `SpillRepair.swift`

- 只在完整舒适负载可行时重插。
- 不可重插的高质量候选进入 optional，而不是直接静默丢弃。

#### `NearbyFood.swift`

- 保留美食推荐。
- 复用动态推荐的真实剩余时间、营业和区域过滤逻辑。

### 11.3 UI 接入

时间线卡片展示：

```text
建议游玩 2～3 小时
当前按舒适节奏预留 2 小时 45 分钟
```

允许用户选择：

- 快速逛逛。
- 舒适游览。
- 深度体验。
- 自定义。

当天底部增加“如果还有时间”区域，不把 optional 混入正式时间线。

## 12. 分阶段实施计划

### 阶段 A：Core 时长止血

1. 新增 `POIScope`、`VisitDurationRange`、`VisitProfile`。
2. 实现 `VisitFeatureExtractor`、`ScopeClassifier` 和 `VisitProfileResolver`。
3. 将 `StayDuration.duration` 切换到范围选择算法。
4. 接入结构化元数据，并为缺失字段提供中性回退。
5. 增加不同规模、不同类别景点的参数化单元测试。

完成标志：同类别不同规模的景点能得到不同且稳定的时长范围，不存在按具体 POI 名称编写的生产规则。

### 阶段 B：轻松分天与模拟

1. 实现 `DayComfortPolicy`。
2. 分天使用完整访问成本和主景区排他规则。
3. 模拟器加入访问缓冲和休息缓冲。
4. 调整 spill：不能主排的候选转 optional。
5. 增加多日和真实交通回归测试。

完成标志：任意全天 anchor 当天都不再强塞第二个跨区域大型景点；轻松模式大多数天为 1～2 个核心景点。

### 阶段 C：动态下一站

1. 实现 `NextStopRecommender` 纯函数。
2. 加入营业、返程、安全余量、区域和疲劳硬过滤。
3. 输出继续游玩、轻松收尾、结束行程三类建议。
4. 接入当天完成/延长/跳过事件。

完成标志：不同实际结束时间会得到不同且可行的下一站建议。

### 阶段 D：UI 与持久化

1. 展示时长区间及当前采用值。
2. 支持快速/舒适/深度/自定义。
3. 展示 optional 区域。
4. 保存用户覆盖和当天执行状态。
5. 老 Trip 解码兼容测试。

## 13. 必需测试

### 13.1 时长测试

- 普通景点 relaxed 使用 comfortable。
- tight 不低于 minimum。
- casual 不高于 extended。
- 结果取整到 5 分钟。
- 用户覆盖优先级高于通用推断结果。
- 同类别下，面积和内容密度更高的景点舒适时长不短于小型景点。
- 数据缺失时使用类别中性值，不能得到 0 或极端时长。
- tight 仍不低于推导出的 minimum。
- 单一名称关键词不会把普通小点判为全天景区。
- 生产代码和 fixture 不包含具体 POI 时长白名单。

### 13.2 分天测试

- 全天 anchor 独占正式景点容量。
- 两个独立全天 anchor 不在同一天。
- 轻松模式普通景点默认不超过 2 个；三个小型点在总负载可行时允许。
- 每日正式负载不超过策略阈值。
- 单个 anchor 超过阈值时可以独占当天且不被压缩。
- 无法主排的点进入 optional/spill，不被强塞。

### 13.3 模拟测试

- 访问缓冲正确计入到达/结束时间。
- 轮渡航行与候船缓冲不重复计时。
- 连续活动超过 150 分钟后插入 relaxed 休息缓冲。
- 营业时间不足 minimum 时判不可行。
- 真实交通变长后，后续点降级为 optional，而不是缩短当前景点。

### 13.4 下一站推荐测试

- 剩余时间不足时不推荐正式景点。
- 推荐必须保留返程和 45 分钟安全余量。
- estimated 交通额外增加 15 分钟余量。
- 全天 anchor 游览中只推荐同一父范围内子点或轻量选项。
- 接近 dayEnd 离开 anchor 后只返回 easyFinish/endDay。
- 同分候选输出稳定。
- endDay 永远存在。

### 13.5 兼容与回归

- 现有周闭馆重插测试继续通过。
- 跨水域轮渡测试继续通过。
- 真实路线校准测试继续通过。
- 单日重生成不使用其他天已用 POI。
- 老数据缺少新增字段时可正常打开。

## 14. 验收标准

实现完成必须同时满足：

1. 所有景点统一使用“类别先验 + 空间范围 + 内容密度 + 访问复杂度 + 用户节奏”算法，不存在具体 POI 特例。
2. 任意全天 anchor 当天不安排第二个跨区域大型景点。
3. 排队、安检、特殊接驳等进入成本进入预算，且不与真实交通时间重复计算。
4. 父景区与内部子景点不重复计算主行程时长。
5. 轻松模式每天主行程通常为 1～2 个核心景点。
6. 主行程保留至少 90 分钟自由余量，全天 anchor 特例除外。
7. 下一站必须通过营业、最低游玩时间、交通、返程和安全余量校验。
8. 用户延长当前景点时，系统优先移除/降级后续点，不压缩当前合理体验。
9. 可选推荐与主时间线视觉和数据语义明确分离。
10. Core 与 App 测试全部通过，同输入结果确定。

## 15. 实现决策优先级

遇到冲突时，按以下顺序决策：

1. 安全、营业时间和真实可达性。
2. 用户明确设置。
3. 当前景点的合理体验下限。
4. 轻松节奏与自由余量。
5. 少绕路、少跨区。
6. 兴趣与评分。
7. 景点覆盖数量。

景点覆盖数量永远是最低优先级。
