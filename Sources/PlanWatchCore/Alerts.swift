import Foundation

public struct AlertRecord: Codable, Equatable {
    public var level = 0
    public var resetAt: Double?
    public var account: String?
    public var lowReadings = 0
    public var sentAt: Double = 0
    public var seenAt: Double?
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
        let time = now.timeIntervalSince1970
        if let next = window.resetAt, let old = record.resetAt {
            // Rolling windows move their reset forward by roughly the time between
            // readings; that drift is the same cycle. A passed reset or a larger jump is new.
            let drift = next - old
            // Records saved before seenAt existed have no baseline; seed it without rearming.
            let jumped = record.seenAt.map { drift > max(0, time - $0) + 120 } ?? false
            if (time >= old && abs(drift) > 120) || drift < -120 || jumped {
                record = AlertRecord(); record.account = account
            }
        }
        record.resetAt = window.resetAt
        record.seenAt = time
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
