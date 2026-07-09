//  OptionListRows.swift
//  RouteTimelineView 的「附近美食推荐」「住宿推荐」清单行（从主文件拆出，控文件长度）。
//  卡片带首图缩略图、推荐菜/特色标签，外链到高德详情页与小红书看真实图片/点评。

import SwiftUI
import TrailheadCore

extension RouteTimelineView {
    /// 当天「附近美食推荐」（按就近 + 评分，不排进动线，供用户自选）。
    @ViewBuilder
    func foodSection(for day: DayPlan) -> some View {
        let options = day.foodOptions
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("附近美食推荐")
                    .font(Typo.display(15, .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 18)
                ForEach(options) { foodRow($0) }
            }
            .padding(.top, 20)
        }
    }

    private func foodRow(_ opt: FoodOption) -> some View {
        let selected = mapFocus?.id == opt.id
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
            mapFocus = MapFocus(id: opt.id, name: opt.name, lat: opt.lat, lng: opt.lng, kind: .food)
        }
        .padding(.horizontal, 18)
    }

    /// 住宿推荐清单（不排进每日动线，整趟共享，供用户自选）。
    @ViewBuilder
    var lodgingSection: some View {
        let options = trip.lodgingOptions
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("住宿推荐（自选）")
                    .font(Typo.display(15, .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 18)
                ForEach(options) { lodgingRow($0) }
            }
            .padding(.top, 20)
        }
    }

    private func lodgingRow(_ opt: LodgingOption) -> some View {
        let selected = mapFocus?.id == opt.id
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
            mapFocus = MapFocus(id: opt.id, name: opt.name, lat: opt.lat, lng: opt.lng, kind: .lodging)
        }
        .padding(.horizontal, 18)
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
                .frame(width: 24, height: 24)
                .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
