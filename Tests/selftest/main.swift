// Plain-Swift self-test (no XCTest needed; runs with Command Line Tools). Run: scripts/selftest.sh
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }
let now = Date()

// Parser: hostile numbers never trap; unrecognized responses yield nil, not an empty live snapshot.
check(Parse.window(["usedPercent": 1e100]) == nil, "usedPercent 1e100 rejected without trapping")
check(Parse.window(["usedPercent": Double.nan]) == nil, "usedPercent NaN rejected")
check(Parse.window(["usedPercent": 37, "windowDurationMins": 1e300, "resetsAt": -1e200])?.usedPercent == 37,
      "huge minutes / reset dropped, valid percent kept")
check(Parse.window(["usedPercent": 104])?.remainingPercent == 0, "small overshoot clamped")
check(Parse.live([:], at: now) == nil, "empty response → nil")
check(Parse.live(["something": "else"], at: now) == nil, "unrecognized response → nil")
check(Parse.live(["rateLimits": ["primary": ["usedPercent": "x"]]], at: now) == nil, "no valid window → nil")
check(Parse.live(["rateLimits": ["primary": ["usedPercent": 40, "windowDurationMins": 10080]],
                  "rateLimitResetCredits": ["availableCount": 1e100]], at: now)?.resetsAvailable == nil,
      "huge availableCount dropped")
check(Parse.live(["rateLimits": ["primary": ["usedPercent": 40, "windowDurationMins": 10080]]], at: now)?
      .weekly?.remainingPercent == 60, "valid response parses")

// Auth errors are recognized from the RPC message alone.
check(Parse.isAuthError("Not signed in"), "'Not signed in' is an auth error")
check(Parse.isAuthError("401 Unauthorized"), "'401 Unauthorized' is an auth error")
check(!Parse.isAuthError("timed out"), "'timed out' is not an auth error")

// Credit history: 24 h of 5-minute polls accumulates samples and yields a burn estimate.
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gauge-selftest-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let h = CreditHistory(dir: dir)
let start = now.addingTimeInterval(-24 * 3600)
for i in 0...(24 * 12) {                       // every 5 minutes, burning 0.5 credits per poll
    h.merge([(start.addingTimeInterval(Double(i) * 300), 1000 - Double(i) * 0.5)], now: now)
}
print("     24h of 5-min polls → \(h.samples.count) samples, burn \(h.burnPerDay(now: now).map { String(format: "%.1f", $0) } ?? "nil")/day")
check(h.samples.count >= 140, "history accumulates (~1 sample per 10 min)")
if let b = h.burnPerDay(now: now) { check(abs(b - 144) < 2, "burn estimate ≈ 144/day") } else { check(false, "burn estimate exists") }

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
