# 行迹 Trailhead — SwiftUI 实现（设计稿落地）

由 Claude Design handoff(`Trailhead.dc.html`)转译为 **SwiftUI**,按 PDR 分层组织。
设计语言、配色、间距、「路线时间线」signature 均像素级对照 mockup,**支持系统浅色/深色自动切换**(对应设计稿每个界面的两套变体)。

> ⚠️ 本工程在无 macOS/Xcode 的环境中手写生成,**未经过编译**。代码面向 **iOS 17 / macOS 14 (SwiftUI + SwiftData)**。首次在 Xcode 打开后若有个别 API 报错,多为版本差异,按提示微调即可。

---

## 一、如何在 Xcode 打开

### 方式 A:XcodeGen(推荐,一条命令)
已安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`):
```bash
cd Trailhead
xcodegen generate
open Trailhead.xcodeproj
```

### 方式 B:手动新建工程
1. Xcode → File → New → Project → **Multiplatform → App**,命名 `Trailhead`,Interface 选 SwiftUI,Storage 选 **SwiftData**。
2. 删除模板生成的 `TrailheadApp.swift`、`ContentView.swift`、`Item.swift`。
3. 把本目录下的 `Trailhead/` 子文件夹整个拖进工程(勾选 "Copy items if needed"、"Create groups")。
4. Target 的 Deployment 设为 iOS 17 / macOS 14。
5. ⌘R 运行。首次启动会自动播种「关西环游」示例,界面即还原设计稿。

---

## 二、目录结构与 PDR 任务映射

```
Trailhead/
├─ App/TrailheadApp.swift          @main + ModelContainer + 首启动播种   [T0.1 T0.3]
├─ DesignSystem/Theme.swift        从 HTML 提取的颜色/字体/间距 token      [设计系统]
├─ Models/
│  ├─ Models.swift                 SwiftData 实体 + 枚举 + 类型→色映射     [T1.1]
│  └─ SampleData.swift             关西环游 5 天示例(Day1 与设计稿一致)
├─ Services/Services.swift         Keychain(真实)+ Amap/LLM/Engine 协议桩 [T1.3 T2 T3 骨架]
└─ Features/
   ├─ Root/RootView.swift          macOS 三栏 / iOS Tab 自适应             [T4.1 T4.2]
   ├─ Sidebar/TripSidebar.swift    行程库(分组+渐变图标+选中态)          [T4.3]
   ├─ Timeline/
   │  ├─ TimelineComponents.swift  脊线 gutter + POI 卡片 + 交通段(signature)[T5.1]
   │  ├─ RouteTimelineView.swift   天数切换 + 当天节点流                   [T5.1 T5.2]
   │  └─ MapInspector.swift        MapKit 地图 + POI 详情卡                [T5.5 T5.6]
   ├─ NewTrip/NewTripView.swift    新建行程表单                           [T5.3]
   ├─ Generating/GeneratingView.swift 生成中(进度环+分步)               [T5.4]
   └─ Settings/SettingsView.swift  API/用量/缓存                          [T7.1 T7.2 T7.3 UI]
```

## 三、已实现 vs 待接入

**已实现(可运行、可交互的设计还原)**
- 五个界面全部转 SwiftUI,浅/深色自动适配
- 路线时间线 signature:绿色脊线、节点(选中蓝环/类型色)、交通段、住宿虚线段
- 侧栏选行程、时间线选天、点 POI 联动地图与详情卡
- 新建表单的标签多选、节奏、预算交互
- SwiftData 持久化 + 首启动播种;Keychain 读写为真实实现

**待接入(下一阶段,见 PDR 续写)**
- `AmapClient`:地理编码 / POI 搜索 / 路径规划(PDR T2)
- `ItineraryEngine` 真实流水线 + `FactChecker`(PDR T3)
- 把 `GeneratingView` 的分步绑定到 `ItineraryEngine.Stage`
- 编辑/重排/替换(PDR 阶段 6)

> 架构已留好缝:`POIDataSource` / `LLMProvider` 是协议,目前注入 `Stub*`;真实 client 实现后替换注入即可,**视图层零改动**。

## 四、一处设计↔架构的差异提示

设计稿 Settings 里写的服务商是「Anthropic · Claude / Sonnet 4.5」。PDR 的数据架构是 **高德(POI/路线)+ 可替换 LLM(DeepSeek/通义/Kimi/Claude 均可)**。`SettingsView` 已按 mockup 还原文案,实际接入时把服务商/模型改成你最终选的即可;`LLMProvider` 协议保证随时可换。
