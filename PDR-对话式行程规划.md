# PDR｜Trailhead 对话式行程规划

> 文档类型：增量 Product / Project Design Requirements
> 版本：v1.0
> 日期：2026-07-17
> 目标读者：产品设计、主程、后续执行实现的 AI coding agent
> 基线：当前 `Trailhead` 主工程与 `TrailheadCore` 确定性编排流水线
> 本文范围：产品流程、UI、状态机、数据契约、算法边界、开发任务与验收标准；本期不包含代码实现

---

## 0. 决策摘要

新增“对话式行程规划”能力，但不让大模型直接生成或修改路线。

职责边界固定为：

| 层 | 负责 | 不负责 |
|---|---|---|
| LLM 对话层 | 理解用户自然语言、提取偏好、发现歧义、生成简洁追问、解释确定性冲突 | 杜撰 POI、决定真实地点、输出最终路线、静默覆盖用户要求 |
| 本地意图层 | 合并结构化约束、管理来源与置信度、校验类型和范围、决定是否继续追问 | 自由生成用户没有表达过的硬要求 |
| 高德事实层 | 城市定位、真实 POI 搜索、地点消歧、营业信息、真实交通路线 | 解释用户意图 |
| 确定性规划层 | 候选筛选、固定锚点、分天、日内排序、时间模拟、真实路线校准、可行性判断 | 用文案掩盖不可行约束、静默删除必去点 |
| LLM 文案层 | 对已经确定的结果生成主题、贴士和冲突说明 | 改动地点、时间、顺序和交通 |

产品形态采用“双入口”：

1. **推荐入口：和行迹聊聊**——适合有特殊要求的用户。
2. **快速入口：按当前设置直接生成**——完整保留现有一键生成能力。

不以空白聊天取代现有表单；表单负责低成本输入确定字段，对话只补充表单难以表达的约束。

---

## 1. 背景与现状

### 1.1 当前生成链路

当前代码已经把几何规划从 DeepSeek 收回到确定性算法：

1. 城市地理编码。
2. 高德召回真实 POI。
3. `CandidateCuration` 按评分、兴趣、预算筛选。
4. `DayClusterer` 聚类分天。
5. `DayRouter` 最近邻 + 2-opt 排序。
6. `ScheduleSimulator` 按营业时间、停留时长和每日时间窗模拟。
7. `MealSlotter` 插入餐饮。
8. `SpillRepair` 跨天修复。
9. 高德真实路线回填并重放排程。
10. `NoteWriter` 只补每日主题和地点贴士。

因此本功能是确定性规划器的“需求理解前置层”，不是恢复旧的 LLM 盲排模式。

### 1.2 当前输入能力缺口

当前新建页可以输入：

- 目的地、日期、天数；
- 兴趣、菜系、住宿类型；
- 行程节奏、每日预算。

当前 `TripPrefs.freeText` 虽然存在，但新建草稿没有写入该字段，且自由字符串无法可靠表达：

- 必须去 / 最好去 / 不要去；
- 某天某时已有预约；
- 每天几点出发、几点结束；
- 酒店或车站作为每日起终点；
- 老人、儿童、无障碍和最大步行量；
- 只坐公共交通、允许打车、不接受轮渡等方式；
- 两项要求互相冲突时用户愿意牺牲什么。

### 1.3 用户问题

用户知道自己想要什么，但不一定知道哪些字段会影响路线，也不愿填写一张更长的高级表单。产品需要通过少量、针对性的交流，把自然语言收敛为可计算、可确认、可解释的约束。

---

## 2. 目标与非目标

### 2.1 产品目标

1. 用户可以用自然语言补充特殊需求。
2. 系统只追问对路线有实际影响的未知信息。
3. 所有用户要求在生成前都能以结构化摘要确认。
4. 点名地点必须绑定真实高德 POI，存在歧义时由用户选择。
5. 硬约束不能被规划器静默删除或降级。
6. 不可行时返回具体原因和可选择的修复方案，并允许继续对话。
7. LLM 不可用时，现有表单和直接生成路径仍可使用。
8. macOS 与 iOS 使用同一业务状态和 Core 契约，界面按空间自适应。

### 2.2 MVP 支持的意图

| 类型 | MVP 支持内容 |
|---|---|
| 基础行程 | 城市、日期、天数、人数构成 |
| 兴趣偏好 | 兴趣、菜系、住宿类型、预算、松紧节奏、室内/户外倾向 |
| 地点约束 | 必须去、优先去、不要去、指定某天 |
| 时间约束 | 每日开始/结束时间、固定到达时间、最短停留时间 |
| 起终点 | 酒店、车站、机场或用户指定 POI；允许每天不同 |
| 行动能力 | 老人、儿童、无障碍、单段最大步行时间、每日舒适负荷 |
| 交通偏好 | 允许/禁止步行、公交地铁、出租车、自驾、轮渡 |
| 餐饮偏好 | 菜系、忌口文字、用餐时间窗、是否必须排入主路线 |
| 冲突协商 | 闭馆、距离过远、预约冲突、日程超载、交通方式不可达 |

### 2.3 明确非目标

- 不做机票、酒店、门票预订和支付。
- 不做多个城市之间的跨城交通规划。
- 不承诺实时拥堵、天气、排队时长或余票。
- 不做多人账号、云同步和多人协作。
- 不让 LLM 自行创建 POI、坐标、营业时间或交通路线。
- MVP 不做长期用户画像学习；只保存用户确认的本次行程意图。
- MVP 不支持对已生成行程逐句聊天后原地局部修改；先采用“调整要求后重新规划”，后续再扩展局部重规划。

---

## 3. 成功指标与质量红线

### 3.1 产品指标

首版记录本地匿名诊断，不上传对话原文：

| 指标 | 建议目标 |
|---|---:|
| 从进入助手到点击生成的完成率 | ≥ 75% |
| 中位有效对话轮数 | ≤ 3 轮 |
| 地点消歧后 POI 绑定成功率 | ≥ 95% |
| 生成后立即因“没理解要求”而重做的比例 | < 15% |
| 直接生成路径相对当前版本的额外操作数 | 0 |
| 可恢复错误后草稿保留率 | 100% |

### 3.2 工程质量红线

以下项目必须为 100%：

- 用户明确的硬约束不被静默覆盖。
- `mustVisit` 不因排序分、spill 或真实路线校准而静默删除。
- `avoidVisit` 不进入最终主路线与备选推荐。
- 最终 POI 全部来自高德候选或既有缓存。
- 同一已确认 `TripIntent` 与同一候选集生成确定性一致的路线。
- LLM 返回畸形 JSON 时不污染当前意图。
- 用户取消或网络失败后，表单和已确认要求仍然存在。

---

## 4. 设计原则

1. **表单给确定性，对话给表达力。** 已填字段不重复询问。
2. **一次只解决一个主题。** 每轮最多提出一个主题、包含不超过三个紧密相关的小问题。
3. **让结构可见。** 用户随时看到系统理解了什么、哪些是推断、哪里有冲突。
4. **显式比聪明重要。** 模型推断的高影响字段必须让用户确认。
5. **硬约束是契约。** 不能满足就解释和协商，不能悄悄删掉。
6. **事实先落地。** 用户点名地点先经高德解析，再进入规划器。
7. **快速路径不退化。** 不需要对话的用户继续一键生成。
8. **沿用 Trailhead 视觉语言。** 使用系统字体、路线绿、原生控件、卡片和现有设计 token，不引入聊天产品式渐变、头像墙或独立品牌色。

---

## 5. 核心用户故事

### US-1：补充特殊要求

作为旅行者，我希望在填完基础信息后说“带两位老人，不要太赶”，系统能理解并询问是否接受打车，而不是让我寻找隐藏设置。

### US-2：点名地点

作为旅行者，我希望说“一定要去省博”，系统能在当前城市找到真实地点；存在多个同名地点时让我选择。

### US-3：固定预约

作为旅行者，我希望告诉系统“第二天下午两点预约了三星堆”，规划器把它当作固定锚点，不安排会导致迟到的路线。

### US-4：生成前确认

作为旅行者，我希望在生成前看到“必须去、不要去、每日时间、交通与步行限制”的摘要，能直接修改错误理解。

### US-5：冲突修复

作为旅行者，我希望系统在要求不可能同时满足时说明具体原因，并提供两到三个可行选择，而不是返回笼统的生成失败。

### US-6：跳过交流

作为只想快速看结果的用户，我希望沿用当前设置直接生成，不被迫完成对话。

---

## 6. 信息架构与主流程

### 6.1 主流程

| 阶段 | 用户动作 | 系统结果 |
|---|---|---|
| 1. 基础设置 | 在现有新建页填写城市、日期、天数和偏好 | 形成预填 `TripIntent` |
| 2A. 快速生成 | 点击“按当前设置直接生成” | 走现有生成流水线 |
| 2B. 对话完善 | 点击“和行迹聊聊” | 进入规划助手，表单值已显示在摘要中 |
| 3. 澄清 | 自然语言回答或选择快捷选项 | LLM 产生结构化 patch，本地合并校验 |
| 4. 地点核验 | 选择同名 POI 或确认自动匹配 | 形成真实 `poi_id` 约束 |
| 5. 确认 | 查看需求摘要并点击“按这些要求生成” | 冻结 `TripIntentSnapshot` |
| 6. 规划 | 查看生成进度 | 确定性规划 + 高德真实路线校准 |
| 7A. 成功 | 浏览行程 | 可从行程页进入“调整要求” |
| 7B. 冲突 | 查看原因并选择修复方向 | 回到助手，应用用户选择后重新规划 |

### 6.2 会话状态机

| 状态 | 说明 | 允许事件 | 下一状态 |
|---|---|---|---|
| `draft` | 来自表单的初始意图 | 打开助手、直接生成、取消 | `clarifying` / `generating` / 结束 |
| `clarifying` | 对话收集与确认需求 | 发送消息、点快捷选项、查看摘要、取消 | `clarifying` / `resolvingPOI` / `ready` |
| `resolvingPOI` | 处理点名地点歧义 | 选择候选、修改关键词、跳过软地点 | `clarifying` / `ready` |
| `ready` | 没有阻塞冲突，可确认生成 | 编辑字段、继续聊天、生成 | `clarifying` / `generating` |
| `generating` | 规划与真实路线校准 | 取消 | `completed` / `conflict` / `failedRecoverable` |
| `conflict` | 硬约束不可满足 | 选择替代方案、继续聊天、取消要求 | `clarifying` / `generating` |
| `failedRecoverable` | 网络、密钥或模型格式错误 | 重试、返回草稿、直接生成 | `clarifying` / `generating` |
| `completed` | 已生成并落库 | 浏览、调整要求 | 结束 / 新 `clarifying` |

任何异步回调都必须校验当前 `sessionID` 与状态，防止旧请求覆盖新输入。

---

## 7. UI 设计总则

### 7.1 视觉基线

完全复用现有 `Theme.swift`：

| 用途 | token / 规则 |
|---|---|
| 主操作、已确认、路线 | `Palette.green` `#1FA67A` |
| 选中与焦点 | `Palette.blue` |
| 餐饮 | `Palette.orange` |
| 住宿 | `Palette.purple` |
| 交通 | `Palette.slate` |
| 冲突与破坏性操作 | `Palette.red` |
| 页面背景 | `Palette.canvasBG` / `Palette.groupedBG` |
| 卡片 | `Palette.cardBG` + `Palette.cardStroke` |
| 圆角 | 字段 11、卡片 12/14、胶囊 20 |
| 字体 | SF Pro 系统字体，复用 `Typo` |

新增状态色只允许通过现有颜色的浅色背景表达，不新增品牌色。任何状态必须同时使用图标和文字，不能只依赖颜色。

### 7.2 自适应布局

| 平台 | 规划助手布局 |
|---|---|
| macOS | 建议 760×680 的 sheet；左侧会话区约 470，右侧需求摘要约 290；最小宽度 680，过窄时切为单列 |
| iPhone | `NavigationStack` 单列；顶部显示可折叠摘要条，完整摘要由工具栏按钮进入 sheet |
| iPad / 宽屏 iOS | 宽度允许时采用 macOS 同类双栏，但保留 iOS 导航与触控尺寸 |

所有 iOS 控件点击目标不小于 44pt；macOS 控件使用现有 `Metric.minimumControlTarget`。

---

## 8. 屏幕与交互规格

### DCP-01｜新建行程入口改造

**目的**：在不破坏当前新建表单的前提下提供两个明确出口。

保留当前字段、滚动结构、标题和固定底栏。修改内容：

1. 标题副文案改为：“先填基本信息，也可以让助手继续了解特殊要求”。
2. 底栏保留预计耗时和 API 调用量。
3. 主按钮：绿色填充，“和行迹聊聊”。
4. 次按钮：无填充文本按钮，“按当前设置直接生成”。
5. 主按钮图标使用 SF Symbol `sparkles`；次按钮不加装饰图标。
6. 目的地为空时两个按钮均禁用。
7. DeepSeek Key 不可用时：主按钮仍可点击，但进入前展示可恢复提示；次按钮继续按现有生成能力判断所需 Key。

辅助说明只显示一次，位于主按钮上方：

> 有必去地点、固定预约、老人儿童或步行限制？让行迹先问清楚。

**macOS 行为**：当前 sheet 内容切换到 `PlanningAssistantView`，避免叠加第二个 sheet。

**iOS 行为**：从“新建”页 push 到助手页；返回后表单内容和已生成的对话摘要保留。

**验收重点**：现有“直接生成”操作数不得增加。

### DCP-02｜规划助手主界面

#### 页面头部

- 左侧：返回按钮。
- 中间：“完善行程要求”，副标题为“成都 · 7月20日–22日 · 3天”。
- 右侧：“需求摘要”按钮；macOS 双栏时不显示该按钮。
- 关闭时若存在未生成的新内容，提示“保留草稿 / 放弃修改 / 继续编辑”。

#### 会话区

首条助手消息根据表单生成，不重复询问已知内容。例如：

> 你计划 7 月 20 日去成都 3 天，偏好美食、历史古迹和自然风光。还有必须去的地点、固定预约，或同行人的步行限制吗？

消息样式：

- 助手消息使用无头像的白色卡片，左上角小号 `sparkles` + “行迹助手”。
- 用户消息右对齐，使用 `Palette.green.opacity(0.12)`，文字仍为 `textPrimary`，不使用高饱和实心气泡。
- 消息最大宽度为会话区的 82%。
- 消息之间 10–12pt；主题变化前 18pt。
- 不显示模型名称、token、内部置信度数值。

#### 快捷回答

助手可以在消息下方提供 2–5 个胶囊选项，例如：

- “有老人同行”
- “带儿童”
- “不想走太多”
- “都没有”

快捷选项必须与文本输入等价，选择后作为一条用户消息进入同一意图解析流程。多选题必须明确标记“可多选”，并提供“完成”按钮，不能点击第一项后立即提交。

#### 输入区

- 固定在底部。
- 多行文本框占主要宽度，placeholder：“补充要求，或回答上面的问题…”
- 发送按钮使用圆形绿色 `arrow.up`。
- 空文本时发送按钮禁用。
- 异步解析期间允许继续输入，但发送按钮显示忙碌；同一会话只允许一个意图解析请求在途。
- macOS：`Command + Return` 发送，Return 换行。
- iOS：通过发送按钮提交，键盘 Return 保留换行。
- 输入内容在失败时不能丢失。

#### 解析中状态

在最新用户消息下方显示轻量行内状态：“正在整理你的要求…”，配小型 progress indicator。不要覆盖全屏，也不要使用模拟逐字打印。

### DCP-03｜实时需求摘要

摘要是用户与系统共享的“单一理解结果”，不是聊天记录总结。

分组顺序固定：

1. 基本信息。
2. 必须满足。
3. 偏好与节奏。
4. 交通与步行。
5. 餐饮与住宿。
6. 待确认。

每个要求显示为带图标的行或 chip：

| 状态 | 表达 |
|---|---|
| 用户明确 | 绿色 checkmark + 正常文字 |
| 用户已确认模型推断 | 绿色 checkmark + “已确认”辅助文本 |
| 模型推断待确认 | 橙色 questionmark + “待确认” |
| 默认值 | 灰色 + “默认” |
| 冲突 | 红色 exclamationmark + 冲突说明 |

交互：

- 点击字段进入局部编辑 sheet，使用原生控件而不是要求用户必须通过聊天修正。
- 左滑或 context menu 可移除软偏好。
- 删除硬约束需要二次确认。
- “查看原话”只在调试构建提供，正式界面不暴露内部 patch。
- 摘要顶部显示完成度文案，例如“已确认 6 项 · 1 项待确认”，不显示伪精确百分比。

macOS 摘要固定在右栏；iOS 顶部摘要条只显示最重要的 2–3 个 chip 和待确认数量，点击后进入完整摘要 sheet。

### DCP-04｜地点消歧卡

触发条件：点名地点未绑定 POI、同名候选置信度不足、候选与目标城市明显不符。

卡片内容：

- 标题：“你说的‘省博’是哪个？”
- 最多显示 4 个候选。
- 每项显示真实名称、类型、行政区/地址、距市中心或住宿的大致距离。
- 有照片时可显示 48×48 缩略图；无照片时使用对应类别 SF Symbol，不能显示空占位框。
- 单选使用整行点击和清晰选中态。
- 底部操作：“都不是，换个说法”。
- 对软偏好可提供“先跳过”；`mustVisit` 不允许在未解析时直接进入生成。

如果只有一个高置信候选，助手可以自动绑定，但在摘要中显示真实全名，并提供“不是这里”撤销入口。

### DCP-05｜生成前确认

当本地 `ClarificationPolicy` 判定为 ready，助手发送完成卡，而不是自动开始生成。

卡片标题：“规划需求已准备好”。

内容必须明确展示：

- 目的地、日期、天数。
- 必须去和不要去的地点。
- 固定预约。
- 每日活动时间。
- 交通/步行限制。
- 仍使用默认值的高影响字段。

底部操作：

1. 主按钮：“按这些要求生成”。
2. 次按钮：“继续补充”。
3. 文本操作：“查看完整需求”。

如果只有软性待确认项，可生成，但必须显示“将按默认设置处理 1 项”。存在任何阻塞性歧义或硬冲突时，主按钮禁用并解释原因。

### DCP-06｜生成进度

复用现有 `GeneratingView` 的圆环和步骤卡，步骤调整为：

1. 理解并锁定需求。
2. 核验指定地点。
3. 规划每日路线。
4. 校准真实交通。
5. 生成行程说明。

进度文案不能继续把总进度简单换算成“已规划 N 天”；只有引擎实际提供逐日状态时才显示天数，否则显示当前步骤说明。

取消后回到确认页，保留冻结的意图快照和地点解析结果。再次生成应优先复用 POI 与路线缓存。

### DCP-07｜约束冲突修复

生成中发现硬约束不可满足时，不显示通用错误 alert，切换到助手的冲突卡。

卡片结构：

- 标题：“有一项要求无法同时满足”。
- 事实原因，例如：“杜甫草堂周一 18:00 闭馆；按当前路线最早 18:35 到达。”
- 受影响要求：“必须去杜甫草堂”“每天 18:00 前结束”。
- 2–3 个由确定性修复器计算出的真实选项，例如：
  - 改到第二天上午；
  - 第一天延长到 19:30；
  - 保留结束时间，取消该必去要求。
- 主操作：“应用并重新规划”。
- 次操作：“我想换个办法”，回到输入框。

LLM 可以改写说明，但选项内容、可行性和代价必须来自规划器，不得自行提出未经验证的替代路线。

### DCP-08｜生成结果中的要求入口

生成成功后：

- 行程页标题区域增加轻量入口：“已按 7 项要求规划”。
- 点击打开只读需求摘要。
- 摘要底部提供“调整要求并重新规划”。
- 固定预约的时间线卡片显示 `calendar.badge.clock` + “固定预约”。
- 必去点显示 `pin.fill` + “必去”。
- 不要在每张普通卡片重复显示兴趣匹配标签，避免挤压主路线信息。

“调整要求并重新规划”创建新会话版本，原行程在新方案成功前保持可浏览；失败不能覆盖原行程。

---

## 9. 文案规范

### 9.1 助手语气

- 简短、具体、像行程顾问，不像客服或心理咨询。
- 先复述已经理解的结论，再问缺失信息。
- 不说“作为 AI”“根据算法”“我无法保证”等内部化表达。
- 不虚构“我查过”——只有完成高德查询后才说“已找到”。
- 不连续道歉；失败时直接说明原因和恢复动作。

### 9.2 推荐文案

| 场景 | 文案 |
|---|---|
| 首次询问 | “基本信息已经有了。还有必须去的地点、固定预约，或同行人的步行限制吗？” |
| 确认推断 | “你提到两位老人同行。是否按单段步行不超过 15 分钟，并允许打车接驳？” |
| POI 自动匹配 | “已找到‘四川博物院’，地址在浣花南路；如果不是这里可以更换。” |
| ready | “要求已经整理好了，可以开始规划。” |
| 闭馆冲突 | “这个时间会晚于闭馆时间 35 分钟，需要调整日期、结束时间或必去要求。” |
| 模型失败 | “这条要求暂时没有整理成功，内容已保留。可以重试，或按当前已确认设置继续。” |

### 9.3 禁止文案

- “好的，我完全明白了”——仍有不确定项时禁止。
- “已为你完美规划”——不可验证的绝对表述。
- “可能是网络问题”——已有具体错误类型时禁止模糊表达。
- “系统异常”“未知错误”——必须提供恢复动作。

---

## 10. 无障碍、键盘与动态字体

1. 消息列表新增内容通过 VoiceOver announcement 提示，但不能强制抢走输入框焦点。
2. 快捷选项以 Button/Toggle 暴露，读出“已选择/未选择”。
3. 需求状态必须读出“已确认、待确认、默认或冲突”，不能只靠颜色。
4. 地点候选整行可点击，并提供明确单选状态。
5. 发送按钮 accessibility label 为“发送要求”，不能只读图标名。
6. 生成步骤读出步骤名和“已完成/进行中/等待中”。
7. macOS 完整支持 Tab 顺序、Space 选择、Escape 返回、Command+Return 发送。
8. 动态字体放大后，双栏可降为单栏；按钮文字不得截断。
9. 文本对比度使用现有 `textPrimary/Secondary`，避免用 `textTertiary` 承载关键要求。
10. 动效遵循 Reduce Motion；不得用动画作为唯一状态提示。

---

## 11. 数据模型与契约

### 11.1 `TripIntent`

建议新增独立 Codable 值类型，不把所有字段继续塞进 `TripPrefs`：

```swift
public struct TripIntent: Codable, Hashable, Sendable {
    public var destination: DestinationIntent
    public var startDate: Date
    public var days: Int
    public var party: TravelParty
    public var preferences: TripPrefs
    public var poiConstraints: [POIConstraint]
    public var dailyConstraints: [DailyConstraint]
    public var mobility: MobilityConstraint
    public var transport: TransportConstraint
    public var meals: MealConstraint
    public var rawNotes: String
    public var revision: Int
}
```

`TripPrefs` 继续承载现有兼容字段；新硬约束进入 `TripIntent`，避免破坏旧 Trip 解码。

### 11.2 约束来源

```swift
public enum IntentSource: String, Codable, Sendable {
    case userExplicit
    case userConfirmed
    case modelInferred
    case systemDefault
}

public enum ConstraintPriority: String, Codable, Sendable {
    case hard
    case soft
}
```

所有高影响推断字段使用包装结构保存 `value/source/confidence/confirmedAt`。置信度仅用于本地追问策略，不直接展示给用户。

### 11.3 POI 约束

```swift
public enum POIRequirement: String, Codable, Sendable {
    case mustVisit
    case preferVisit
    case avoidVisit
}

public struct POIConstraint: Codable, Hashable, Sendable {
    public var mention: String
    public var resolvedPOIID: String?
    public var resolvedName: String?
    public var requirement: POIRequirement
    public var assignedDay: Int?
    public var fixedArrivalMinute: Int?
    public var minimumStayMinutes: Int?
    public var source: IntentSource
}
```

### 11.4 每日约束

```swift
public struct DailyConstraint: Codable, Hashable, Sendable {
    public var dayIndex: Int
    public var startMinute: Int
    public var endMinute: Int
    public var startAnchorPOIID: String?
    public var endAnchorPOIID: String?
}
```

`ItineraryDayBuilder.dayStart/dayEnd` 的固定 09:00–20:00 改为无用户输入时的默认值，不再是规划器唯一真源。

### 11.5 规划会话

```swift
public struct PlanningSession: Codable, Identifiable, Sendable {
    public var id: UUID
    public var state: PlanningSessionState
    public var intent: TripIntent
    public var messages: [PlanningMessage]
    public var pendingAmbiguities: [IntentAmbiguity]
    public var createdAt: Date
    public var updatedAt: Date
}
```

存储原则：

- 草稿会话本地持久化，App 重启可恢复。
- 生成成功后把确认的 `TripIntent` 快照与 Trip 关联。
- 完整聊天记录默认只保留在规划草稿；成功后可删除，只保留用户确认的结构化意图和最后一段 `rawNotes`。
- 诊断不记录完整用户文本、地点原话或同行人敏感信息。

---

## 12. LLM 意图理解协议

### 12.1 协议拆分

新增独立协议，避免复用语义已经过时的 `planItinerary`：

```swift
public protocol IntentUnderstandingProvider: Sendable {
    func interpret(_ request: IntentInterpretationRequest) async throws -> IntentInterpretationResponse
}
```

输入只包含：

- 当前已确认意图摘要；
- 尚未确认字段；
- 最近必要消息，建议最多 6 条；
- 当前用户消息；
- 允许修改的字段 schema 和枚举；
- 本地策略提出的当前问题。

不要每轮发送全部历史 POI、完整路线或无关聊天。

### 12.2 LLM 输出

模型必须使用 JSON mode，输出：

```json
{
  "assistant_text": "了解到你们有两位老人同行。",
  "operations": [
    {
      "op": "set",
      "path": "party.seniors",
      "value": 2,
      "source": "userExplicit",
      "confidence": 1.0
    }
  ],
  "poi_mentions": [
    {
      "text": "熊猫基地",
      "requirement": "mustVisit"
    }
  ],
  "uncertainties": [
    {
      "path": "transport.allowTaxi",
      "reason": "老人同行但用户未表达交通偏好",
      "confidence": 0.65
    }
  ],
  "suggested_question_ids": ["mobility_taxi_permission"]
}
```

模型不能输出 POI ID、经纬度、营业时间、最终路线、规划 ready 状态或自由字段路径。

### 12.3 本地验证与合并

处理顺序固定：

1. 解码 JSON。
2. 校验操作类型与允许路径。
3. 校验数值范围、日期、时间和枚举。
4. 拒绝模型给出的未知字段。
5. 根据来源优先级执行 patch。
6. 检测显式冲突。
7. 提取 POI mention，交给 `POIResolver`。
8. 由本地 `ClarificationPolicy` 决定下一状态和问题。

合并优先级：

```text
用户最新明确表达
> 用户较早明确表达
> 用户确认过的模型推断
> 未确认模型推断
> 系统默认值
```

模型畸形响应允许重试一次；两次失败不得修改当前意图。

---

## 13. 澄清问题算法

### 13.1 阻塞字段

以下情况必须阻止进入生成：

- 目的地为空或无法地理编码。
- 天数不在 1...14。
- `mustVisit` 尚未绑定真实 POI。
- 同一个 POI 同时为 must 和 avoid。
- 固定时间不在对应日活动时间内。
- 开始时间不早于结束时间。
- 固定锚点之间仅按理论最短交通也无法到达。
- 用户禁止所有可达交通方式。

### 13.2 问题价值

对每个未知或冲突字段计算：

```text
QuestionUtility(field) =
    routeImpact(field)
  × uncertainty(field)
  × answerability(field)
  - interactionCost(field)
  - repetitionPenalty(field)
```

建议权重层级：

| 层级 | 字段 |
|---|---|
| P0 | 城市/日期/天数冲突、固定预约、未解析必去点、行动能力硬限制 |
| P1 | 每日起止时间、起终点、允许交通方式、最大步行量 |
| P2 | 兴趣、菜系、住宿类型、预算、室内外偏好 |
| P3 | 文案风格、非路线相关偏好 |

选择最高价值的一个主题提问。若同一主题内有紧密相关字段，可合并为不超过三个小问题。

### 13.3 ready 条件

满足以下全部条件才显示确认生成卡：

1. 没有阻塞字段。
2. 所有硬约束已确认并通过静态校验。
3. 所有 `mustVisit` 已绑定 POI。
4. 高影响模型推断已得到确认或恢复默认。
5. 用户主动说“直接生成”时，只有软性缺失可跳过。

LLM 的建议问题只作为候选，本地策略拥有最终决定权。

---

## 14. 地点解析与消歧算法

### 14.1 解析流程

1. LLM 只提取用户原始 mention 与 must/prefer/avoid 语义。
2. 先完成目的城市 geocode，得到 adcode。
3. 使用高德关键词搜索，限定 adcode。
4. 过滤明显不属于目标城市或类别冲突的结果。
5. 计算候选匹配分。
6. 高置信且唯一时自动绑定；否则进入 DCP-04。

### 14.2 匹配分

```text
ResolutionScore =
    0.45 × nameSimilarity
  + 0.20 × cityConsistency
  + 0.15 × categoryConsistency
  + 0.10 × popularityQuality
  + 0.10 × distanceToTripAnchor
```

自动绑定必须同时满足：

- 第一名得分高于建议阈值 0.82；
- 第一名与第二名差值不低于 0.12；
- 城市一致；
- 没有明显类别冲突。

阈值应集中配置并通过真实样本调整，不散落硬编码。

### 14.3 缓存

缓存键建议为：

```text
adcode + normalizedMention + resolverSchemaVersion
```

缓存搜索结果，不缓存用户最终选择；最终绑定属于当前 `PlanningSession`。

---

## 15. 约束编译与线路算法

### 15.1 约束编译

`ConstraintCompiler` 将 `TripIntent` 转为规划器只读输入：

```swift
public struct PlanningConstraints: Sendable {
    public var requiredPOIIDs: Set<String>
    public var preferredPOIIDs: Set<String>
    public var excludedPOIIDs: Set<String>
    public var fixedVisits: [FixedVisit]
    public var dailyWindows: [DayWindow]
    public var dailyAnchors: [DayAnchors]
    public var allowedModes: Set<TransitMode>
    public var maxWalkingMinutesPerSegment: Int?
    public var accessibilityRequired: Bool
}
```

编译失败必须返回结构化 `PlanningConflict`，不得传入一个部分有效的约束集。

### 15.2 召回与筛选

1. 标准类别召回继续执行。
2. 每个点名地点单独召回并注入候选池。
3. `excludedPOIIDs` 在候选筛选和备选推荐前统一移除。
4. `requiredPOIIDs` 强制进入候选，不受 top-K 限制。
5. `preferredPOIIDs` 通过效用加权提高入选概率。
6. must 不得通过“巨大加分”近似实现，必须是独立硬约束。

普通候选效用：

```text
Utility(p) =
    ratingQuality
  + interestAffinity
  + cuisineAffinity
  + budgetFit
  + diversityGain
  - duplicateSubtypePenalty
  - accessibilityRisk
  - routeDistancePenalty
```

### 15.3 固定锚点优先

每一天先放入：

- 当日起点、终点；
- 固定预约地点和时间；
- 用户指定必须在当天的地点。

固定锚点把一天切成多个可规划区间。规划器不得通过 2-opt、swap 或 spill 改变固定锚点的相对顺序和固定到达时间。

### 15.4 最佳插入

对剩余候选 `x`，在相邻点 `a/b` 间计算：

```text
InsertionCost(x, a, b) =
    travel(a, x)
  + stay(x)
  + travel(x, b)
  - travel(a, b)
```

插入目标：

```text
Objective =
    Σ selectedUtility
  - λ × totalTravelMinutes
  - μ × comfortOverload
  - ν × softConstraintViolations
```

只有经快速时间模拟仍可满足以下条件的插入才有效：

- 营业窗；
- 固定预约；
- 每日起止时间；
- 交通方式限制；
- 单段最大步行量；
- 进入/排队/离场 buffer；
- 舒适负荷预算。

### 15.5 局部优化

初始方案完成后，按固定顺序执行，确保确定性：

1. 区间内 2-opt。
2. 同日 relocate。
3. 同日 swap。
4. 跨日 relocate。
5. 跨日 swap。
6. 删除最低效用可选点。

平手按 `poi_id`、dayIndex、原始顺序依次破平。固定点和必去点不可进入删除候选。

### 15.6 两遍模拟与餐饮

继续复用现有两遍模拟：

1. 景点初排并生成临时时刻线。
2. 根据用户餐窗与绕行代价插入餐饮。
3. 景点 + 餐饮重放终版模拟。

如果用户明确“餐饮只作为附近推荐”，`MealSlotter` 不把餐厅排入主路线；如果明确固定餐厅和时间，则该餐厅作为固定锚点。

### 15.7 真实路线校准

1. 先用本地估算得到候选方案。
2. 调高德获取实际相邻段交通。
3. 依据真实耗时重放全天。
4. 溢出时依次尝试 relocate、跨天移动、删除可选点。
5. 仍需删除必去或固定点时返回冲突。

不能沿用“返回最优可行子集并只写 warning”的语义处理用户硬约束。

### 15.8 冲突输出

```swift
public struct PlanningConflict: Error, Codable, Sendable {
    public var code: PlanningConflictCode
    public var affectedConstraintIDs: [String]
    public var facts: [ConflictFact]
    public var repairOptions: [RepairOption]
}
```

`repairOptions` 必须由确定性修复器实际试算后生成，至少包含：

- 对意图的 patch；
- 是否保持所有 must；
- 预计新增交通或延长时间；
- 应用后是否已通过快速可行性检查。

LLM 只能把这些事实写成自然语言。

---

## 16. Core 与 App 集成方案

### 16.1 Core 新增模块

| 模块 | 职责 |
|---|---|
| `TripIntent.swift` | 意图与约束值类型 |
| `PlanningSession.swift` | 会话状态、消息、版本 |
| `IntentUnderstandingProvider.swift` | 对话意图协议 |
| `IntentMerger.swift` | patch 白名单、来源优先级、冲突检测 |
| `ClarificationPolicy.swift` | 阻塞检查、问题价值、ready 判断 |
| `POIResolver.swift` | 真实地点搜索、打分、消歧 |
| `ConstraintCompiler.swift` | TripIntent → PlanningConstraints |
| `ConstrainedPlanner.swift` | 固定锚点、最佳插入、局部优化 |
| `PlanningConflict.swift` | 结构化冲突与修复选项 |
| `PlanningSessionStore.swift` | 本地草稿与恢复 |

### 16.2 既有模块改造

| 模块 | 改造 |
|---|---|
| `DeepSeekClient` | 实现 `IntentUnderstandingProvider`，保留 NoteWriter 能力 |
| `ItineraryEngine` | 新增接收 `TripIntentSnapshot`/`PlanningConstraints` 的 generate 重载；旧接口保持兼容 |
| `POIRecall` | 接收显式 POI mentions、must/prefer/avoid，不再只解析 freeText |
| `CandidateCuration` | required 强制保留、excluded 统一过滤、preferred 加权 |
| `DayClusterer` | 支持预分配固定日和每日容量 |
| `DayRouter` | 支持多个固定锚点与区间内优化 |
| `ScheduleSimulator` | 支持逐日时间窗、固定到达、步行限制 |
| `MealSlotter` | 支持用户餐窗与“主路线/仅推荐”模式 |
| `SpillRepair` | 禁止 spill/drop required；输出冲突 |
| `ItineraryFeasibility` | 区分 hard violation 与 soft warning |
| `TripRepository` | 保存确认的 TripIntent 快照，调整要求时版本化 |

### 16.3 App 新增界面

| 界面/组件 | 职责 |
|---|---|
| `PlanningAssistantView` | 自适应助手容器 |
| `PlanningConversationView` | 消息列表、快捷选项、输入框 |
| `IntentSummaryView` | 实时需求摘要与编辑 |
| `POIDisambiguationCard` | 地点候选选择 |
| `PlanningConfirmationCard` | 生成前确认 |
| `PlanningConflictCard` | 冲突说明与修复选择 |
| `IntentFieldEditor` | 对单项结构化字段进行原生编辑 |
| `TripIntentSummarySheet` | 结果页只读摘要与重新规划入口 |

`RootView` 继续持有生成任务，但会话状态建议由独立 `PlanningAssistantModel` 管理，避免把聊天、意图和路线生成全部堆进 Root。

---

## 17. 错误、离线与降级

| 场景 | UI 行为 | 数据行为 |
|---|---|---|
| DeepSeek Key 缺失 | 助手页提示去设置；提供“按当前设置直接生成” | 保留表单与草稿 |
| LLM 超时 | 行内错误 + 重试；允许继续编辑 | 不应用本轮 patch |
| LLM JSON 畸形 | 自动重试一次；仍失败显示恢复操作 | 不污染 intent |
| 高德地点搜索失败 | 地点卡显示重试；软地点可跳过，must 不可生成 | 保留 mention |
| 高德配额耗尽 | 优先缓存；无缓存时给出明确限制 | 不伪造 POI |
| 生成任务取消 | 回确认页 | 保留冻结快照和已解析 POI |
| App 退出 | 下次展示“继续完善上次行程” | 本地恢复 session |
| 规划硬冲突 | 进入冲突卡，不显示通用失败 alert | 原 Trip 不被覆盖 |
| NoteWriter 失败 | 路线正常完成，主题与贴士为空 | 与现有降级一致 |

离线时如果已有城市 POI 缓存，可以允许打开助手并编辑结构化要求；需要 LLM 解析的新自然语言暂存为未处理消息，联网后继续。MVP 也可简化为明确提示“对话需要联网”，但直接生成和浏览已有行程不应被助手阻断。

---

## 18. 隐私与安全

1. API Key 继续只存 Keychain。
2. LLM 请求只发送完成意图理解所需的最小上下文。
3. 不发送完整历史行程、API Key、设备信息或 SwiftData 内容。
4. 对话记录只存本机；默认不写入诊断。
5. 成功生成后只持久化结构化需求快照，完整聊天可清理。
6. LLM patch 使用路径白名单，禁止任意键路径和未知枚举。
7. 用户文本不得改变 system prompt、工具边界或允许输出 schema。
8. 所有 POI ID、坐标、营业和路线事实必须来自高德或本地可信缓存。

---

## 19. 本地诊断

在 `GenerationDiagnostics` 或独立 `ConversationDiagnostics` 中记录：

- 会话轮数；
- 解析成功/失败次数；
- 模型响应耗时和 token；
- patch 数量与被拒绝数量；
- POI mention 数、自动绑定数、用户消歧数；
- ready 前阻塞项数量；
- 生成冲突类型和修复次数；
- 用户选择直接生成或对话生成；
- 最终硬约束数量、满足数量；
- 总生成时长与缓存命中。

禁止记录：完整消息、用户自由文本、同行人描述原文、具体敏感地点原话。

Debug 构建可提供“对话诊断”入口，展示结构化 intent、字段来源、被拒绝 patch 和状态转移；Release 不显示。

---

## 20. 测试策略

### 20.1 Core 单测

1. `IntentMerger` 来源优先级。
2. 最新用户明确值覆盖旧值。
3. 模型推断不能覆盖用户明确值。
4. 畸形路径、未知枚举、越界时间全部拒绝。
5. 同一消息重试不重复添加 POI 约束。
6. ClarificationPolicy 阻塞、优先级和 ready 判断。
7. POIResolver 自动绑定和消歧阈值。
8. must/prefer/avoid 召回与筛选语义。
9. 固定锚点不会被 2-opt 或 spill 改动。
10. required 永不被 drop。
11. 每日不同时间窗生效。
12. 真实路线溢出时先移除 optional。
13. 无法保留 required 时返回 conflict。
14. 同输入确定性回归。
15. 老 TripPrefs/Trip 解码兼容。

### 20.2 LLM 契约测试

建立中文 golden cases，不依赖真实网络：

- “带两个老人，不要走太多”。
- “第二天下午两点预约三星堆”。
- “熊猫基地必须去，宽窄巷子不要去”。
- “不要太早，十点以后出门”。
- “只坐公共交通，但最多走十分钟”。
- 用户纠正：“不是四川博物院，我说的是成都博物馆”。
- 用户撤回：“算了，不要求必须去”。
- 多轮冲突与否定表达。

断言模型 mock 输出经 validator 后形成预期 patch；不对具体助手文案逐字断言。

### 20.3 App/UI 测试

- 两个入口都可达，直接生成操作数不增加。
- macOS 双栏和窄窗口单栏切换。
- iPhone SE、标准 iPhone、Pro Max 布局。
- 键盘遮挡不覆盖输入框。
- 发送中、失败、重试、取消、恢复。
- 多选快捷选项不会误提交。
- 摘要编辑同步回会话。
- POI 单选和“都不是”。
- 确认页阻塞和可生成状态。
- 冲突应用后重新规划。
- 原行程在重规划失败时仍存在。
- 深色模式、动态字体、Reduce Motion。

### 20.4 端到端验收样例

**样例 A：老人 + 必去点**

> 成都 3 天，2 位老人，熊猫基地必须去，每段步行不超过 15 分钟，允许打车。

验收：熊猫基地绑定真实 POI；不被 spill；交通模式满足；摘要可见；路线可行。

**样例 B：固定预约**

> 第二天 14:00 三星堆，至少停留 3 小时，每天 20:00 前回酒店。

验收：固定时间锁定；前序安排不导致迟到；若酒店过远产生可解释冲突。

**样例 C：冲突**

> 周一 18:00 后去一个 18:00 闭馆的必去点。

验收：不生成伪路线；返回闭馆事实和至少一个实际试算可行的修复方案。

---

## 21. 开发任务拆解

执行约定：

- 每个任务单一职责。
- 后续 AI 每次只领取一个任务或一个明确批次。
- 完成任务后必须运行对应验收，不以“编译通过”代替行为测试。
- UI 任务使用 mock provider 先完成全部状态，再接真实服务。
- 不允许在 UI 中复制 Core 规则。

### 阶段 P0｜契约与状态基础

| ID | 任务 | 产出与验收 | 依赖 |
|---|---|---|---|
| CP-0.1 | 定义 `TripIntent` 及子类型 | Codable/Hashable/Sendable；默认值与边界单测；老 TripPrefs 不受影响 | — |
| CP-0.2 | 定义 `PlanningSession` 状态与消息 | 状态枚举、消息角色、revision；非法状态转移单测 | CP-0.1 |
| CP-0.3 | 定义意图 patch schema | 操作、路径白名单、值类型、来源；未知路径拒绝 | CP-0.1 |
| CP-0.4 | 实现 `IntentMerger` | 来源优先级、幂等、撤回和冲突；完整单测 | CP-0.3 |
| CP-0.5 | 实现 `ClarificationPolicy` | 阻塞字段、问题价值、ready 判断；表驱动单测 | CP-0.4 |
| CP-0.6 | 定义 `PlanningConflict/RepairOption` | 可编码、可本地化事实、硬/软分类；单测 | CP-0.1 |

### 阶段 P1｜LLM 对话与会话编排

| ID | 任务 | 产出与验收 | 依赖 |
|---|---|---|---|
| CP-1.1 | 新增 `IntentUnderstandingProvider` | 请求/响应协议与 stub；Core 无 UI 依赖 | CP-0.3 |
| CP-1.2 | DeepSeek 实现意图 JSON 调用 | JSON mode、超时、重试一次、UsageStore；mock URLProtocol 测试 | CP-1.1 |
| CP-1.3 | 实现 `PlanningCoordinator` | 发送→解析→校验→合并→策略；旧响应不能覆盖新 revision | CP-0.4, CP-0.5, CP-1.1 |
| CP-1.4 | 实现会话草稿存储 | 本地保存、恢复、删除；不写入 API Key；迁移测试 | CP-0.2 |
| CP-1.5 | 增加对话诊断 | 不记录消息原文；耗时、token、拒绝 patch 可查询 | CP-1.3 |
| CP-1.6 | 建立中文 golden intent cases | 覆盖否定、撤回、固定时间、老人儿童、步行限制 | CP-1.3 |

### 阶段 P2｜POI 解析

| ID | 任务 | 产出与验收 | 依赖 |
|---|---|---|---|
| CP-2.1 | 定义 `POIResolver` 协议与结果 | resolved/ambiguous/notFound/failed；stub 测试 | CP-0.1 |
| CP-2.2 | 实现高德地点解析 | adcode 限定、匹配分、阈值集中配置、缓存 | CP-2.1 |
| CP-2.3 | 接入 coordinator | mention 自动解析；must 未解析阻塞；revision 安全 | CP-1.3, CP-2.2 |
| CP-2.4 | POI 解析回归样本 | 同名、简称、错城、类别冲突、无结果 | CP-2.2 |

### 阶段 P3｜助手 UI

| ID | 任务 | 产出与验收 | 依赖 |
|---|---|---|---|
| CP-3.1 | 改造新建页双入口 | 主/次按钮、说明、禁用态；直接生成操作数不增加 | CP-0.1 |
| CP-3.2 | 搭建自适应助手容器 | macOS 双栏、窄屏单栏、iOS push；全用 mock | CP-0.2 |
| CP-3.3 | 消息列表与输入区 | 消息、快捷选项、多选、发送、解析中、键盘行为 | CP-3.2 |
| CP-3.4 | 实时需求摘要 | 状态图标、分组、局部编辑、iOS sheet | CP-0.4, CP-3.2 |
| CP-3.5 | POI 消歧卡 | 真实字段、单选、都不是、软性跳过、无图降级 | CP-2.1, CP-3.3 |
| CP-3.6 | 生成前确认卡 | 阻塞态、默认值提示、生成/继续补充 | CP-0.5, CP-3.3, CP-3.4 |
| CP-3.7 | 错误与恢复状态 | 缺 Key、超时、畸形 JSON、取消、草稿恢复 | CP-1.4, CP-3.3 |
| CP-3.8 | 接入真实 coordinator | UI 不包含合并规则；状态全由 model 驱动 | CP-1.3, CP-2.3, CP-3.3...3.7 |
| CP-3.9 | UI 无障碍与键盘 | VoiceOver label、Tab 顺序、动态字体、Reduce Motion | CP-3.8 |

### 阶段 P4｜确定性约束规划

| ID | 任务 | 产出与验收 | 依赖 |
|---|---|---|---|
| CP-4.1 | 实现 `ConstraintCompiler` | 完整输入或结构化冲突；不产生部分有效结果 | CP-0.6 |
| CP-4.2 | 改造召回与筛选语义 | required 注入、excluded 过滤、preferred 加权 | CP-2.2, CP-4.1 |
| CP-4.3 | 每日独立时间窗 | 09:00–20:00 成为默认；模拟器逐日读取约束 | CP-4.1 |
| CP-4.4 | 每日起终点 | 支持不同 anchor；路线与真实校准首尾一致 | CP-4.3 |
| CP-4.5 | 固定访问锚点 | 时间锁定、区间切分、静态不可行检测 | CP-4.3, CP-4.4 |
| CP-4.6 | 最佳插入算法 | 按效用/增量成本插入；同输入确定性 | CP-4.5 |
| CP-4.7 | 受约束局部优化 | 2-opt/relocate/swap 不移动固定点 | CP-4.6 |
| CP-4.8 | 行动与交通限制 | 单段步行上限、允许模式、无障碍硬过滤 | CP-4.1, CP-4.6 |
| CP-4.9 | Spill 与可行性语义 | required 永不 drop；失败返回 conflict | CP-0.6, CP-4.7 |
| CP-4.10 | 真实路线后的约束修复 | relocate→跨天→drop optional→conflict | CP-4.8, CP-4.9 |
| CP-4.11 | 确定性与硬约束回归套件 | 全部质量红线自动测试 | CP-4.2...4.10 |

### 阶段 P5｜端到端集成

| ID | 任务 | 产出与验收 | 依赖 |
|---|---|---|---|
| CP-5.1 | `ItineraryEngine` 新入口 | 接收 intent snapshot；旧 generate 接口继续通过 | CP-4.11 |
| CP-5.2 | 更新生成进度 | 新五步骤；不再伪算已规划天数 | CP-5.1 |
| CP-5.3 | 冲突卡与重规划闭环 | repair patch→重新编译→重新规划；原 Trip 安全 | CP-3.8, CP-5.1 |
| CP-5.4 | Trip 保存意图快照 | 成功后可查看；旧 Trip 无快照正常展示 | CP-1.4, CP-5.1 |
| CP-5.5 | 结果页需求入口 | 摘要、必去/固定标记、调整并重新规划 | CP-5.4 |
| CP-5.6 | 端到端 mock 测试 | 对话→消歧→确认→生成→冲突→修复→落库 | CP-5.2...5.5 |

### 阶段 P6｜视觉与发布质量

| ID | 任务 | 产出与验收 | 依赖 |
|---|---|---|---|
| CP-6.1 | macOS 视觉回归 | 标准宽度、最小宽度、浅/深色截图对比 | CP-5.6 |
| CP-6.2 | iOS 视觉回归 | SE、标准、Pro Max、iPad；键盘与旋转 | CP-5.6 |
| CP-6.3 | 完整无障碍走查 | VoiceOver、键盘、动态字体、对比度 | CP-3.9, CP-5.6 |
| CP-6.4 | 性能与费用验证 | 中位轮次、LLM token、缓存复用、取消响应 | CP-5.6 |
| CP-6.5 | 失败注入 | LLM/高德超时、配额、畸形响应、App 重启 | CP-5.6 |
| CP-6.6 | 文档与设置说明 | README、API 用量估计、隐私说明、支持范围 | CP-6.1...6.5 |

---

## 22. 推荐实施批次

后续 AI 不宜一次实现整个 PDR。建议按以下批次执行：

| 批次 | 范围 | 可演示结果 |
|---|---|---|
| Batch A | CP-0.* + CP-1.1 + stub | 完整结构化意图、合并和追问策略测试 |
| Batch B | CP-3.1...3.7（全 mock） | 双端可体验完整助手 UI 和所有状态 |
| Batch C | CP-1.2...1.6 + CP-2.* + CP-3.8 | 真实对话和真实地点消歧，但尚不生成受约束路线 |
| Batch D | CP-4.1...4.7 | 时间窗、固定锚点和插入优化 |
| Batch E | CP-4.8...4.11 | 行动/交通限制、真实路线修复和硬约束保证 |
| Batch F | CP-5.* | 完整端到端闭环与结果页入口 |
| Batch G | CP-6.* | 双端视觉、无障碍、性能和失败质量 |

每个批次结束都应有独立演示和回归测试，不能等到最终集成才首次验证 UI 或算法。

---

## 23. Definition of Done

功能只有同时满足以下条件才算完成：

1. 用户可选择直接生成或进入助手，两条路径都可用。
2. 助手不会重复询问表单已知字段。
3. 自然语言被转换为可见、可编辑、带来源的结构化要求。
4. 点名地点全部绑定真实 POI；歧义由用户选择。
5. 生成前有明确确认步骤，不自动提交。
6. 硬约束全链路不可静默覆盖、删除或降级。
7. 不可行要求返回事实、受影响约束和试算过的修复方案。
8. macOS/iOS、浅色/深色、动态字体、键盘和 VoiceOver 核心流程通过。
9. LLM、高德、取消、重启和重规划失败均能恢复且不丢草稿。
10. 旧 Trip、旧 `TripPrefs`、旧直接生成入口和现有编辑功能全部回归通过。
11. Core 与 App 测试全过，确定性回归无漂移。
12. README 与设置页准确说明对话需要的 API、隐私边界和降级方式。

---

## 24. 后续可选增强

不进入本期，但当前数据契约应允许未来扩展：

- 对已生成行程说“第二天太累，放松一点”的局部重规划。
- 在时间线中直接对某一天发起对话。
- 展示两个可行方案的取舍比较。
- 用户确认后记住长期偏好，例如默认 10:00 出门。
- 结合天气把室内/户外作为动态软约束。
- 结合实时拥堵重新计算当天剩余路线。
- 多城市行程与跨城交通锚点。

这些增强仍应遵守同一边界：LLM 理解和解释，事实与路线由可信数据和确定性算法负责。
