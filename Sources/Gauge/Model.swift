import Foundation
import AppKit
import Combine

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

enum Parse {
    static func window(_ any: Any?) -> UsageWindow? {
        guard let d = any as? [String: Any] else { return nil }
        guard let used = (d["usedPercent"] ?? d["used_percent"]) as? NSNumber else { return nil }
        let mins = (d["windowDurationMins"] ?? d["window_minutes"]) as? NSNumber
        let reset = (d["resetsAt"] ?? d["resets_at"]) as? NSNumber
        return UsageWindow(usedPercent: Int(used.doubleValue.rounded()),
                           minutes: mins?.intValue,
                           resetsAt: reset.map { Date(timeIntervalSince1970: $0.doubleValue) })
    }

    static func windows(primary: Any?, secondary: Any?) -> [UsageWindow] {
        [window(primary), window(secondary)].compactMap { $0 }
            .sorted { ($0.minutes ?? 0) > ($1.minutes ?? 0) }
    }

    static func credits(_ any: Any?) -> (Double?, Bool) {
        guard let c = any as? [String: Any] else { return (nil, false) }
        let unlimited = (c["unlimited"] as? Bool) ?? false
        if let s = c["balance"] as? String, let v = Double(s) { return (v, unlimited) }
        if let n = c["balance"] as? NSNumber { return (n.doubleValue, unlimited) }
        return (nil, unlimited)
    }

    /// `account/rateLimits/read` result → Snapshot. Opaque ids and account ids are dropped here.
    static func live(_ r: [String: Any], at now: Date) -> Snapshot {
        var rl = r["rateLimits"] as? [String: Any] ?? [:]
        if let byId = r["rateLimitsByLimitId"] as? [String: Any], let codex = byId["codex"] as? [String: Any] {
            rl = codex
        }
        var s = Snapshot(asOf: now, source: .live)
        s.windows = windows(primary: rl["primary"], secondary: rl["secondary"])
        (s.creditsBalance, s.creditsUnlimited) = credits(rl["credits"])
        s.limitReached = rl["rateLimitReachedType"] as? String
        if let rc = r["rateLimitResetCredits"] as? [String: Any] {
            s.resetsAvailable = (rc["availableCount"] as? NSNumber)?.intValue
            let rows = (rc["credits"] as? [[String: Any]]) ?? []
            s.resets = rows.enumerated().compactMap { i, c in
                if let st = c["status"] as? String, st != "available" { return nil }
                return BankedReset(id: i, title: c["title"] as? String,
                                   expiresAt: (c["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
            }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        }
        return s
    }
}

/// Fallback + credit-history seed: newest `token_count` rate_limits in ~/.codex/sessions.
enum SessionLogs {
    static var root: URL { Setup.codexHome.appendingPathComponent("sessions") }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    static func recentFiles(days: Int) -> [URL] {
        let fm = FileManager.default
        let cal = Calendar(identifier: .gregorian)
        var urls: [URL] = []
        for back in 0...days {
            guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            urls += items.filter { $0.pathExtension == "jsonl" }
        }
        return urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    struct Sample { var at: Date; var rl: [String: Any] }

    static func samples(in url: URL) -> [Sample] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var out: [Sample] = []
        let needle = Data("\"rate_limits\"".utf8)
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            if line.range(of: needle) != nil,
               let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let ts = obj["timestamp"] as? String, let at = iso.date(from: ts),
               let p = obj["payload"] as? [String: Any], let rl = p["rate_limits"] as? [String: Any] {
                out.append(Sample(at: at, rl: rl))
            }
            start = end < data.endIndex ? data.index(after: end) : end
        }
        return out
    }

    /// Newest sample that actually carries a usage window (some events carry only credits).
    static func latestSnapshot() -> Snapshot? {
        var best: (Date, Snapshot)? = nil
        for url in recentFiles(days: 7).prefix(6) {
            for s in samples(in: url) {
                let w = Parse.windows(primary: s.rl["primary"], secondary: s.rl["secondary"])
                guard !w.isEmpty else { continue }
                if let b = best, b.0 >= s.at { continue }
                var snap = Snapshot(asOf: s.at, source: .sessionLogs)
                snap.windows = w
                (snap.creditsBalance, snap.creditsUnlimited) = Parse.credits(s.rl["credits"])
                snap.limitReached = s.rl["rate_limit_reached_type"] as? String
                best = (s.at, snap)
            }
        }
        return best?.1
    }

    static func creditSamples(days: Int) -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        for url in recentFiles(days: days) {
            for s in samples(in: url) {
                if let b = Parse.credits(s.rl["credits"]).0 { out.append((s.at, b)) }
            }
        }
        return out
    }
}

/// Balance samples → recent burn. Stored locally (time + balance only).
final class CreditHistory {
    private(set) var samples: [(Date, Double)] = []
    private let url: URL

    init(dir: URL) {
        url = dir.appendingPathComponent("credits.json")
        if let d = try? Data(contentsOf: url), let arr = try? JSONSerialization.jsonObject(with: d) as? [[Double]] {
            samples = arr.compactMap { $0.count == 2 ? (Date(timeIntervalSince1970: $0[0]), $0[1]) : nil }
        }
    }

    var isEmpty: Bool { samples.isEmpty }

    func merge(_ new: [(Date, Double)]) {
        samples += new
        samples.sort { $0.0 < $1.0 }
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        samples.removeAll { $0.0 < cutoff }
        // thin to one sample per 10 minutes
        var thinned: [(Date, Double)] = []
        for s in samples {
            if let last = thinned.last, s.0.timeIntervalSince(last.0) < 600 { thinned[thinned.count - 1] = s } else { thinned.append(s) }
        }
        samples = thinned
        save()
    }

    func add(_ balance: Double, at: Date) { merge([(at, balance)]) }

    /// Average credits used per day over the last `days`, ignoring top-ups.
    /// Needs at least 12 h of history; nil otherwise.
    func burnPerDay(days: Double = 7) -> Double? {
        let cutoff = Date().addingTimeInterval(-days * 86400)
        let window = samples.filter { $0.0 >= cutoff }
        guard let first = window.first, let last = window.last else { return nil }
        let span = last.0.timeIntervalSince(first.0)
        guard span >= 12 * 3600 else { return nil }
        let used = first.1 - last.1            // net; a top-up inside the window hides burn
        guard used >= 0 else { return nil }
        return used / (span / 86400)
    }

    private func save() {
        let arr = samples.map { [$0.0.timeIntervalSince1970, $0.1] }
        if let d = try? JSONSerialization.data(withJSONObject: arr) { try? d.write(to: url, options: .atomic) }
    }
}

final class Store: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var lastError: String?
    /// Set when Codex is missing or signed out; drives the setup message.
    @Published private(set) var setupIssue: Setup.Issue?
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var burnPerDay: Double?
    @Published private(set) var now = Date()
    @Published private(set) var isReading = false
    /// Bumped each time the dropdown opens; bars replay their fill.
    @Published private(set) var openToken = 0
    /// Bumped once when the headline crosses into a worse warning level.
    @Published private(set) var pulseToken = 0
    /// Debug-build proof hook: force the tile's hover presentation.
    @Published var debugHover = false
    private var lastLevel: Level?

    static let staleAfter: TimeInterval = 15 * 60
    let supportDir: URL
    private let history: CreditHistory
    private var lastLiveRead: Date?
    private var timer: Timer?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDir = base.appendingPathComponent("Gauge", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        history = CreditHistory(dir: supportDir)
    }

    var isStale: Bool {
        guard let s = snapshot else { return false }
        return s.source == .sessionLogs || now.timeIntervalSince(s.asOf) > Store.staleAfter
    }

    var pollInterval: TimeInterval {
        (snapshot?.headline?.remainingPercent ?? 100) <= 20 ? 60 : 300
    }

    func start() {
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private func tick() {
        now = Date()
        let due = lastAttempt.map { now.timeIntervalSince($0) >= pollInterval - 5 } ?? true
        if due { refresh() }
    }

    /// Animations only run while the dropdown is on screen; offscreen ones never settle.
    @Published private(set) var menuIsOpen = false
    func menuOpened() { menuIsOpen = true; openToken += 1 }
    func menuClosed() { menuIsOpen = false }

    func refreshIfOlder(than seconds: TimeInterval) {
        if let t = lastAttempt, Date().timeIntervalSince(t) < seconds { return }
        refresh()
    }

    func refresh() {
        guard !isReading else { return }
        isReading = true
        lastAttempt = Date()
        let seedHistory = history.isEmpty
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let started = Date()
            #if DEBUG
            // Test hook (debug builds only): `defaults write com.dohalloran.gauge debugSimulate logs|unavailable|left:NN`
            let simulate = UserDefaults.standard.string(forKey: "debugSimulate")
            #else
            let simulate: String? = nil
            #endif
            var result: Result<AppServer.Output, AppServer.Failure>
            if simulate == "logs" || simulate == "unavailable" {
                result = .failure(.rpc("simulated"))
            } else {
                result = AppServer.readRateLimits()
                if let sim = simulate, sim.hasPrefix("left:"), let left = Int(sim.dropFirst(5)),
                   case .success(var out) = result, var rl = out.rateLimits["rateLimits"] as? [String: Any],
                   var primary = rl["primary"] as? [String: Any] {
                    primary["usedPercent"] = 100 - left; rl["primary"] = primary
                    out.rateLimits["rateLimits"] = rl; out.rateLimits["rateLimitsByLimitId"] = ["codex": rl]
                    result = .success(out)
                }
            }
            var fallback: Snapshot? = nil
            var seed: [(Date, Double)] = []
            if case .failure = result, simulate != "unavailable" { fallback = SessionLogs.latestSnapshot() }
            if seedHistory { seed = SessionLogs.creditSamples(days: 7) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReading = false
                self.now = Date()
                if !seed.isEmpty { self.history.merge(seed) }
                switch result {
                case .success(let out):
                    let snap = Parse.live(out.rateLimits, at: Date())
                    self.snapshot = snap
                    self.lastLiveRead = snap.asOf
                    self.lastError = nil
                    self.setupIssue = nil
                    if let b = snap.creditsBalance { self.history.add(b, at: snap.asOf) }
                    Log.write(String(format: "read ok in %.2fs", Date().timeIntervalSince(started))
                              + " · " + snap.windows.map { "\($0.title) \($0.remainingPercent)% left resets \(Int($0.resetsAt?.timeIntervalSince1970 ?? 0))" }.joined(separator: ", ")
                              + " · banked \(snap.resetsAvailable.map(String.init) ?? "?") exp " + snap.resets.map { "\(Int($0.expiresAt?.timeIntervalSince1970 ?? 0))" }.joined(separator: "/")
                              + " · credits \(snap.creditsBalance.map { Fmt.number($0) } ?? "?")")
                case .failure(let e):
                    self.lastError = e.description
                    self.setupIssue = Setup.diagnose(e)
                    Log.write("read failed: \(e.description)")
                    // Keep a live snapshot until it is older than a newer log sample; otherwise use logs.
                    if simulate == "unavailable" { self.snapshot = nil }
                    if let fb = fallback, (self.snapshot == nil || fb.asOf > self.snapshot!.asOf || self.snapshot!.source == .live && simulate == "logs") {
                        self.snapshot = fb
                    }
                }
                self.burnPerDay = self.history.burnPerDay()
                let level = Level(remaining: self.snapshot?.headline?.remainingPercent)
                if let prev = self.lastLevel, level.severity > prev.severity { self.pulseToken += 1 }
                self.lastLevel = level
            }
        }
    }
}

enum Log {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Gauge/gauge.log")
    }()
    static func write(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
