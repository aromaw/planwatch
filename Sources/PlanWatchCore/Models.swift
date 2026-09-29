import Foundation

public enum Provider: String, CaseIterable, Codable, Identifiable {
    case codex, kimi, commandcode, opencode
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: return "Codex"
        case .kimi: return "Kimi Code"
        case .commandcode: return "Command Code"
        case .opencode: return "OpenCode Go"
        }
    }
    public var symbol: String {
        switch self {
        case .codex: return "terminal"
        case .kimi: return "moon.stars"
        case .commandcode: return "command"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        }
    }
    public var website: URL {
        switch self {
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .kimi: return URL(string: "https://www.kimi.com/code/console")!
        case .commandcode: return URL(string: "https://commandcode.ai/usage")!
        case .opencode: return URL(string: "https://opencode.ai/auth")!
        }
    }
}

public struct QuotaWindow: Codable, Identifiable, Equatable {
    public var id: String
    public var label: String
    public var pool: String?
    public var percent: Double?
    public var used: Double?
    public var limit: Double?
    public var unit: String?
    public var resetAt: Double?
    public var note: String?

    public init(id: String, label: String, percent: Double? = nil, resetAt: Double? = nil, pool: String? = nil) {
        self.id = id; self.label = label; self.percent = percent; self.resetAt = resetAt; self.pool = pool
    }
    public var remainingPercent: Int? { percent.map { Int(max(0, 100 - $0).rounded(.down)) } }
    public func awaitingReset(at now: Date) -> Bool { resetAt.map { $0 <= now.timeIntervalSince1970 } ?? false }
    public func resetText(at now: Date) -> String {
        guard let resetAt else { return "重置时间未知" }
        let seconds = resetAt - now.timeIntervalSince1970
        if seconds <= 0 { return "等待额度更新" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)天 \(minutes % 1440 / 60)小时后重置" }
        if minutes >= 60 { return "\(minutes / 60)小时 \(minutes % 60)分后重置" }
        return "\(minutes)分钟后重置"
    }
}

public struct Snapshot: Codable, Equatable {
    public var provider: String
    public var plan: String?
    public var account: String?
    public var windows: [QuotaWindow]
    public var notes: [String]?
    public var fetchedAt: Double
    public var error: String?
    public var errorCode: String?
    public var retryAfter: Double?

    public init(provider: String, windows: [QuotaWindow], fetchedAt: Double = Date().timeIntervalSince1970,
                plan: String? = nil, error: String? = nil) {
        self.provider = provider; self.windows = windows; self.fetchedAt = fetchedAt; self.plan = plan; self.error = error
    }
    public func isStale(at now: Date, interval: Double = 120) -> Bool {
        now.timeIntervalSince1970 - fetchedAt > max(300, interval * 2.5)
    }
    public func highestUsage(at now: Date) -> Double? {
        windows.filter { !$0.awaitingReset(at: now) }.compactMap(\.percent).max()
    }
}

public struct Configuration: Codable {
    public var enabled: [String: Bool] = ["codex": true]
    public var codexPath = ""
    public var kimiRegion = "china"
    public var notificationsEnabled = false
    public var interval: Double = 120
    public var selectedProvider = "codex"
    public var showMenuPercent = false
    public init() {}

    // Missing keys keep their defaults so settings written by older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Configuration()
        enabled = try c.decodeIfPresent([String: Bool].self, forKey: .enabled) ?? d.enabled
        codexPath = try c.decodeIfPresent(String.self, forKey: .codexPath) ?? d.codexPath
        kimiRegion = try c.decodeIfPresent(String.self, forKey: .kimiRegion) ?? d.kimiRegion
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? d.interval
        selectedProvider = try c.decodeIfPresent(String.self, forKey: .selectedProvider) ?? d.selectedProvider
        showMenuPercent = try c.decodeIfPresent(Bool.self, forKey: .showMenuPercent) ?? d.showMenuPercent
    }
}

public struct FetchRequest: Encodable {
    public let provider: String
    public let credential: String
    public let region: String
    public let codexPath: String
    public init(provider: String, credential: String, region: String, codexPath: String) {
        self.provider = provider; self.credential = credential; self.region = region; self.codexPath = codexPath
    }
}
