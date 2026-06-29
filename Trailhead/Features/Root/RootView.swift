//  RootView.swift
//  Adaptive shell: NavigationSplitView (three columns) on macOS,
//  TabView + NavigationStack on iOS — matching the two device mockups.
//  Owns the ItineraryEngine and drives 新建 → 生成中 → 选中新行程 的流程。

import SwiftData
import SwiftUI
import TrailheadCore

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Trip.createdAt, order: .reverse) private var trips: [Trip]

    @StateObject private var engine: ItineraryEngine

    @State private var selection: Trip?
    @State private var dayIndex = 0
    @State private var selectedItemID: UUID?
    @State private var mapFocus: MapFocus?
    @State private var showNewTrip = false

    // 生成流程状态
    @State private var generating = false
    @State private var genCity = ""
    @State private var genDays = 0
    @State private var genError: String?
    @State private var genTask: Task<Void, Never>?
    @State private var quotaBanner = false
    @State private var tripPendingDelete: Trip?

    init(container: ModelContainer) {
        // key 解析：环境变量 → ~/.config/trailhead/secrets.json → Keychain（不弹授权框）
        _engine = StateObject(wrappedValue: ItineraryEngine(
            source: AmapClient.live(), llm: DeepSeekClient.live(), context: container.mainContext))
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if quotaBanner { quotaBannerView }
            }
            .sheet(isPresented: $generating) { generatingSheet }
            .alert("生成失败", isPresented: errorBinding, presenting: genError) { _ in
                Button("好") { genError = nil; generating = false }
            } message: { Text($0) }
            .confirmationDialog("删除这个行程？", isPresented: deletePresented, presenting: tripPendingDelete) { trip in
                Button("删除「\(trip.city)」", role: .destructive) { performDelete(trip) }
                Button("取消", role: .cancel) { tripPendingDelete = nil }
            } message: { _ in Text("删除后无法恢复。") }
            .onAppear { quotaBanner = QuotaState().isExhausted() }
    }

    /// 配额耗尽降级横幅（PDR T8.2 / §7 错误文案）。
    private var quotaBannerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("高德今日额度已用完，明日恢复；当前展示已缓存行程").font(Typo.caption)
            Spacer()
            Button { quotaBanner = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Palette.red)
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        macOS
        #else
        iOS
        #endif
    }

    /// 默认选中第一个有内容的行程（避免开屏停在空草稿上）。
    private var current: Trip? { selection ?? trips.first { !$0.days.isEmpty } ?? trips.first }

    // MARK: macOS — three columns

    #if os(macOS)
    private var macOS: some View {
        NavigationSplitView {
            TripSidebar(trips: trips, selection: bindingSelection,
                        onNewTrip: { showNewTrip = true },
                        onDelete: { tripPendingDelete = $0 })
                .navigationSplitViewColumnWidth(min: 240, ideal: Metric.sidebarWidth, max: 300)
        } content: {
            Group {
                if let trip = current {
                    RouteTimelineView(trip: trip,
                                      selectedDayIndex: $dayIndex,
                                      selectedItemID: $selectedItemID,
                                      mapFocus: $mapFocus)
                        .navigationTitle(trip.city)
                        .navigationSubtitle(trip.subtitle)
                } else { emptyState }
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: Metric.timelineWidth, max: 520)
            .toolbar {
                ToolbarItem { Button { showNewTrip = true } label: { Image(systemName: "plus") } }
            }
        } detail: {
            if let trip = current {
                MapInspector(trip: trip, dayIndex: dayIndex,
                             selectedItemID: $selectedItemID, mapFocus: $mapFocus)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380)
            } else { Color(Palette.canvasBG) }
        }
        .sheet(isPresented: $showNewTrip) {
            NewTripView { prefs, dest, days, start in startGeneration(prefs, dest, days, start) }
        }
    }
    #endif

    // MARK: iOS — tabs

    #if os(iOS)
    private var iOS: some View {
        TabView {
            NavigationStack {
                Group {
                    if let trip = current {
                        RouteTimelineView(trip: trip,
                                          selectedDayIndex: $dayIndex,
                                          selectedItemID: $selectedItemID,
                                          mapFocus: $mapFocus,
                                          gutter: Metric.gutterCompact)
                            .navigationTitle("\(trip.city) · D\(dayIndex + 1)")
                            .navigationBarTitleDisplayMode(.inline)
                    } else { emptyState }
                }
            }
            .tabItem { Label("行程", systemImage: "list.bullet.indent") }

            NavigationStack {
                NewTripView { prefs, dest, days, start in startGeneration(prefs, dest, days, start) }
            }
            .tabItem { Label("新建", systemImage: "plus.circle") }

            NavigationStack { SettingsView().navigationTitle("设置") }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(Palette.green)
    }
    #endif

    // MARK: 生成中

    private var generatingSheet: some View {
        GeneratingView(
            city: genCity,
            progress: engine.progress,
            plannedDays: Int((engine.progress * Double(genDays)).rounded()),
            totalDays: genDays,
            steps: genSteps(engine.stage),
            onCancel: { genTask?.cancel(); generating = false }
        )
        .frame(minWidth: 460, minHeight: 640)
    }

    private func startGeneration(_ prefs: TripPrefs, _ destination: String, _ days: Int, _ startDate: Date) {
        showNewTrip = false
        genCity = destination
        genDays = days
        genError = nil
        generating = true
        genTask = Task {
            do {
                let trip = try await engine.generate(destination: destination, prefs: prefs,
                                                      days: days, startDate: startDate)
                guard !Task.isCancelled else { return }
                QuotaState().clear()
                quotaBanner = false
                selection = trip
                dayIndex = 0
                selectedItemID = nil
                generating = false
            } catch {
                guard !Task.isCancelled else { return }
                generating = false
                if case AmapError.quotaExceeded = error {
                    QuotaState().markExhausted()      // 降级：标记 + 持久横幅，行程仍可浏览
                    quotaBanner = true
                } else {
                    genError = Self.friendlyMessage(error)
                }
            }
        }
    }

    /// ItineraryEngine.Stage → 分步状态（PDR T3.7 / 设计稿 FRAME 7）。
    private func genSteps(_ stage: ItineraryEngine.Stage) -> [GeneratingView.Step] {
        let order: [(ItineraryEngine.Stage, String)] = [
            (.analyzing, "分析兴趣偏好"),
            (.routing, "规划每日路线"),
            (.dining, "匹配餐饮与住宿"),
            (.transit, "优化交通衔接"),
            (.budgeting, "估算每日预算"),
        ]
        let rank: [ItineraryEngine.Stage: Int] = [
            .analyzing: 0, .routing: 1, .dining: 2, .transit: 3, .budgeting: 4, .done: 5,
        ]
        let current = rank[stage] ?? 0
        return order.map { stage, title in
            let r = rank[stage]!
            let state: GeneratingView.Step.State = r < current ? .done : (r == current ? .active : .pending)
            return GeneratingView.Step(title: title, state: state)
        }
    }

    static func friendlyMessage(_ error: Error) -> String {
        switch error {
        case AmapError.missingKey, LLMError.missingKey:
            return "还没配置 API Key。请到「设置」填写 高德 Web 服务 Key 与 DeepSeek Key。"
        case AmapError.quotaExceeded:
            return "高德今日配额已用完，明日恢复；可稍后再试。"
        case ItineraryEngine.EngineError.noCandidates:
            return "没找到候选地点，换个目的地或调整兴趣偏好再试试。"
        case ItineraryEngine.EngineError.emptyPlan:
            return "生成的行程为空，请重试或调整偏好。"
        default:
            return (error as? LocalizedError)?.errorDescription ?? "生成失败：\(error)"
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { genError != nil }, set: { if !$0 { genError = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { tripPendingDelete != nil }, set: { if !$0 { tripPendingDelete = nil } })
    }

    /// 删除行程；若删的是当前选中项，清空选中让列表回落到下一条。
    private func performDelete(_ trip: Trip) {
        let wasSelected = current?.id == trip.id
        try? TripRepository(context: context).delete(trip)
        if wasSelected { selection = nil; dayIndex = 0; selectedItemID = nil }
        tripPendingDelete = nil
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "map").font(.system(size: 40)).foregroundStyle(Palette.textTertiary)
            Text("还没有行程").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.textPrimary)
            Text("从上方新建一个，自动生成路线时间线").font(Typo.caption).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvasBG)
    }

    private var bindingSelection: Binding<Trip?> {
        Binding(get: { current }, set: { selection = $0; dayIndex = 0; selectedItemID = nil })
    }
}
