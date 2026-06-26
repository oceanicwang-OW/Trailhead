//  SettingsView.swift
//  FRAME 9/10 — grouped settings: API keys (Keychain-backed), monthly quota,
//  cache. UI mirrors the mockup; values bind to KeychainStore + a usage counter.

import SwiftData
import SwiftUI
import TrailheadCore

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var keys = APIKeySettingsViewModel()
    @State private var amapToday = 0
    @State private var llmToday = 0
    /// 软性日预算（仅用于进度条参照；高德个人免费配额按接口分别计，非硬上限）。
    private let dailyBudget = 5000

    @AppStorage("offlineCacheEnabled") private var offlineCacheEnabled = true
    @State private var tripCount = 0
    @State private var cachedPOICount = 0
    @State private var confirmClearCache = false
    @State private var confirmClearAll = false

    private func reloadUsage() {
        let usage = UsageStore()
        amapToday = usage.count(.amap)
        llmToday = usage.count(.llm)
    }

    private func reloadStorage() {
        tripCount = (try? modelContext.fetchCount(FetchDescriptor<Trip>())) ?? 0
        cachedPOICount = (try? modelContext.fetchCount(FetchDescriptor<CachedPOI>())) ?? 0
    }

    private func clearCache() {
        try? POICache(context: modelContext).clearAll()
        reloadStorage()
    }

    private func clearAllData() {
        try? POICache(context: modelContext).clearAll()
        try? TripRepository(context: modelContext).deleteAll()
        reloadStorage()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("API 与用量").font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Palette.textPrimary).padding(.bottom, -4)

                group("API 密钥") {
                    keyRow(
                        title: "高德 Web 服务 Key",
                        status: keys.amapStatusText,
                        draft: $keys.amapKeyDraft,
                        placeholder: keys.hasAmapKey ? "输入新 key 以覆盖" : "粘贴高德 Web 服务 key",
                        save: keys.saveAmapKey,
                        delete: keys.deleteAmapKey,
                        canDelete: keys.hasAmapKey
                    )
                    Divider().padding(.leading, 15)
                    keyRow(
                        title: "DeepSeek API Key",
                        status: keys.deepSeekStatusText,
                        draft: $keys.deepSeekKeyDraft,
                        placeholder: keys.hasDeepSeekKey ? "输入新 key 以覆盖" : "粘贴 DeepSeek API key",
                        save: keys.saveDeepSeekKey,
                        delete: keys.deleteDeepSeekKey,
                        canDelete: keys.hasDeepSeekKey
                    )
                }

                group("今日用量") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 0) {
                            Text("高德接口调用").font(Typo.body).foregroundStyle(Palette.textPrimary)
                            Spacer()
                            Text("\(amapToday)").font(Typo.body.weight(.bold)).foregroundStyle(Palette.textPrimary)
                            Text(" / \(dailyBudget) 次").font(Typo.body).foregroundStyle(Palette.textTertiary)
                        }
                        ProgressView(value: Double(min(amapToday, dailyBudget)), total: Double(dailyBudget))
                            .tint(amapToday >= dailyBudget ? Palette.red : Palette.green)
                        HStack(spacing: 0) {
                            Text("DeepSeek 生成").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                            Spacer()
                            Text("\(llmToday) 次").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        }
                        Text("本地计数 · 次日 0 点自动归零")
                            .font(Typo.caption2).foregroundStyle(Palette.textTertiary)
                    }.padding(.horizontal, 15).padding(.vertical, 14)
                }

                group("缓存与存储") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用离线缓存").font(Typo.body).foregroundStyle(Palette.textPrimary)
                            Text("同城重复生成命中本地、省高德配额").font(Typo.caption2).foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: $offlineCacheEnabled).labelsHidden().tint(Palette.green)
                    }.padding(.horizontal, 15).padding(.vertical, 8)
                    Divider().padding(.leading, 15)
                    row("已保存行程", trailing: "\(tripCount) 个")
                    Divider().padding(.leading, 15)
                    row("POI 缓存", trailing: "\(cachedPOICount) 条")
                    Divider().padding(.leading, 15)
                    destructiveRow("清除 POI 缓存", trailing: "\(cachedPOICount) 条") { confirmClearCache = true }
                    Divider().padding(.leading, 15)
                    destructiveRow("清除全部数据", trailing: "行程 + 缓存") { confirmClearAll = true }
                }
            }
            .padding(26)
        }
        .background(Palette.groupedBG)
        .onAppear { keys.load(); reloadUsage(); reloadStorage() }
        .alert("清除 POI 缓存？", isPresented: $confirmClearCache) {
            Button("清除", role: .destructive) { clearCache() }
            Button("取消", role: .cancel) {}
        } message: { Text("仅清空本地 POI 缓存，行程不受影响；下次生成会重新联网召回。") }
        .alert("清除全部数据？", isPresented: $confirmClearAll) {
            Button("清除全部", role: .destructive) { clearAllData() }
            Button("取消", role: .cancel) {}
        } message: { Text("删除所有行程与缓存，不可恢复。") }
    }

    private func destructiveRow(_ title: String, trailing: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(Typo.body).foregroundStyle(Palette.red)
                Spacer()
                Text(trailing).font(Typo.caption).foregroundStyle(Palette.textTertiary)
            }.padding(.horizontal, 15).padding(.vertical, 11)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // helpers
    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(Typo.caption2.weight(.semibold)).foregroundStyle(Palette.textSecondary).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(Palette.cardBG, in: RoundedRectangle(cornerRadius: 11))
        }
    }
    private func row(_ title: String, trailing: String, chevron: Bool = false) -> some View {
        HStack {
            Text(title).font(Typo.body).foregroundStyle(Palette.textPrimary)
            Spacer()
            Text(trailing).font(Typo.body).foregroundStyle(Palette.textSecondary)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Palette.textTertiary) }
        }.padding(.horizontal, 15).padding(.vertical, 11)
    }

    private func keyRow(title: String, status: String, draft: Binding<String>,
                        placeholder: String, save: @escaping () -> Void,
                        delete: @escaping () -> Void, canDelete: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Typo.body).foregroundStyle(Palette.textPrimary)
                    Text(status).font(Typo.caption2).foregroundStyle(canDelete ? Palette.green : Palette.textTertiary)
                }
                Spacer()
                if canDelete {
                    Button("删除", role: .destructive, action: delete)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.red)
                }
            }
            HStack(spacing: 8) {
                SecureField(placeholder, text: draft)
                    .font(Typo.mono)
                    .textFieldStyle(.roundedBorder)
                Button("保存", action: save)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.blue)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 11)
                    .background(Palette.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }

    private func pill(_ text: String, tint: Color? = nil) -> some View {
        Text(text).font(.system(size: 12, weight: tint == nil ? .medium : .semibold))
            .foregroundStyle(tint ?? Palette.textPrimary)
            .padding(.vertical, 4).padding(.horizontal, 11)
            .background((tint ?? Palette.textPrimary).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }
}
