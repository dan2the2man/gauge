import Foundation
import AppKit
import Combine

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
            // Parse off the main thread; an unrecognized response is a failure, never an empty snapshot.
            var parsed: Result<Snapshot, AppServer.Failure>
            switch result {
            case .success(let out):
                parsed = Parse.live(out.rateLimits, at: Date()).map { .success($0) }
                    ?? .failure(.rpc("unrecognized rateLimits response"))
            case .failure(let e): parsed = .failure(e)
            }
            var fallback: Snapshot? = nil
            var seed: [(Date, Double)] = []
            if case .failure = parsed, simulate != "unavailable" { fallback = SessionLogs.latestSnapshot() }
            if seedHistory { seed = SessionLogs.creditSamples(days: 7) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReading = false
                self.now = Date()
                if !seed.isEmpty { self.history.merge(seed) }
                switch parsed {
                case .success(let snap):
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
