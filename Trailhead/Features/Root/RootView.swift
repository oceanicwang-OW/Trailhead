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
    @StateObject private var mapSelection = MapSelectionStore()
    @State private var showNewTrip = false
    @State private var tripDraft: NewTripDraft

    // 生成流程状态
    @State private var generating = false
    @State private var genCity = ""
    @State private var genDays = 0
    @State private var genError: String?
    @State private var genTask: Task<Void, Never>?
    @State private var lastGenerationRequest: GenerationRequest?
    @State private var quotaBanner = false
    @State private var tripPendingDelete: Trip?

    init(container: ModelContainer) {
        // Release 仅从 Keychain 取 key；DEBUG 额外支持环境变量和本地开发配置文件。
        _engine = StateObject(wrappedValue: ItineraryEngine(
            source: AmapClient.live(), llm: DeepSeekClient.live(), context: container.mainContext))
        _tripDraft = State(initialValue: NewTripDraft(days: NewTripDraft.rememberedDays()))
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if quotaBanner { quotaBannerView }
            }
            .sheet(isPresented: $generating) { generatingSheet }
            .alert("生成失败", isPresented: errorBinding) {
                Button("重试生成") { retryGeneration() }
                Button("返回表单", role: .cancel) { returnToDraft() }
            } message: {
                Text(genError ?? "请稍后重试。")
            }
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
                .accessibilityLabel("关闭配额提示")
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
                                      selectionStore: mapSelection)
                        .navigationTitle(trip.city)
                        .navigationSubtitle(trip.subtitle)
                } else { emptyState }
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: Metric.timelineWidth, max: 520)
            .toolbar {
                ToolbarItem {
                    Button { showNewTrip = true } label: { Image(systemName: "plus") }
                        .help("新建行程")
                        .accessibilityLabel("新建行程")
                }
                ToolbarItem {
                    SettingsLink {
                        Image(systemName: "gearshape")
                    }
                    .help("设置")
                    .accessibilityLabel("设置")
                }
            }
        } detail: {
            if let trip = current {
                MapInspector(trip: trip, dayIndex: dayIndex,
                             selectionStore: mapSelection)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380)
            } else { Color(Palette.canvasBG) }
        }
        .sheet(isPresented: $showNewTrip) {
            NewTripView(draft: $tripDraft, onGenerate: startGeneration)
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
                                          selectionStore: mapSelection,
                                          gutter: Metric.gutterCompact)
                            .navigationTitle("\(trip.city) · D\(dayIndex + 1)")
                            .navigationBarTitleDisplayMode(.inline)
                    } else { emptyState }
                }
            }
            .tabItem { Label("行程", systemImage: "list.bullet.indent") }

            NavigationStack {
                NewTripView(draft: $tripDraft, onGenerate: startGeneration)
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

    private struct GenerationRequest {
        let draft: NewTripDraft
    }

    private func startGeneration(_ draft: NewTripDraft) {
        draft.rememberDays()
        let request = GenerationRequest(draft: draft)
        lastGenerationRequest = request
        runGeneration(request)
    }

    private func runGeneration(_ request: GenerationRequest) {
        showNewTrip = false
        genCity = request.draft.trimmedDestination
        genDays = request.draft.days
        genError = nil
        generating = true
        genTask = Task {
            do {
                let trip = try await engine.generate(destination: request.draft.trimmedDestination,
                                                      prefs: request.draft.preferences,
                                                      days: request.draft.days,
                                                      startDate: request.draft.startDate)
                guard !Task.isCancelled else { return }
                QuotaState().clear()
                quotaBanner = false
                selection = trip
                dayIndex = 0
                mapSelection.selection = nil
                generating = false
            } catch {
                guard !Task.isCancelled else { return }
                generating = false
                if case AmapError.quotaExceeded = error {
                    QuotaState().markExhausted()      // 降级：标记 + 持久横幅，行程仍可浏览
                    quotaBanner = true
                } else {
                    genError = Self.failureMessage(error, stage: engine.stage)
                }
            }
        }
    }

    private func retryGeneration() {
        genError = nil
        guard let lastGenerationRequest else {
            returnToDraft()
            return
        }
        runGeneration(lastGenerationRequest)
    }

    private func returnToDraft() {
        genError = nil
        generating = false
        #if os(macOS)
        showNewTrip = true
        #endif
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

    static func failureMessage(_ error: Error, stage: ItineraryEngine.Stage) -> String {
        let stageText: String
        switch stage {
        case .analyzing: stageText = "分析偏好"
        case .routing: stageText = "规划路线"
        case .dining: stageText = "匹配餐饮与住宿"
        case .transit: stageText = "校准交通"
        case .budgeting: stageText = "估算预算"
        case .done: stageText = "保存结果"
        }
        return "\(friendlyMessage(error))\n失败阶段：\(stageText)。重试会优先复用已缓存地点。"
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
        if wasSelected { selection = nil; dayIndex = 0; mapSelection.selection = nil }
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
        Binding(get: { current }, set: { selection = $0; dayIndex = 0; mapSelection.selection = nil })
    }
}
