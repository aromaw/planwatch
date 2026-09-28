import AppKit
import ServiceManagement
import SwiftUI
import PlanWatchCore

@MainActor
struct SettingsView: View {
    @ObservedObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        TabView {
            Form {
                if store.demo { Text("演示模式 · 账号设置不会保存").foregroundStyle(.purple) }
                ForEach(Provider.allCases) { provider in
                    AccountSection(store: store, provider: provider)
                }
                Section {
                    Text("凭证保存在这台 Mac 的钥匙串中，仅发送给对应服务。Codex 使用自己的登录管理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
                .tabItem { Label("账号", systemImage: "person.crop.circle") }
            Form {
                Section("额度提醒") {
                    Toggle("系统通知", isOn: Binding(get: { store.configuration.notificationsEnabled }, set: { enabled in
                        if enabled { Task { await store.enableNotifications() } }
                        else { store.configuration.notificationsEnabled = false }
                    }))
                    Text("已用 80%、95% 和 100% 时提醒；同一周期内自动去重。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("发送测试通知") { Task { await store.testNotification() } }
                        Button("系统通知设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
                    }
                    if store.configuration.notificationsEnabled && !store.notificationAllowed {
                        Label("系统通知权限未开启", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                }
                Section("菜单栏与刷新") {
                    Toggle("菜单栏显示剩余百分比", isOn: $store.configuration.showMenuPercent)
                    Picker("显示订阅", selection: $store.configuration.selectedProvider) {
                        ForEach(Provider.allCases) { Text($0.name).tag($0.id) }
                    }
                    Text("取所选订阅所有已知窗口中最少的剩余量；未知或过期时显示 —。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("自动刷新", selection: $store.configuration.interval) {
                        Text("每 1 分钟").tag(60.0)
                        Text("每 2 分钟（推荐）").tag(120.0)
                        Text("每 5 分钟").tag(300.0)
                    }
                    Toggle("登录 Mac 时启动", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            launchError = nil
                            if enabled && !launchAtLogin { launchError = "请在系统设置 → 通用 → 登录项中允许 PlanWatch" }
                        } catch { launchError = "无法修改登录项，请先将应用放入 Applications 文件夹。" }
                    }))
                    if let launchError { Text(launchError).font(.caption).foregroundStyle(.orange) }
                    Text("Mac 休眠时暂停监控，唤醒后自动刷新。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("PlanWatch 0.1") {
                    Text("一个只关心额度的小工具。macOS 14 或更高版本。")
                        .foregroundStyle(.secondary)
                    Button("打开本地数据文件夹") { NSWorkspace.shared.open(Storage.directory) }
                }
            }.formStyle(.grouped)
                .tabItem { Label("提醒与显示", systemImage: "bell.badge") }
        }
        .padding(8).frame(width: 580, height: 650)
        .disabled(store.demo)
        .onAppear { Task { await store.updateNotificationPermission() } }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                HStack {
                    Text(notice).font(.caption)
                    Spacer()
                    Button("关闭") { store.notice = nil }
                }.padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 10)).padding(12)
            }
        }
    }
}

@MainActor
struct AccountSection: View {
    @ObservedObject var store: Store
    let provider: Provider
    @State private var token = ""
    @State private var message: String?
    @State private var hasCredential = false
    @State private var showAdvanced = false

    var body: some View {
        Section {
            Toggle("监控此订阅", isOn: Binding(get: { store.configuration.enabled[provider.id] == true }, set: {
                store.configuration.enabled[provider.id] = $0
            }))
            if provider == .codex {
                Text("复用本机 Codex CLI 的 ChatGPT 登录状态。首次使用请在终端执行 codex login。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("自动查找 Codex CLI", text: $store.configuration.codexPath)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { chooseCodex() }
                }
                HStack {
                    Button("检查连接") { store.invalidate(.codex); store.refresh(force: true) }
                    Link("安装说明", destination: URL(string: "https://developers.openai.com/codex/cli/")!)
                }
            } else if provider == .commandcode {
                HStack {
                    Button("网页登录 / 重新登录") { store.loginWeb(.commandcode) }
                    Button("清除登录") { disconnect() }
                }
                Text("在应用内打开 Command Code 官网登录，完成后保存会话。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("无法在应用内登录？", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("可在浏览器登录 commandcode.ai，再从开发者工具中复制该网站请求的 Cookie 请求头。粘贴值即可，不包含 Cookie: 前缀。")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("Cookie 请求头", text: $token).textFieldStyle(.roundedBorder)
                        Button("保存 Cookie") { saveCredential() }.disabled(token.isEmpty)
                    }.padding(.vertical, 8)
                }
            } else {
                if provider == .kimi {
                    Picker("账号地区", selection: $store.configuration.kimiRegion) {
                        Text("中国区 · kimi.com").tag("china")
                        Text("国际区 · kimi.ai").tag("global")
                    }
                    Button("网页登录（可读取会员月总额度）") { store.loginWeb(.kimi) }
                }
                SecureField(hasCredential ? "已保存；输入新 Key 可替换" : "粘贴 Coding API Key", text: $token)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存并连接") { saveCredential() }.disabled(token.isEmpty)
                    Button("获取 API Key") { NSWorkspace.shared.open(provider.website) }
                    Spacer()
                    Button("移除") { disconnect() }
                }
                if provider == .kimi {
                    Text("也可使用 Kimi Code API Key。若 Key 查询缺少月额度，请改用网页登录；普通 Moonshot Key 不适用。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("使用 OpenCode Go 的 API Key，查询服务端返回的额度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.inFlight.contains(provider.id) {
                HStack { ProgressView().controlSize(.small); Text("正在检查…").font(.caption).foregroundStyle(.secondary) }
            } else if let error = store.errors[provider.id] {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            } else if store.snapshots[provider.id] != nil {
                Label("已连接", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Label(provider.name, systemImage: provider.symbol).foregroundStyle(provider.tint)
        }
        .onAppear { if provider != .codex { hasCredential = store.credentialExists(provider) } }
    }

    private func saveCredential() {
        do {
            try store.connect(provider, credential: token)
            token = ""; message = "已保存到钥匙串"; hasCredential = true
        } catch { message = error.localizedDescription }
    }
    private func disconnect() {
        do { try store.disconnect(provider); token = ""; hasCredential = false; message = "已移除本工具保存的凭证" }
        catch { message = error.localizedDescription }
    }
    private func chooseCodex() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 可执行文件"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            store.configuration.codexPath = url.path; store.refresh(force: true)
        }
    }
}
