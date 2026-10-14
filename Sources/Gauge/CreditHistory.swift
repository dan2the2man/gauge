import Foundation

/// Balance samples → recent burn. Stored locally (time + balance only).
final class CreditHistory {
    /// Samples are thinned to the newest one per fixed bucket of this many seconds.
    static let bucket: TimeInterval = 600
    static let keep: TimeInterval = 8 * 86400
    private(set) var samples: [(Date, Double)] = []
    private let url: URL

    init(dir: URL) {
        url = dir.appendingPathComponent("credits.json")
        if let d = try? Data(contentsOf: url), let arr = try? JSONSerialization.jsonObject(with: d) as? [[Double]] {
            samples = arr.compactMap { $0.count == 2 && $0[0].isFinite && $0[1].isFinite
                ? (Date(timeIntervalSince1970: $0[0]), $0[1]) : nil }
        }
    }

    var isEmpty: Bool { samples.isEmpty }

    func merge(_ new: [(Date, Double)], now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.keep)
        // One sample per fixed time bucket (floor(t / bucket)); the newest reading in a bucket wins.
        // Fixed buckets, unlike "replace if < 10 min since the last kept sample", let steady
        // 5-minute polling accumulate one sample every 10 minutes.
        var byBucket: [Int64: (Date, Double)] = [:]
        for s in samples + new where s.0 >= cutoff {
            let k = Int64((s.0.timeIntervalSince1970 / Self.bucket).rounded(.down))
            if let cur = byBucket[k], cur.0 > s.0 { continue }
            byBucket[k] = s
        }
        samples = byBucket.values.sorted { $0.0 < $1.0 }
        save()
    }

    func add(_ balance: Double, at: Date) { merge([(at, balance)], now: max(at, Date())) }

    /// Average credits used per day over the last `days`, ignoring top-ups.
    /// Needs at least 12 h of history; nil otherwise.
    func burnPerDay(days: Double = 7, now: Date = Date()) -> Double? {
        let cutoff = now.addingTimeInterval(-days * 86400)
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
