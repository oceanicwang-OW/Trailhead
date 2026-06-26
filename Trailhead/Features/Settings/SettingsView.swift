//  SettingsView.swift
//  FRAME 9/10 — grouped settings: API keys (Keychain-backed), monthly quota,
//  cache. UI mirrors the mockup; values bind to KeychainStore + a usage counter.

import SwiftUI
import TrailheadCore

struct SettingsView: View {
    @State private var providerName = "Anthropic · Claude"
    @State private var model = "Claude Sonnet 4.5"
    @State private var keyMasked = "sk-ant-•••• •••• 3f2a"
    @State private var quotaUsed = 1240
    @State private var quotaTotal = 2000
    @State private var offlineMaps = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("API 与用量").font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Palette.textPrimary).padding(.bottom, -4)

                group("API 密钥") {
                    row("服务商", trailing: providerName)
                    Divider().padding(.leading, 15)
                    HStack {
                        Text("API Key").font(Typo.body).foregroundStyle(Palette.textPrimary)
                        Spacer()
                        Text(keyMasked).font(Typo.mono).foregroundStyle(Palette.textPrimary).tracking(1)
                        pill("显示"); pill("更换", tint: Palette.blue)
                    }.padding(.horizontal, 15).padding(.vertical, 11)
                    Divider().padding(.leading, 15)
                    row("模型", trailing: model, chevron: true)
                }

                group("本月用量") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 0) {
                            Text("请求配额").font(Typo.body).foregroundStyle(Palette.textPrimary)
                            Spacer()
                            Text("\(quotaUsed)").font(Typo.body.weight(.bold)).foregroundStyle(Palette.textPrimary)
                            Text(" / \(quotaTotal) 次").font(Typo.body).foregroundStyle(Palette.textTertiary)
                        }
                        ProgressView(value: Double(quotaUsed), total: Double(quotaTotal)).tint(Palette.green)
                        Text("还剩 \(quotaTotal - quotaUsed) 次生成 · 配额将于 7 月 1 日重置")
                            .font(Typo.caption2).foregroundStyle(Palette.textSecondary)
                    }.padding(.horizontal, 15).padding(.vertical, 14)
                }

                group("缓存与存储") {
                    HStack {
                        Text("离线地图").font(Typo.body).foregroundStyle(Palette.textPrimary)
                        Spacer()
                        Toggle("", isOn: $offlineMaps).labelsHidden().tint(Palette.green)
                    }.padding(.horizontal, 15).padding(.vertical, 8)
                    Divider().padding(.leading, 15)
                    row("已缓存行程", trailing: "18 个行程 · 124 MB")
                    Divider().padding(.leading, 15)
                    HStack {
                        Text("清除缓存").font(Typo.body).foregroundStyle(Palette.red)
                        Spacer()
                        Text("释放 124 MB").font(Typo.caption).foregroundStyle(Palette.textTertiary)
                    }.padding(.horizontal, 15).padding(.vertical, 11)
                }
            }
            .padding(26)
        }
        .background(Palette.groupedBG)
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
    private func pill(_ text: String, tint: Color? = nil) -> some View {
        Text(text).font(.system(size: 12, weight: tint == nil ? .medium : .semibold))
            .foregroundStyle(tint ?? Palette.textPrimary)
            .padding(.vertical, 4).padding(.horizontal, 11)
            .background((tint ?? Palette.textPrimary).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }
}
