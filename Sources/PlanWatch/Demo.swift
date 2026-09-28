import Foundation
import PlanWatchCore

enum Demo {
    static var snapshots: [String: Snapshot] {
        let now = Date().timeIntervalSince1970
        func make(_ id: String, _ plan: String, _ values: [Double]) -> Snapshot {
            let labels = ["5 小时", "周额度", "月额度"]
            let ids = ["5h", "week", "month"]
            let resets: [Double] = [5400, 194400, 1555200]
            return Snapshot(provider: id, windows: values.enumerated().map {
                QuotaWindow(id: ids[$0.offset], label: labels[$0.offset], percent: $0.element, resetAt: now + resets[$0.offset])
            }, plan: plan)
        }
        return ["codex": make("codex", "Plus", [82, 51]), "kimi": make("kimi", "Allegretto", [32, 64, 43]),
                "commandcode": make("commandcode", "GOAT", [21, 38, 57]), "opencode": make("opencode", "Go", [95, 72, 61])]
    }
}
