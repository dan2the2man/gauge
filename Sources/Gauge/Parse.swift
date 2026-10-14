import Foundation

struct UsageWindow: Equatable {
    var usedPercent: Int
    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
    var minutes: Int?
    var resetsAt: Date?
    var isWeekly: Bool { (minutes ?? 0) >= 24 * 60 }
    var title: String {
        guard let m = minutes else { return "Usage" }
        if m >= 7 * 24 * 60 { return "Weekly" }
        if m % 60 == 0 { return "\(m / 60)-hour" }
        return "\(m)-minute"
    }
}

struct BankedReset: Equatable, Identifiable {
    var id: Int
    var title: String?
    var expiresAt: Date?
}

enum Source: Equatable { case live, sessionLogs }

struct Snapshot: Equatable {
    var windows: [UsageWindow] = []          // longest window first
    var resetsAvailable: Int?                 // nil = unknown
    var resets: [BankedReset] = []
    var creditsBalance: Double?
    var creditsUnlimited = false
    var limitReached: String?
    var asOf: Date
    var source: Source

    var weekly: UsageWindow? { windows.first(where: { $0.isWeekly }) ?? windows.first }
    var shortWindows: [UsageWindow] { windows.filter { $0 != weekly } }
    /// The window that binds hardest; drives the menu-bar text and tint.
    var headline: UsageWindow? { windows.min(by: { $0.remainingPercent < $1.remainingPercent }) }
}

/// Pure parsing of untrusted JSON (app-server responses and session-log lines).
/// Every number is range-checked before conversion so bad input can never trap.
enum Parse {
    /// Finite double within `range`, else nil. Accepts NSNumber or numeric strings.
    static func number(_ any: Any?, in range: ClosedRange<Double>) -> Double? {
        let v: Double?
        if let n = any as? NSNumber, !(any is Bool) { v = n.doubleValue }
        else if let s = any as? String { v = Double(s) }
        else { v = nil }
        guard let d = v, d.isFinite, range.contains(d) else { return nil }
        return d
    }
    static func int(_ any: Any?, in range: ClosedRange<Int>) -> Int? {
        number(any, in: Double(range.lowerBound)...Double(range.upperBound)).map { Int($0.rounded()) }
    }
    static func date(_ any: Any?) -> Date? {
        // 2001…2100 in Unix seconds
        number(any, in: 978_307_200...4_102_444_800).map { Date(timeIntervalSince1970: $0) }
    }

    static func window(_ any: Any?) -> UsageWindow? {
        guard let d = any as? [String: Any] else { return nil }
        // Percent used; a little overshoot is tolerated and clamped, nonsense is rejected.
        guard let used = number(d["usedPercent"] ?? d["used_percent"], in: 0...1000) else { return nil }
        let mins = int(d["windowDurationMins"] ?? d["window_minutes"], in: 1...(366 * 24 * 60))
        return UsageWindow(usedPercent: Int(min(100, used).rounded()),
                           minutes: mins,
                           resetsAt: date(d["resetsAt"] ?? d["resets_at"]))
    }

    static func windows(primary: Any?, secondary: Any?) -> [UsageWindow] {
        [window(primary), window(secondary)].compactMap { $0 }
            .sorted { ($0.minutes ?? 0) > ($1.minutes ?? 0) }
    }

    static func credits(_ any: Any?) -> (Double?, Bool) {
        guard let c = any as? [String: Any] else { return (nil, false) }
        let unlimited = (c["unlimited"] as? Bool) ?? false
        return (number(c["balance"], in: -1e12...1e12), unlimited)
    }

    /// `account/rateLimits/read` result → Snapshot, or nil when the response isn't recognizable
    /// (no rate-limit object or no valid usage window). Callers keep the previous snapshot or fall
    /// back to session logs on nil; an empty "live" snapshot is never produced.
    /// Opaque ids and account ids are dropped here.
    static func live(_ r: [String: Any], at now: Date) -> Snapshot? {
        var rl = r["rateLimits"] as? [String: Any]
        if let byId = r["rateLimitsByLimitId"] as? [String: Any], let codex = byId["codex"] as? [String: Any] {
            rl = codex
        }
        guard let rl else { return nil }
        var s = Snapshot(asOf: now, source: .live)
        s.windows = windows(primary: rl["primary"], secondary: rl["secondary"])
        guard !s.windows.isEmpty else { return nil }
        (s.creditsBalance, s.creditsUnlimited) = credits(rl["credits"])
        s.limitReached = rl["rateLimitReachedType"] as? String
        if let rc = r["rateLimitResetCredits"] as? [String: Any] {
            s.resetsAvailable = int(rc["availableCount"], in: 0...10_000)
            let rows = (rc["credits"] as? [[String: Any]]) ?? []
            s.resets = rows.prefix(100).enumerated().compactMap { i, c in
                if let st = c["status"] as? String, st != "available" { return nil }
                return BankedReset(id: i, title: c["title"] as? String, expiresAt: date(c["expiresAt"]))
            }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        }
        return s
    }

    /// True when an app-server error message means the user isn't signed in / auth failed.
    static func isAuthError(_ message: String) -> Bool {
        let m = message.lowercased()
        return ["not signed in", "not logged in", "sign in", "log in", "login", "logged out",
                "unauthorized", "unauthenticated", "authentication", "auth required", "401",
                "token expired", "refresh token", "no credentials", "credentials"].contains { m.contains($0) }
    }
}
