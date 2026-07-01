//  NewTripView.swift
//  The "新建行程" form (FRAME 3/4). Collects destination + preferences and
//  hands off to the itinerary engine.

import SwiftUI
import TrailheadCore

struct NewTripView: View {
    @Environment(\.dismiss) private var dismiss
    var onGenerate: (TripPrefs, String, Int, Date) -> Void = { _, _, _, _ in }

    @State private var destination = "成都"
    @State private var days = 5
    @State private var startDate = Calendar.current.startOfDay(for: .now)
    @State private var selectedTags: Set<String> = ["美食", "历史古迹", "自然风光"]
    @State private var selectedCuisines: Set<String> = []
    @State private var lodgingType = ""        // "" = 不限
    @State private var pace: Pace = .relaxed
    @State private var budget: Double = 600

    private let allTags = ["美食", "历史古迹", "自然风光", "温泉", "购物",
                           "动漫文化", "夜生活", "亲子", "摄影"]
    private let allCuisines = ["本地特色", "海鲜", "火锅", "烧烤", "小吃",
                               "川菜", "粤菜", "湘菜", "日料", "西餐", "素食"]
    private let allLodging = ["民宿", "经济型酒店", "豪华酒店", "青年旅舍", "度假酒店"]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    destinationField
                    HStack(alignment: .top, spacing: 14) { dateField; daysStepper }
                    tagsSection
                    cuisineSection
                    lodgingSection
                    paceSection
                    budgetSection
                }
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)
            }
            footer
        }
        .background(Palette.canvasBG)
        .frame(minWidth: 560, minHeight: 640)
    }

    // MARK: header / footer

    private var header: some View {
        VStack(spacing: 3) {
            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain).foregroundStyle(Palette.blue).font(.system(size: 13.5))
                Spacer()
            }
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Palette.green)
                Text("新建行程").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.textPrimary)
            }
            Text("告诉我们目的地与偏好，自动生成路线时间线")
                .font(Typo.caption).foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
        .overlay(Divider(), alignment: .bottom)
    }

    private var footer: some View {
        let city = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button {
            var p = TripPrefs(); p.tags = Array(selectedTags); p.pace = pace; p.budgetPerDay = Int(budget)
            p.cuisines = Array(selectedCuisines); p.lodgingType = lodgingType
            onGenerate(p, city, days, startDate); dismiss()
        } label: {
            Text("生成行程")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(city.isEmpty ? Palette.textTertiary : Palette.green, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(city.isEmpty)
        .padding(.horizontal, 28).padding(.vertical, 14)
    }

    // MARK: fields

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(Typo.caption2.weight(.semibold)).tracking(0.5)
            .foregroundStyle(Palette.textTertiary)
    }

    private var destinationField: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("目的地")
            HStack(spacing: 11) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(Palette.green)
                TextField("输入城市，如 成都 / 北京 / 西安", text: $destination)
                    .textFieldStyle(.plain)
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .submitLabel(.done)
            }
            .fieldChrome()
            Text("目前覆盖中国大陆城市（高德 POI）").font(Typo.caption2).foregroundStyle(Palette.textTertiary)
        }
    }

    private var dateField: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("出发日期")
            HStack(spacing: 10) {
                Image(systemName: "calendar").foregroundStyle(Palette.textMuted)
                DatePicker("", selection: $startDate, in: Calendar.current.startOfDay(for: .now)...,
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Spacer()
            }
            .fieldChrome()
            Text(returnDateText).font(Typo.caption2).foregroundStyle(Palette.textTertiary)
        }
    }

    private var returnDateText: String {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: max(0, days - 1), to: startDate) ?? startDate
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日"
        return "返程 \(f.string(from: end)) · 共 \(days) 天"
    }

    private var daysStepper: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("天数")
            HStack(spacing: 0) {
                stepButton("minus") { days = max(1, days - 1) }
                Text("\(days) 天").font(Typo.cardTitle).foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity)
                stepButton("plus", tint: true) { days += 1 }
            }
            .padding(5)
            .background(Palette.cardBG, in: RoundedRectangle(cornerRadius: Metric.fieldRadius))
            .overlay(RoundedRectangle(cornerRadius: Metric.fieldRadius).stroke(Palette.cardStroke, lineWidth: 0.5))
        }
    }

    private func stepButton(_ icon: String, tint: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint ? Palette.green : Palette.textPrimary)
                .frame(width: 38, height: 34)
                .background(tint ? Palette.green.opacity(0.12) : Palette.fieldBG,
                            in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("兴趣偏好")
            FlowLayout(spacing: 9) {
                ForEach(allTags, id: \.self) { tag in
                    let on = selectedTags.contains(tag)
                    HStack(spacing: 5) {
                        if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                        Text(tag).font(.system(size: 13, weight: on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? .white : Palette.textPrimary)
                    .padding(.vertical, 8).padding(.horizontal, 13)
                    .background(on ? Palette.green : Palette.fieldBG, in: Capsule())
                    .onTapGesture {
                        if on { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
                    }
                }
            }
        }
    }

    private var cuisineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("口味 / 菜系（影响美食推荐）")
            FlowLayout(spacing: 9) {
                ForEach(allCuisines, id: \.self) { c in
                    chip(c, on: selectedCuisines.contains(c)) {
                        if selectedCuisines.contains(c) { selectedCuisines.remove(c) } else { selectedCuisines.insert(c) }
                    }
                }
            }
        }
    }

    private var lodgingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("住宿类型（影响住宿推荐）")
            FlowLayout(spacing: 9) {
                chip("不限", on: lodgingType.isEmpty) { lodgingType = "" }
                ForEach(allLodging, id: \.self) { t in
                    chip(t, on: lodgingType == t) { lodgingType = (lodgingType == t ? "" : t) }
                }
            }
        }
    }

    /// 统一胶囊选项样式（兴趣偏好/菜系/住宿共用）。
    private func chip(_ text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
            Text(text).font(.system(size: 13, weight: on ? .semibold : .medium))
        }
        .foregroundStyle(on ? .white : Palette.textPrimary)
        .padding(.vertical, 8).padding(.horizontal, 13)
        .background(on ? Palette.green : Palette.fieldBG, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: action)
    }

    private var paceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("行程节奏")
            HStack(spacing: 8) {
                ForEach(Pace.allCases, id: \.self) { p in
                    let on = pace == p
                    Text(p.display).font(.system(size: 12.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Palette.green : Palette.textMuted)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(on ? Palette.green.opacity(0.12) : Palette.fieldBG,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .stroke(on ? Palette.green : .clear, lineWidth: 1))
                        .onTapGesture { pace = p }
                }
            }
        }
    }

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { label("人均预算"); Spacer()
                Text("¥\(Int(budget))/天").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.green) }
            Slider(value: $budget, in: 200...2000, step: 50).tint(Palette.green)
            HStack { Text("经济"); Spacer(); Text("奢华") }
                .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
        }
    }
}

// Field chrome modifier
private extension View {
    func fieldChrome() -> some View {
        self.padding(.vertical, 13).padding(.horizontal, 14)
            .background(Palette.cardBG, in: RoundedRectangle(cornerRadius: Metric.fieldRadius))
            .overlay(RoundedRectangle(cornerRadius: Metric.fieldRadius).stroke(Palette.cardStroke, lineWidth: 0.5))
    }
}

// Minimal flow layout for wrapping chips (iOS16/macOS13+ Layout API)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
