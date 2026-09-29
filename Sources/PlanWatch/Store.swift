import AppKit
import Combine
import Foundation
import UserNotifications
import PlanWatchCore

@MainActor
final class Store: ObservableObject {
    @Published var configuration: Configuration {
        didSet {
            guard !demo else { return }
            save(configuration, file: "settings.json")
            if oldValue.codexPath != configuration.codexPath { invalidate(.codex) }
            if oldValue.kimiRegion != configuration.kimiRegion { invalidate(.kimi) }
            if oldValue.enabled != configuration.enabled { refresh(force: true) }
        }
    }
    @Published var snapshots: [String: Snapshot] = [:]
    @Published var errors: [String: String] = [:]
    @Published var inFlight: Set<String> = []
    @Published var notice: String?
    @Published var now = Date()
    @Published var notificationAllowed = false
    let demo: Bool
    private var records: [String: AlertRecord] = [:]
    private var nextFetch: [String: Date] = [:]
    private var rateLimitedUntil: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var revisions: [String: UUID] = [:]
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var loginController: WebLoginController?

    init() {
        demo = ProcessInfo.processInfo.arguments.contains("--demo")
        configuration = Configuration()
        if demo {
            configuration.enabled = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0.rawValue, true) })
            snapshots = Demo.snapshots
            return
        }
        do {
            configuration = try Storage.load(Configuration.self, file: "settings.json") ?? Configuration()
            snapshots = try Storage.load([String: Snapshot].self, file: "snapshots.json") ?? [:]
            records = try Storage.load([String: AlertRecord].self, file: "alerts.json") ?? [:]
        } catch { notice = "本地配置无法读取，已使用默认设置。请重新检查账号配置。" }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.now = Date(); self.refresh()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.now = Date(); self.refresh(force: true)
            }
        }
        Task { await updateNotificationPermission(); refresh() }
    }

    var activeProviders: [Provider] { Provider.allCases.filter { configuration.enabled[$0.rawValue] == true } }
    var menuUsage: Double? {
        let id = configuration.selectedProvider
        guard let s = snapshots[id], configuration.enabled[id] == true,
              errors[id] == nil, !s.isStale(at: now, interval: configuration.interval) else { return nil }
        return s.highestUsage(at: now)
    }
    var menuSymbol: String {
        let all = activeProviders.compactMap { provider -> Double? in
            guard errors[provider.id] == nil, let s = snapshots[provider.id],
                  !s.isStale(at: now, interval: configuration.interval) else { return nil }
            return s.highestUsage(at: now)
        }
        if let highest = all.max(), highest >= 95 { return "exclamationmark.circle.fill" }
        if let highest = all.max(), highest >= 80 { return "exclamationmark.circle" }
        if activeProviders.contains(where: { errors[$0.id] != nil || snapshots[$0.id]?.isStale(at: now, interval: configuration.interval) == true }) {
            return "questionmark.circle"
        }
        return "gauge.with.dots.needle.33percent"
    }

    func refresh(force: Bool = false) {
        guard !demo else { return }
        for provider in activeProviders {
            let id = provider.id
            guard !inFlight.contains(id) else { continue }
            if let until = rateLimitedUntil[id], until > Date() { continue }
            // Respect upstream backoff even when the user presses refresh.
            if let next = nextFetch[id], next > Date(), (!force || failures[id, default: 0] > 0) { continue }
            let credential: String
            do { credential = provider == .codex ? "" : try Keychain.read(id) }
            catch { errors[id] = error.localizedDescription; continue }
            if provider != .codex && credential.isEmpty {
                errors[id] = "尚未接入，请打开设置"; continue
            }
            let revision = revisions[id] ?? UUID(); revisions[id] = revision
            let request = FetchRequest(provider: id, credential: credential,
                                       region: configuration.kimiRegion, codexPath: configuration.codexPath)
            inFlight.insert(id)
            Task {
                let result = await Collector.fetch(request)
                guard revisions[id] == revision, configuration.enabled[id] == true else {
                    inFlight.remove(id); refresh(); return
                }
                if let retry = result.retryAfter, retry > 0 { rateLimitedUntil[id] = Date().addingTimeInterval(retry) }
                if let error = result.error {
                    errors[id] = error
                    failures[id, default: 0] += 1
                    let backoff = min(1800, max(120, configuration.interval) * pow(2, Double(min(4, failures[id, default: 1] - 1))))
                    nextFetch[id] = Date().addingTimeInterval(max(backoff, result.retryAfter ?? 0))
                } else {
                    snapshots[id] = result; errors.removeValue(forKey: id); failures[id] = 0
                    nextFetch[id] = Date().addingTimeInterval(max(max(30, configuration.interval), result.retryAfter ?? 0))
                    save(snapshots, file: "snapshots.json")
                    await deliverAlerts(result, revision: revision)
                }
                inFlight.remove(id)
                now = Date()
            }
        }
    }

    func credentialExists(_ provider: Provider) -> Bool { !((try? Keychain.read(provider.id)) ?? "").isEmpty }

    func connect(_ provider: Provider, credential: String) throws {
        guard !demo else { return }
        let clean = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count < 32_768, !clean.contains("\n"), !clean.contains("\r") else {
            throw AppError("请输入有效的凭证")
        }
        try Keychain.save(clean, for: provider.id)
        invalidate(provider)
        configuration.enabled[provider.id] = true
        refresh(force: true)
    }
    func disconnect(_ provider: Provider) throws {
        guard !demo else { return }
        try Keychain.save("", for: provider.id)
        configuration.enabled[provider.id] = false
        invalidate(provider)
        if provider == .commandcode || provider == .kimi { WebLoginController.clearSession(kimi: provider == .kimi) }
    }
    func invalidate(_ provider: Provider) {
        revisions[provider.id] = UUID(); snapshots.removeValue(forKey: provider.id)
        errors.removeValue(forKey: provider.id); nextFetch.removeValue(forKey: provider.id); failures.removeValue(forKey: provider.id)
        rateLimitedUntil.removeValue(forKey: provider.id)
        records = records.filter { !$0.key.hasPrefix(provider.id + "/") }
        save(snapshots, file: "snapshots.json"); save(records, file: "alerts.json")
    }
    func loginWeb(_ provider: Provider) {
        guard !demo else { return }
        loginController = WebLoginController(kimi: provider == .kimi, international: configuration.kimiRegion == "global") { [weak self] cookie in
            guard let self else { return }
            do { try connect(provider, credential: cookie) }
            catch { notice = error.localizedDescription }
        }
        loginController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func updateNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
    func enableNotifications() async {
        guard !demo else { return }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            configuration.notificationsEnabled = allowed
            await updateNotificationPermission()
            if !allowed { notice = "请在系统设置 → 通知 → PlanWatch 中允许通知" }
        } catch { notice = "无法申请系统通知权限，请检查系统设置" }
    }
    func testNotification() async {
        guard !demo else { return }
        await updateNotificationPermission()
        guard notificationAllowed else { notice = "请先开启系统通知权限"; return }
        let content = UNMutableNotificationContent()
        content.title = "PlanWatch 已就绪"; content.body = "额度达到 80%、95% 或耗尽时，将在这里提醒。"; content.sound = .default
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "planwatch-test", content: content, trigger: nil)) }
        catch { notice = "测试通知发送失败" }
    }
    private func deliverAlerts(_ snapshot: Snapshot, revision: UUID) async {
        guard configuration.notificationsEnabled, !demo else { return }
        await updateNotificationPermission()
        guard notificationAllowed, revisions[snapshot.provider] == revision else { return }
        let date = Date()
        var pending: [(String, QuotaWindow, AlertDecision)] = []
        for window in snapshot.windows {
            let key = snapshot.provider + "/" + window.id
            let decision = Alerts.evaluate(window: window, account: snapshot.account, previous: records[key], now: date)
            records[key] = decision.record
            if decision.level != nil { pending.append((key, window, decision)) }
        }
        if !pending.isEmpty {
            let name = Provider(rawValue: snapshot.provider)?.name ?? snapshot.provider
            let content = UNMutableNotificationContent()
            content.title = "\(name) · \(pending.contains(where: { $0.2.level == 100 }) ? "额度已耗尽" : "额度提醒")"
            content.body = pending.prefix(4).map { _, window, _ in
                let pool = window.pool.map { "\($0) · " } ?? ""
                return "\(pool)\(window.label)已用 \(Int(min(100, max(0, window.percent ?? 0)).rounded()))% · \(window.resetText(at: date))"
            }.joined(separator: "\n")
            if pending.count > 4 { content.body += "\n另有 \(pending.count - 4) 项，请打开面板查看。" }
            content.sound = .default
            do {
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                guard revisions[snapshot.provider] == revision else { return }
                for (key, _, decision) in pending { records[key] = Alerts.delivered(decision, now: date) }
            } catch { notice = "系统通知未发送，将在下次刷新时重试" }
        }
        save(records, file: "alerts.json")
    }
    private func save<T: Encodable>(_ value: T, file: String) {
        guard !demo else { return }
        do { try Storage.save(value, file: file) }
        catch { notice = "本地设置保存失败，请检查磁盘空间与文件权限" }
    }
}
