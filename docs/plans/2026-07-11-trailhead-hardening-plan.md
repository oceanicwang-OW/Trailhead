# Trailhead 可靠性与体验加固计划

日期：2026-07-11

目标：先消除会让用户误判路线可执行性的缺陷，再提升推荐相关性、诊断能力和无障碍体验。

## Phase 1 — P0 路线可信度

### 1.1 交通段永不静默断链

涉及：`ItineraryDayBuilder.routedSegment`、`buildItems`、`PlanItem`、`TransportRow`。

- 真实路线成功：保存真实 mode、minutes、meters、cost，标记 `verified`。
- 真实路线失败：使用 `TravelEstimator` 生成兜底交通段，标记 `estimated`，UI 显示“估算 · 待联网校准”。
- 只有相邻两个地点本身无有效坐标时才允许缺少交通段，同时加入 diagnostics warning。
- 将路线错误原因写入 `GenerationDiagnostics`，不能再以 `try?` 静默吞掉。

验收：任意 N 个有效坐标的 POI 必须生成 N-1 个交通段；模拟高德 route 全部失败时，时间线仍连续且每段明确标为估算。

### 1.2 地图选择状态单一来源

涉及：`RootView`、`RouteTimelineView`、`MapInspector`。

- 统一由一个 selection state 表达当前 day、item 与 map focus，避免 `selectedItemID` 和 `mapFocus` 各自漂移。
- 点击时间线 POI 后，地图中心、选中标记、底部详情必须指向同一 POI。
- 切换行程、日期、替换或删除 POI 时，主动清理失效 selection。

验收：连续选择三个相距较远的 POI，每次地图中心、标记和详情一致；切换行程后不保留上一个城市的焦点。

## Phase 2 — P1 推荐相关性与信息层级

### 2.1 住宿地理范围收敛

涉及：`ItineraryEngine.lodgingShortlist`、候选模型与测试。

- 以最终路线点位的几何中位点优先作为住宿锚点，路线尚未生成时回退城市中心。
- 默认过滤距锚点超过 25–30 km 的住宿；用户点名或明确选择远郊区域时豁免。
- 排序权重调整为：距离可达性 > 住宿类型匹配 > 评分 > 预算。
- 住宿作为每天首尾锚点前，先验证其不会显著拉长全程交通。

验收：苏州市区行程默认不出现张家港、昆山住宿；候选至少 3 个时优先覆盖不同价格层。

### 2.2 路线与备选推荐分层

涉及：`RouteTimelineView`、`OptionListRows`。

- 主路线保持首屏优先。
- 附近美食和住宿默认各展示 Top 3，其余折叠为“查看更多”。
- 明确标注“路线内停留”和“备选推荐”，避免用户误以为所有卡片都已排程。
- 推荐卡补充“距当天路线最近点 X km / X 分钟”。

验收：打开任意行程时，用户无需滚动即可识别当天主路线；展开推荐不会改变当前地图选择。

## Phase 3 — P1 密钥验证与可观测性

### 3.1 API 连接测试

涉及：`KeychainStore`、`APIKeySettingsViewModel`、`SettingsView`。

- Keychain `set/delete` 返回或抛出明确状态，不再忽略 `OSStatus`。
- 分别提供“测试高德连接”“测试 DeepSeek 连接”，使用最小请求验证鉴权。
- 显示最近成功验证时间；区分“已保存”“已验证”“验证失败”。
- 错误信息不得包含 key、Authorization header 或完整响应体中的敏感字段。

验收：无效 key、配额耗尽、网络离线和 Keychain 写入失败均显示不同、可恢复的提示。

### 3.2 生成诊断

涉及：`GenerationDiagnostics`、`UsageStore`、开发诊断界面。

- 记录召回数、缓存命中率、候选裁剪数、真实路线成功/失败/估算数、最终删点原因。
- 记录各阶段耗时、DeepSeek input/output token 与估算费用。
- Debug 构建提供可复制的脱敏诊断摘要；Release 只展示用户可理解的状态。

验收：一次完整生成后能解释“为什么只留下这些点”“哪些交通是估算”“本次用了多少调用与 token”。

## Phase 4 — P2 生成体验与无障碍

### 4.1 生成前后可预期

- 新建页显示预计耗时和大致调用量，默认天数从 5 天评估是否调整为 3 天或记忆上次选择。
- 失败后保留完整表单，提供“重试失败阶段”，避免重新召回已缓存 POI。
- 生成结果显示质量摘要，例如“3 个路线点、2 段真实交通、0 段估算”。

### 4.2 键盘与辅助功能

- 兴趣、菜系、住宿类型使用带 selected 状态的 Button/Toggle 语义，而非分离的图片与文字。
- 所有图标按钮使用自然语言 accessibility label；检查工具栏、编辑、替换和删除流程。
- 完成 macOS 全键盘遍历、VoiceOver 实听、深色模式、小窗口和 iOS 动态字体检查。
- 修正浅灰辅助文本对比度和过小的 24 px 图标操作目标。

## 建议执行批次

1. 批次 A：1.1 + 1.2，先建立路线可信度回归测试。
2. 批次 B：2.1 + 2.2，解决远郊推荐与信息过载。
3. 批次 C：3.1 + 3.2，让真实用户和开发者都能解释失败。
4. 批次 D：4.1 + 4.2，完成体验与无障碍收尾。

每个批次均要求：核心包单测、App 目标测试、macOS Debug/Release 构建、iOS Simulator 构建，以及对应的实际界面回归。
