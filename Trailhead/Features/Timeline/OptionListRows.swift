//  OptionListRows.swift
//  RouteTimelineView 的「附近美食推荐」「住宿推荐」清单行（从主文件拆出，控文件长度）。
//  卡片带首图缩略图、推荐菜/特色标签，外链到高德详情页与小红书看真实图片/点评。

import SwiftUI
import TrailheadCore

enum RecommendationPresentation {
    static func visible<T>(_ options: [T], expanded: Bool, collapsedLimit: Int = 3) -> [T] {
        expanded ? options : Array(options.prefix(collapsedLimit))
    }

    static func proximity(meters: Int?, minutes: Int?, prefix: String) -> String? {
        guard let meters else { return nil }
        let distance = meters < 1_000
            ? "\(meters) m"
            : String(format: "%.1f km", Double(meters) / 1_000)
        if let minutes { return "\(prefix)最近点 \(distance) · 约 \(minutes) 分钟" }
        return "\(prefix)最近点 \(distance)"
    }
}

extension RouteTimelineView {
    /// 未占用主时间线的景点；只有实际时间和体力允许时再选择。
    @ViewBuilder
    func optionalVisitSection(for day: DayPlan) -> some View {
        let options = day.optionalVisits
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                recommendationHeader(title: "如果还有时间 · 可选景点", count: options.count)
                ForEach(RecommendationPresentation.visible(options, expanded: showAllOptionalVisits)) {
                    optionalVisitRow($0)
                }
                recommendationToggle(total: options.count, expanded: $showAllOptionalVisits)
            }
            .padding(.top, 20)
        }
    }

    private func optionalVisitRow(_ opt: OptionalVisitOption) -> some View {
        let selected = selectionStore.selection?.matchesRecommendation(opt.id) == true
        return HStack(spacing: 10) {
            optionThumbnail(photos: opt.photos, icon: "sparkles", color: ItemKind.sight.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(opt.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                HStack(spacing: 8) {
                    if let rating = opt.rating { Text("评分 \(String(format: "%.1f", rating))") }
                    if !opt.subtype.isEmpty { Text(opt.subtype) }
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                Text("建议游玩 \(durationRange(opt.minimumMinutes, opt.comfortableMinutes))")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.green)
                if let proximity = RecommendationPresentation.proximity(
                    meters: opt.distanceMeters, minutes: opt.estimatedMinutes, prefix: "距当天路线") {
                    Text(proximity).font(.system(size: 11)).foregroundStyle(Palette.textMuted)
                }
                optionTags(opt.tags)
            }
            Spacer()
            externalLinkButtons(poiId: opt.id, name: opt.name)
            Image(systemName: "mappin.circle").font(.system(size: 15)).foregroundStyle(Palette.textMuted)
        }
        .padding(10)
        .background(Palette.fieldBG.opacity(selected ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? ItemKind.sight.color : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            selectionStore.selection = .recommendation(
                MapFocus(id: opt.id, name: opt.name, lat: opt.lat, lng: opt.lng, kind: .sight))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("在地图查看可选景点：\(opt.name)，建议游玩 \(durationRange(opt.minimumMinutes, opt.comfortableMinutes))")
        .accessibilityAction {
            selectionStore.selection = .recommendation(
                MapFocus(id: opt.id, name: opt.name, lat: opt.lat, lng: opt.lng, kind: .sight))
        }
        .padding(.horizontal, 18)
    }

    private func durationRange(_ minimum: Int, _ comfortable: Int) -> String {
        func text(_ minutes: Int) -> String {
            if minutes < 60 { return "\(minutes) 分钟" }
            let hours = Double(minutes) / 60
            return hours == hours.rounded()
                ? "\(Int(hours)) 小时"
                : String(format: "%.1f 小时", hours)
        }
        return "\(text(minimum))～\(text(comfortable))"
    }

    /// 当天「附近美食推荐」（按就近 + 评分，不排进动线，供用户自选）。
    @ViewBuilder
    func foodSection(for day: DayPlan) -> some View {
        let options = day.foodOptions
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                recommendationHeader(title: "备选推荐 · 附近美食", count: options.count)
                ForEach(RecommendationPresentation.visible(options, expanded: showAllFoodOptions)) { foodRow($0) }
                recommendationToggle(total: options.count, expanded: $showAllFoodOptions)
            }
            .padding(.top, 20)
        }
    }

    private func foodRow(_ opt: FoodOption) -> some View {
        let selected = selectionStore.selection?.matchesRecommendation(opt.id) == true
        return HStack(spacing: 10) {
            optionThumbnail(photos: opt.photos, icon: "fork.knife", color: ItemKind.food.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(opt.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                HStack(spacing: 8) {
                    if let r = opt.rating { Text("评分 \(String(format: "%.1f", r))") }
                    if !opt.subtype.isEmpty { Text(opt.subtype) }
                    if let p = opt.avgPrice, p > 0 { Text("¥\(p)/人") }
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                if let proximity = RecommendationPresentation.proximity(
                    meters: opt.distanceMeters, minutes: opt.estimatedMinutes, prefix: "距当天路线") {
                    Text(proximity).font(.system(size: 11)).foregroundStyle(Palette.green)
                }
                optionTags(opt.tags)
            }
            Spacer()
            externalLinkButtons(poiId: opt.id, name: opt.name)
            Image(systemName: "mappin.circle").font(.system(size: 15)).foregroundStyle(Palette.textMuted)
        }
        .padding(10)
        .background(Palette.fieldBG.opacity(selected ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? ItemKind.food.color : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            selectionStore.selection = .recommendation(
                MapFocus(id: opt.id, name: opt.name, lat: opt.lat, lng: opt.lng, kind: .food))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("在地图查看美食推荐：\(opt.name)")
        .accessibilityAction {
            selectionStore.selection = .recommendation(
                MapFocus(id: opt.id, name: opt.name, lat: opt.lat, lng: opt.lng, kind: .food))
        }
        .padding(.horizontal, 18)
    }

    /// 住宿推荐清单（不排进每日动线，整趟共享，供用户自选）。
    @ViewBuilder
    var lodgingSection: some View {
        let options = trip.lodgingOptions
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                recommendationHeader(title: "备选推荐 · 住宿（自选）", count: options.count)
                ForEach(RecommendationPresentation.visible(options, expanded: showAllLodgingOptions)) {
                    lodgingRow($0)
                }
                recommendationToggle(total: options.count, expanded: $showAllLodgingOptions)
            }
            .padding(.top, 20)
        }
    }

    private func lodgingRow(_ opt: LodgingOption) -> some View {
        let selected = selectionStore.selection?.matchesRecommendation(opt.id) == true
        return HStack(spacing: 10) {
            optionThumbnail(photos: opt.photos, icon: "bed.double.fill", color: Palette.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(opt.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                HStack(spacing: 8) {
                    if let r = opt.rating { Text("评分 \(String(format: "%.1f", r))") }
                    if let p = opt.avgPrice { Text("¥\(p)/晚") }
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                if let proximity = RecommendationPresentation.proximity(
                    meters: opt.distanceMeters, minutes: opt.estimatedMinutes, prefix: "距整趟路线") {
                    Text(proximity).font(.system(size: 11)).foregroundStyle(Palette.green)
                }
                optionTags(opt.tags)
            }
            Spacer()
            externalLinkButtons(poiId: opt.id, name: opt.name)
            Image(systemName: "mappin.circle").font(.system(size: 15)).foregroundStyle(Palette.textMuted)
        }
        .padding(10)
        .background(Palette.fieldBG.opacity(selected ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? ItemKind.lodging.color : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            selectionStore.selection = .recommendation(
                MapFocus(id: opt.id, name: opt.name, lat: opt.lat, lng: opt.lng, kind: .lodging))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("在地图查看住宿推荐：\(opt.name)")
        .accessibilityAction {
            selectionStore.selection = .recommendation(
                MapFocus(id: opt.id, name: opt.name, lat: opt.lat, lng: opt.lng, kind: .lodging))
        }
        .padding(.horizontal, 18)
    }

    private func recommendationHeader(title: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(Typo.display(15, .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.textMuted)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Palette.fieldBG, in: Capsule())
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private func recommendationToggle(total: Int, expanded: Binding<Bool>) -> some View {
        if total > 3 {
            Button {
                withAnimation(.snappy) { expanded.wrappedValue.toggle() }
            } label: {
                Label(expanded.wrappedValue ? "收起" : "查看其余 \(total - 3) 个",
                      systemImage: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .accessibilityHint("展开或收起备选推荐，不会改变地图当前选择")
        }
    }

    /// 首图缩略图；加载中/无图退化为类型图标（旧样式）。
    @ViewBuilder
    private func optionThumbnail(photos: [String], icon: String, color: Color) -> some View {
        let fallback = Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color)
        Group {
            if let url = photos.first.flatMap(POILinks.httpsPhotoURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: 44, height: 44)
        .background(Palette.fieldBG)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 推荐菜/特色标签行（最多 3 个，超出截断）。
    @ViewBuilder
    private func optionTags(_ tags: [String]) -> some View {
        if !tags.isEmpty {
            Text(tags.prefix(3).joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
        }
    }

    /// 外链：高德详情页（图片/点评）+ 小红书搜索。高德无点评正文，真实点评走外链。
    private func externalLinkButtons(poiId: String, name: String) -> some View {
        HStack(spacing: 6) {
            if let url = POILinks.amapDetail(poiId: poiId) {
                linkButton("safari", url: url, help: "高德详情：图片与点评")
            }
            if let url = POILinks.xiaohongshuSearch(name: name, city: trip.city) {
                linkButton("magnifyingglass", url: url, help: "小红书搜点评")
            }
        }
    }

    private func linkButton(_ icon: String, url: URL, help: String) -> some View {
        Button { openURL(url) } label: {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Metric.minimumControlTarget, height: Metric.minimumControlTarget)
                .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
