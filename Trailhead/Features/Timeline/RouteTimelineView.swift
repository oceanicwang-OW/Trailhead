//  RouteTimelineView.swift
//  Center column of the macOS main screen (and the iOS trip page body):
//  a day header, day-tabs, and the scrolling route timeline for the selected day.

import SwiftData
import SwiftUI
import TrailheadCore

struct RouteQualitySummary: Equatable {
    let routePoints: Int
    let verifiedTransitSegments: Int
    let estimatedTransitSegments: Int

    init(trip: Trip) {
        let items = trip.sortedDays.flatMap(\.sortedItems)
        routePoints = items.filter { $0.kind != .transit }.count
        let transit = items.filter { $0.kind == .transit }
        estimatedTransitSegments = transit.filter { $0.transitReliability == .estimated }.count
        verifiedTransitSegments = transit.count - estimatedTransitSegments
    }

    var text: String {
        "\(routePoints) 个路线点 · \(verifiedTransitSegments) 段真实交通 · \(estimatedTransitSegments) 段估算"
    }
}

struct RouteTimelineView: View {
    let trip: Trip
    @Binding var selectedDayIndex: Int
    @ObservedObject var selectionStore: MapSelectionStore
    var gutter: CGFloat = Metric.gutter
    var showDayTabs: Bool = true
    var onAdjustRequirements: ((TripIntent) -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) var openURL   // OptionListRows 扩展（另文件）也要用
    @State private var isEditing = false
    @State private var draftPOIIDs: [UUID] = []
    @State private var editError: String?
    @State private var deletingItemID: UUID?
    @State private var replacingItem: PlanItem?
    @State private var replacementCandidates: [POICandidate] = []
    @State private var replacementLoading = false
    @State private var replacementError: String?
    @State private var applyingReplacementItemID: UUID?
    @State private var regeneratingDayID: UUID?
    @State var showAllFoodOptions = false
    @State var showAllOptionalVisits = false
    @State var showAllLodgingOptions = false
    @State var intentSummaryPresentation: IntentSummaryPresentation?

    private var day: DayPlan? {
        trip.sortedDays.first { $0.dayIndex == selectedDayIndex } ?? trip.sortedDays.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                qualitySummary
                if let intent = trip.planningIntent { planningRequirementButton(intent) }
                if showDayTabs { dayTabs.padding(.horizontal, 18).padding(.bottom, 6) }
                if let day {
                    routeSectionLabel
                    timeline(for: day)
                    optionalVisitSection(for: day)
                    foodSection(for: day)
                }
                lodgingSection
            }
            .padding(.bottom, 28)
        }
        .background(Palette.canvasBG)
        .scrollIndicators(.hidden)
        .alert("保存失败", isPresented: editErrorPresented) {
            Button("好", role: .cancel) { editError = nil }
        } message: {
            Text(editError ?? "请稍后重试")
        }
        .sheet(isPresented: replacementPresented) {
            if let replacingItem {
                replacementSheet(for: replacingItem)
            }
        }
        .sheet(item: $intentSummaryPresentation) { presentation in
            TripIntentSummarySheet(intent: presentation.intent,
                                   onAdjust: onAdjustRequirements)
        }
        .onChange(of: trip.id) {
            showAllFoodOptions = false
            showAllOptionalVisits = false
            showAllLodgingOptions = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("Day \(selectedDayIndex + 1)")
                    .font(Typo.display(19, .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text(daySubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                if let day {
                    regenerateDayButton(day)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
    }

    private var daySubtitle: String {
        guard let day else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEE · M/d"
        var parts = ["\(f.string(from: day.date)) · \(day.cityLabel)"]
        if !day.theme.isEmpty { parts.append(day.theme) }   // P7 当天主题（未生成则不显示）
        return parts.joined(separator: " · ")
    }

    private var qualitySummary: some View {
        let summary = RouteQualitySummary(trip: trip)
        return HStack(spacing: 7) {
            Image(systemName: summary.estimatedTransitSegments == 0
                  ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(summary.estimatedTransitSegments == 0 ? Palette.green : Palette.orange)
            Text(summary.text)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("行程质量摘要，\(summary.text)")
    }

    private var dayTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(trip.sortedDays, id: \.id) { d in
                    let on = d.dayIndex == selectedDayIndex
                    Button {
                        selectDay(d.dayIndex)
                    } label: {
                        Text("D\(d.dayIndex + 1)")
                            .font(.system(size: 13, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? .white : Palette.textMuted)
                            .frame(width: 46, height: 30)
                            .background(on ? Palette.green : Palette.fieldBG,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                if isEditing {
                    editControls
                } else {
                    editButton
                }
            }
        }
    }

    private var editButton: some View {
        Button {
            if let day { startEditing(day) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                Text("编辑").font(.system(size: 12.5))
            }
            .foregroundStyle(Palette.textMuted)
            .frame(height: 30).padding(.horizontal, 12)
            .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(regeneratingDayID != nil)
    }

    private func regenerateDayButton(_ day: DayPlan) -> some View {
        let isRegenerating = regeneratingDayID == day.id
        return Button {
            regenerateDay(day)
        } label: {
            Group {
                if isRegenerating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .frame(width: 30, height: 30)
            .foregroundStyle(Palette.green)
            .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isEditing || deletingItemID != nil || applyingReplacementItemID != nil || regeneratingDayID != nil)
        .help("重生成当天")
        .accessibilityLabel("重生成当天")
    }

    private func timeline(for day: DayPlan) -> some View {
        VStack(spacing: 0) {
            ForEach(timelineItems(for: day), id: \.id) { item in
                if item.kind == .transit {
                    TransportRow(item: item, gutter: gutter)
                        .opacity(isEditing ? 0.72 : 1)
                } else {
                    editablePOIRow(item, day: day)
                }
            }
        }
        .padding(.top, 4)
    }

    private var routeSectionLabel: some View {
        Label("路线内停留 · 已排程", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.green)
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .accessibilityLabel("路线内停留，以下地点已经排入当天行程")
    }

    private var editControls: some View {
        HStack(spacing: 6) {
            editControlButton(systemName: "xmark", accessibilityLabel: "取消编辑", tint: Palette.textMuted) {
                cancelEditing()
            }
            .help("取消")

            editControlButton(systemName: "checkmark", accessibilityLabel: "保存编辑",
                              tint: .white, background: Palette.green) {
                if let day { saveEditing(day) }
            }
            .help("保存")
        }
        .disabled(regeneratingDayID != nil)
    }

    private func editablePOIRow(_ item: PlanItem, day: DayPlan) -> some View {
        POICard(item: item,
                selected: selectionStore.selection?.itineraryID == item.id,
                gutter: gutter)
            .contentShape(Rectangle())
            .onTapGesture { selectionStore.selection = .itinerary(item.id) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("在地图查看路线地点：\(item.name ?? item.kind.label)")
            .accessibilityAction { selectionStore.selection = .itinerary(item.id) }
            .contextMenu {
                if let minimum = item.minimumStayMinutes {
                    Button("快速逛逛 · \(minimum) 分钟", systemImage: "hare") {
                        updateDuration(item, in: day, minutes: minimum)
                    }
                }
                if let comfortable = item.comfortableStayMinutes {
                    Button("舒适游览 · \(comfortable) 分钟", systemImage: "figure.walk") {
                        updateDuration(item, in: day, minutes: comfortable)
                    }
                }
                if let extended = item.extendedStayMinutes {
                    Button("深度体验 · \(extended) 分钟", systemImage: "binoculars") {
                        updateDuration(item, in: day, minutes: extended)
                    }
                }
                Divider()
                if item.visitStatus != .visiting {
                    Button("开始游玩", systemImage: "play.fill") { updateVisit(item, status: .visiting) }
                }
                if item.visitStatus != .completed {
                    Button("完成游玩", systemImage: "checkmark.circle") { updateVisit(item, status: .completed) }
                }
                Button("跳过这个地点", systemImage: "forward.end") { updateVisit(item, status: .skipped) }
                if item.visitStatus != .planned {
                    Button("恢复为未开始", systemImage: "arrow.uturn.backward") { updateVisit(item, status: .planned) }
                }
            }
            .overlay(alignment: .topTrailing) {
                if isEditing {
                    moveControls(for: item, day: day)
                        .padding(.top, 8)
                        .padding(.trailing, 22)
                }
            }
    }

    private func updateVisit(_ item: PlanItem, status: VisitExecutionStatus) {
        do {
            try TripRepository(context: modelContext).updateVisitStatus(item, status: status)
        } catch {
            editError = error.localizedDescription
        }
    }

    private func updateDuration(_ item: PlanItem, in day: DayPlan, minutes: Int) {
        do {
            try TripRepository(context: modelContext).updateVisitDuration(item, in: day, minutes: minutes)
        } catch {
            editError = error.localizedDescription
        }
    }

    private func moveControls(for item: PlanItem, day: DayPlan) -> some View {
        let index = poiIndex(for: item, day: day)
        return HStack(spacing: 4) {
            moveButton(systemName: "chevron.up", accessibilityLabel: "上移地点",
                       disabled: index == nil || index == 0) {
                movePOI(item.id, offset: -1, day: day)
            }
            .help("上移")

            moveButton(systemName: "chevron.down", accessibilityLabel: "下移地点",
                       disabled: index == nil || index == poiIDs(for: day).count - 1) {
                movePOI(item.id, offset: 1, day: day)
            }
            .help("下移")

            moveButton(systemName: applyingReplacementItemID == item.id ? "hourglass" : "arrow.triangle.2.circlepath",
                       accessibilityLabel: "替换地点",
                       tint: Palette.green,
                       disabled: deletingItemID != nil
                           || applyingReplacementItemID != nil
                           || regeneratingDayID != nil) {
                openReplacement(for: item, day: day)
            }
            .help("替换")

            moveButton(systemName: deletingItemID == item.id ? "hourglass" : "trash",
                       accessibilityLabel: "删除地点",
                       tint: .red,
                       disabled: deletingItemID != nil
                           || applyingReplacementItemID != nil
                           || regeneratingDayID != nil) {
                deletePOI(item, day: day)
            }
            .help("删除")
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func editControlButton(systemName: String,
                                   accessibilityLabel: String,
                                   tint: Color,
                                   background: Color = Palette.fieldBG,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 30)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func moveButton(systemName: String,
                            accessibilityLabel: String,
                            tint: Color = Palette.green,
                            disabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(disabled ? Palette.textMuted.opacity(0.35) : tint)
                .frame(width: Metric.minimumControlTarget, height: Metric.minimumControlTarget)
                .background(Palette.canvasBG.opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var editErrorPresented: Binding<Bool> {
        Binding(
            get: { editError != nil },
            set: { if !$0 { editError = nil } }
        )
    }

    private var replacementPresented: Binding<Bool> {
        Binding(
            get: { replacingItem != nil },
            set: { if !$0 { replacingItem = nil } }
        )
    }

    private func replacementSheet(for item: PlanItem) -> some View {
        ReplacementCandidateSheet(candidates: replacementCandidates,
                                  loading: replacementLoading,
                                  error: replacementError,
                                  applyingReplacementItemID: applyingReplacementItemID) {
            replacingItem = nil
        } onRetry: {
            if let day { loadReplacementCandidates(for: item, day: day) }
        } onApply: { candidate in
            if let day { applyReplacement(candidate, for: item, day: day) }
        }
    }

    private func selectDay(_ dayIndex: Int) {
        if isEditing {
            cancelEditing()
        }
        withAnimation(.snappy) {
            selectedDayIndex = dayIndex
            showAllFoodOptions = false
        }
    }

    private func startEditing(_ day: DayPlan) {
        guard regeneratingDayID == nil else { return }
        draftPOIIDs = day.sortedItems.filter { $0.kind != .transit }.map(\.id)
        isEditing = true
    }

    private func cancelEditing() {
        isEditing = false
        draftPOIIDs = []
    }

    private func saveEditing(_ day: DayPlan) {
        guard regeneratingDayID == nil else { return }
        do {
            try TripRepository(context: modelContext).reorderPOIs(day, orderedPOIIDs: poiIDs(for: day))
            cancelEditing()
        } catch {
            editError = error.localizedDescription
        }
    }

    private func timelineItems(for day: DayPlan) -> [PlanItem] {
        guard isEditing else { return day.sortedItems }
        let sortedItems = day.sortedItems
        let poiByID = Dictionary(uniqueKeysWithValues:
            sortedItems.filter { $0.kind != .transit }.map { ($0.id, $0) })
        var orderedPOIs = poiIDs(for: day).compactMap { poiByID[$0] }
        let knownIDs = Set(orderedPOIs.map(\.id))
        orderedPOIs.append(contentsOf: sortedItems.filter { $0.kind != .transit && !knownIDs.contains($0.id) })

        var poiIndex = 0
        return sortedItems.compactMap { item in
            if item.kind == .transit {
                return item
            }
            guard poiIndex < orderedPOIs.count else { return nil }
            defer { poiIndex += 1 }
            return orderedPOIs[poiIndex]
        }
    }

    private func poiIDs(for day: DayPlan) -> [UUID] {
        draftPOIIDs.isEmpty ? day.sortedItems.filter { $0.kind != .transit }.map(\.id) : draftPOIIDs
    }

    private func poiIndex(for item: PlanItem, day: DayPlan) -> Int? {
        poiIDs(for: day).firstIndex(of: item.id)
    }

    private func movePOI(_ id: UUID, offset: Int, day: DayPlan) {
        var ids = poiIDs(for: day)
        guard let current = ids.firstIndex(of: id) else { return }
        let target = current + offset
        guard ids.indices.contains(target) else { return }
        ids.swapAt(current, target)
        withAnimation(.snappy) {
            draftPOIIDs = ids
        }
    }

    private func openReplacement(for item: PlanItem, day: DayPlan) {
        guard regeneratingDayID == nil else { return }
        replacingItem = item
        loadReplacementCandidates(for: item, day: day)
    }

    private func loadReplacementCandidates(for item: PlanItem, day: DayPlan) {
        replacementLoading = true
        replacementError = nil
        replacementCandidates = []
        Task { @MainActor in
            do {
                let adcode = trip.adcode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !adcode.isEmpty else {
                    replacementError = "当前行程缺少城市编码，无法召回候选"
                    replacementLoading = false
                    return
                }
                let recall = POIRecall(source: AmapClient.live(), cache: POICache(context: modelContext))
                let existingPOIIDs = Set(day.sortedItems.compactMap(\.poiId))
                let tags = replacementTags(for: item)
                replacementCandidates = try await recall.recall(adcode: adcode, tags: tags)
                    .filter { !existingPOIIDs.contains($0.id) }
                replacementLoading = false
            } catch {
                replacementError = error.localizedDescription
                replacementLoading = false
            }
        }
    }
}

private extension RouteTimelineView {
    private func replacementTags(for item: PlanItem) -> [String] {
        switch item.kind {
        case .sight:
            if let subtype = item.subtype, !subtype.isEmpty { return [subtype] }
            return ["景点"]
        case .food:
            return ["美食"]
        case .lodging:
            return ["住宿"]
        case .transit:
            return ["景点"]
        }
    }

    private func applyReplacement(_ candidate: POICandidate, for item: PlanItem, day: DayPlan) {
        guard applyingReplacementItemID == nil, regeneratingDayID == nil else { return }
        let currentIDs = poiIDs(for: day)
        applyingReplacementItemID = item.id
        Task { @MainActor in
            do {
                let repo = TripRepository(context: modelContext)
                try repo.reorderPOIs(day, orderedPOIIDs: currentIDs)
                try await repo.replacePOI(item, with: candidate, in: day, routeUsing: AmapClient.live(), adcode: trip.adcode)
                draftPOIIDs = currentIDs
                selectionStore.selection = .itinerary(item.id)
                replacingItem = nil
                applyingReplacementItemID = nil
            } catch {
                editError = error.localizedDescription
                applyingReplacementItemID = nil
            }
        }
    }

    private func deletePOI(_ item: PlanItem, day: DayPlan) {
        guard deletingItemID == nil, regeneratingDayID == nil else { return }
        let currentIDs = poiIDs(for: day)
        deletingItemID = item.id
        Task { @MainActor in
            do {
                let repo = TripRepository(context: modelContext)
                try repo.reorderPOIs(day, orderedPOIIDs: currentIDs)
                try await repo.deletePOI(item, from: day, routeUsing: AmapClient.live(), adcode: trip.adcode)
                draftPOIIDs = currentIDs.filter { $0 != item.id }
                if selectionStore.selection?.itineraryID == item.id {
                    selectionStore.selection = draftPOIIDs.first.map(MapSelection.itinerary)
                }
                deletingItemID = nil
            } catch {
                editError = error.localizedDescription
                deletingItemID = nil
            }
        }
    }

    private func regenerateDay(_ day: DayPlan) {
        guard regeneratingDayID == nil else { return }
        cancelEditing()
        replacingItem = nil
        regeneratingDayID = day.id
        Task { @MainActor in
            do {
                try await TripRepository(context: modelContext).regenerateDay(day, in: trip,
                                                                              source: AmapClient.live(),
                                                                              llm: DeepSeekClient.live())
                selectionStore.selection = day.sortedItems.first { $0.kind != .transit }.map { .itinerary($0.id) }
                regeneratingDayID = nil
            } catch {
                editError = error.localizedDescription
                regeneratingDayID = nil
            }
        }
    }
}
