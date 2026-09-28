import Foundation

public struct AlertRecord: Codable, Equatable {
    public var level = 0
    public var resetAt: Double?
    public var account: String?
    public var lowReadings = 0
    public var sentAt: Double = 0
    public init() {}
}

public struct AlertDecision {
    public let level: Int?
    public let record: AlertRecord
}

public enum Alerts {
    // Values at 100% produce a final exhausted notification, even after the 95% warning.
    public static func evaluate(window: QuotaWindow, account: String?, previous: AlertRecord?, now: Date) -> AlertDecision {
        var record = previous ?? AlertRecord()
        if record.account != account { record = AlertRecord(); record.account = account }
        if let next = window.resetAt, let old = record.resetAt, abs(next - old) > 120 {
            record = AlertRecord(); record.account = account
        }
        record.resetAt = window.resetAt
        guard let p = window.percent, p.isFinite, p >= 0, !window.awaitingReset(at: now) else {
            return AlertDecision(level: nil, record: record)
        }
        // A fixed known cycle is rearmed only by its reset identity. For unknown
        // cycles, two low readings and a cooldown permit recovery without flapping.
        if window.resetAt == nil && p < 70 {
            record.lowReadings += 1
            if record.lowReadings >= 2 && now.timeIntervalSince1970 - record.sentAt >= 600 { record.level = 0 }
        } else { record.lowReadings = 0 }
        let level = p >= 100 ? 100 : p >= 95 ? 95 : p >= 80 ? 80 : 0
        guard level > record.level else { return AlertDecision(level: nil, record: record) }
        return AlertDecision(level: level, record: record)
    }

    // Call only after the system has accepted the notification.
    public static func delivered(_ decision: AlertDecision, now: Date) -> AlertRecord {
        var record = decision.record
        if let level = decision.level { record.level = level; record.sentAt = now.timeIntervalSince1970 }
        return record
    }
}
