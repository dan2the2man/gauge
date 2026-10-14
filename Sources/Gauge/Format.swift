import Foundation
import SwiftUI
import AppKit

enum Fmt {
    static func countdown(to date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    /// "Tue 10:28 PM" within a week, otherwise "Oct 22, 4:04 PM".
    static func moment(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 99
        if days == 1 { return "Tomorrow " + date.formatted(date: .omitted, time: .shortened) }
        if days == -1 { return "Yesterday " + date.formatted(date: .omitted, time: .shortened) }
        if abs(days) < 7 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// "Tue, Oct 13 at 10:28 PM"
    static func exact(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    static func shortDay(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }

    static func number(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0))) }

    static func asOf(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : moment(date, now: now)
    }
}

enum Level: Equatable {
    case normal, warn, critical
    /// Warnings are keyed to what is left: orange at 20% left, red at 5% left.
    init(remaining: Int?) {
        guard let r = remaining else { self = .normal; return }
        self = r <= 5 ? .critical : (r <= 20 ? .warn : .normal)
    }
    var severity: Int { switch self { case .normal: return 0; case .warn: return 1; case .critical: return 2 } }
    var color: Color? {
        switch self { case .normal: return nil; case .warn: return .orange; case .critical: return .red }
    }
    var nsColor: NSColor? {
        switch self { case .normal: return nil; case .warn: return .systemOrange; case .critical: return .systemRed }
    }
}
