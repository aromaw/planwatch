import AppKit
import SwiftUI
import PlanWatchCore

extension Provider {
    var tint: Color {
        switch self {
        case .codex: return Color(red: 0.18, green: 0.58, blue: 0.49)
        case .kimi: return Color(red: 0.36, green: 0.39, blue: 0.86)
        case .commandcode: return Color(red: 0.72, green: 0.43, blue: 0.16)
        case .opencode: return Color(red: 0.36, green: 0.47, blue: 0.62)
        }
    }
}

@MainActor
struct Dashboard: View {
    @ObservedObject var store: Store
    #if canImport(SwiftUICore)
    @Environment(\.openSettings) private var openSettings
    #endif
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PLANWATCH").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(.secondary)
                    Text("额度概览").font(.system(size: 23, weight: .semibold))
                }
                Spacer()
                if !store.inFlight.isEmpty { ProgressView().controlSize(.small).scaleEffect(0.8) }
                Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                    .buttonStyle(.borderless).help("刷新额度").disabled(store.demo || !store.inFlight.isEmpty)
            }.padding(20)
            if store.demo {
                Label("演示数据 · 不查询账号或发送通知", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.purple).frame(maxWidth: .infinity).padding(8).background(.purple.opacity(0.08))
            }
            if let notice = store.notice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(.horizontal, 20).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.activeProviders.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text("接入你的 coding 订阅").font(.headline)
                            Text("五小时、周、月额度，一眼看清。")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("接入账号") { showSettings() }.buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity).padding(.vertical, 42)
                    }
                    ForEach(store.activeProviders) { provider in
                        ProviderCard(provider: provider, snapshot: store.snapshots[provider.id],
                                     error: store.errors[provider.id], loading: store.inFlight.contains(provider.id),
                                     now: store.now, interval: store.configuration.interval, openSettings: showSettings)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }.frame(maxHeight: 510)
            Divider()
            HStack(spacing: 7) {
                Circle().fill(store.configuration.notificationsEnabled && store.notificationAllowed ? .green : .secondary.opacity(0.4)).frame(width: 5, height: 5)
                Text(store.configuration.notificationsEnabled && store.notificationAllowed ? "额度提醒已开启" : "额度提醒未开启")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { showSettings() } label: { Image(systemName: "gearshape") }.help("设置")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("退出 PlanWatch")
            }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 13)
        }
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        #if canImport(SwiftUICore)
        openSettings()
        #else
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        #endif
    }
}

@MainActor
struct ProviderCard: View {
    let provider: Provider
    let snapshot: Snapshot?
    let error: String?
    let loading: Bool
    let now: Date
    let interval: Double
    let openSettings: () -> Void
    @State private var expanded = false
    private var stale: Bool { error != nil || snapshot?.isStale(at: now, interval: interval) == true }
    private var mainWindows: [QuotaWindow] { snapshot?.windows.filter { ($0.pool ?? "").isEmpty } ?? [] }
    private var extraWindows: [QuotaWindow] { snapshot?.windows.filter { !($0.pool ?? "").isEmpty } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: provider.symbol).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(provider.tint).frame(width: 32, height: 32)
                    .background(provider.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.system(size: 13, weight: .semibold))
                    if let plan = snapshot?.plan { Text(plan).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
                if stale {
                    Text("待更新").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(.orange.opacity(0.1), in: Capsule())
                }
                Button { NSWorkspace.shared.open(provider.website) } label: {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                }.buttonStyle(.plain).help("打开官方额度页面")
            }
            if let error {
                VStack(alignment: .leading, spacing: 7) {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("检查账号设置", action: openSettings).font(.caption).buttonStyle(.link)
                }
            }
            if let snapshot, !snapshot.windows.isEmpty {
                VStack(spacing: 14) {
                    ForEach(mainWindows) { window in WindowRow(window: window, tint: provider.tint, stale: stale, now: now) }
                    if !extraWindows.isEmpty {
                        DisclosureGroup(isExpanded: $expanded) {
                            VStack(spacing: 14) {
                                ForEach(extraWindows) { window in WindowRow(window: window, tint: provider.tint, stale: stale, now: now) }
                            }.padding(.top, 12)
                        } label: {
                            Text("模型 / 额度池明细（\(Set(extraWindows.compactMap(\.pool)).count)）").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let notes = snapshot.notes, !notes.isEmpty {
                    Text(notes.joined(separator: "\n")).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("\(stale ? "上次成功更新" : "更新于") \(Date(timeIntervalSince1970: snapshot.fetchedAt).formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    if stale { Text("数值仅供参考") }
                }.font(.system(size: 9)).foregroundStyle(.tertiary)
            } else if error == nil {
                Text(loading ? "正在读取账号额度…" : "等待首次刷新")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
            }
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.045)))
    }
}

@MainActor
struct WindowRow: View {
    let window: QuotaWindow
    let tint: Color
    let stale: Bool
    let now: Date
    private var barColor: Color {
        guard !stale, !window.awaitingReset(at: now) else { return .secondary.opacity(0.4) }
        if (window.percent ?? 0) >= 95 { return .red }
        if (window.percent ?? 0) >= 80 { return .orange }
        return tint
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pool = window.pool, !pool.isEmpty { Text(pool).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 11, weight: .medium))
                Spacer()
                if let percent = window.percent {
                    Text("\(Int(min(100, max(0, percent)).rounded()))%").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("已用").font(.system(size: 9)).foregroundStyle(.secondary)
                } else { Text(window.note == "套餐未启用周限制" ? "不适用" : "未提供").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.055))
                    if let p = window.percent {
                        Capsule().fill(barColor).frame(width: geometry.size.width * min(100, max(0, p)) / 100)
                    }
                }
            }.frame(height: 5)
            HStack {
                Text(window.resetText(at: now))
                Spacer()
                if let used = window.used, let limit = window.limit, let unit = window.unit {
                    Text("\(used.formatted(.number.precision(.fractionLength(0...1)))) / \(limit.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                } else if let remaining = window.remainingPercent { Text("剩余 \(remaining)%") }
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .opacity(stale ? 0.65 : 1)
        .accessibilityElement(children: .combine)
    }
}
