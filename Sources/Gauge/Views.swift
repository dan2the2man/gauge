import SwiftUI
import Combine

/// View-local state without the @State macro (the Command Line Tools ship no SwiftUI macro plugin).
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}

// MARK: motion

enum Motion {
    /// Short, critically-damped-ish spring used for every value change.
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Slightly slower spring for the bar filling in when the menu opens.
    static let fill = Animation.spring(response: 0.55, dampingFraction: 0.9)
    static func ifAllowed(_ a: Animation, _ reduce: Bool) -> Animation? { reduce ? nil : a }
}

// MARK: shared pieces

/// Remaining-capacity bar: full when fresh, drains as usage grows.
struct UsageBar: View {
    var remaining: Int
    var replayToken: Int = 0
    var animate = true
    var fillOnAppear = false
    var height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0→1 reveal used only for the fill-in when the menu opens; the value itself is always current.
    @StateObject private var reveal = Box<Double>(1)

    private var fraction: CGFloat { CGFloat(min(max(remaining, 0), 100)) / 100 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Level(remaining: remaining).color ?? Color.accentColor)
                    .frame(width: fraction > 0 ? max(height, geo.size.width * fraction) : 0)
                    .scaleEffect(x: reveal.value, y: 1, anchor: .leading)
            }
        }
        .frame(height: height)
        .animation(animate ? Motion.ifAllowed(Motion.spring, reduceMotion) : nil, value: remaining)
        .onChange(of: replayToken) { _, _ in fillIn() }
        .onAppear { if fillOnAppear { fillIn() } }
        .accessibilityElement()
        .accessibilityLabel("\(remaining) percent left")
    }

    private func fillIn() {
        guard !reduceMotion, animate else { reveal.value = 1; return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { reveal.value = 0.001 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(Motion.fill) { reveal.value = 1 }
        }
    }
}

/// Percent with a rolling-digit transition and a single soft pulse when a threshold is crossed.
struct PercentText: View {
    var value: Int
    var font: Font
    var color: Color?
    var dimmed = false
    var pulseToken: Int
    var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var pulseBox = Box(false)

    var body: some View {
        Text("\(value)%")
            .font(font.monospacedDigit())
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(color ?? .primary))
            .contentTransition(reduceMotion || !animate ? .identity : .numericText(value: Double(value)))
            .animation(animate ? Motion.ifAllowed(Motion.spring, reduceMotion) : nil, value: value)
            .scaleEffect(pulseBox.value ? 1.07 : 1, anchor: .leading)
            .onChange(of: pulseToken) { _, _ in
                guard !reduceMotion, animate else { return }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { pulseBox.value = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { pulseBox.value = false }
                }
            }
    }
}

/// Small arrow that turns only while a read is in flight. Nothing animates at idle.
struct ReadingIndicator: View {
    @ObservedObject var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if store.isReading {
            Group {
                if #available(macOS 15.0, *), !reduceMotion {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .symbolEffect(.rotate, options: .speed(1.4), isActive: true)
                } else {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                }
            }
            .foregroundStyle(.secondary)
            .transition(.opacity)
            .accessibilityLabel("Updating")
        }
    }
}

struct FreshnessLine: View {
    @ObservedObject var store: Store
    var exact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let now = store.now
        HStack(spacing: 5) {
            if let s = store.snapshot {
                if store.isStale {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(s.source == .sessionLogs
                         ? "Stale · session logs, \(Fmt.asOf(s.asOf, now: now))"
                         : "Stale · last read \(Fmt.asOf(s.asOf, now: now))")
                } else {
                    Text(exact ? "As of \(s.asOf.formatted(date: .omitted, time: .standard))"
                               : "As of \(Fmt.asOf(s.asOf, now: now))")
                }
            } else if store.lastAttempt != nil, store.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn’t reach Codex · retrying")
            } else {
                Text("Reading…")
            }
            ReadingIndicator(store: store)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: store.isReading)
        .help(store.lastError.map { "Last read failed: \($0)" } ?? "")
    }
}

struct ResetChip: View {
    var reset: BankedReset
    var now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hoverBox = Box(false)

    var body: some View {
        let soon = reset.expiresAt.map { $0.timeIntervalSince(now) < 7 * 86400 } ?? false
        let label = reset.expiresAt.map { d -> String in
            soon ? "\(Fmt.shortDay(d)) · \(Fmt.countdown(to: d, now: now) ?? "")" : Fmt.shortDay(d)
        } ?? "No expiry"
        let base = soon ? Color.orange : Color.primary
        Text(label)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(soon ? Color.orange : Color.primary)
            .background(Capsule().fill(base.opacity(hoverBox.value ? (soon ? 0.26 : 0.14) : (soon ? 0.16 : 0.07))))
            .onHover { h in hoverBox.value = h }
            .help(reset.expiresAt.map { "Expires \(Fmt.exact($0))" } ?? "No expiry")
            .accessibilityLabel(reset.expiresAt.map { "Banked reset, expires \(Fmt.exact($0))" } ?? "Banked reset")
    }
}

// MARK: dropdown

struct MenuPanel: View {
    @ObservedObject var store: Store

    var body: some View {
        let now = store.now
        let snap = store.snapshot
        VStack(alignment: .leading, spacing: 14) {
            if let issue = store.setupIssue {
                VStack(alignment: .leading, spacing: 4) {
                    Label(issue.title, systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                    Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let w = snap?.weekly {
                windowSection(w, now: now)
            } else {
                unavailableRow("Weekly")
            }
            ForEach(Array((snap?.shortWindows ?? []).enumerated()), id: \.offset) { _, w in
                windowSection(w, now: now)
            }
            if let snap, snap.source == .live { resetsSection(snap, now: now) }
            creditsSection(snap)
            FreshnessLine(store: store)
        }
        .padding(.leading, 30)       // aligns with the menu item titles below
        .padding(.trailing, 18)      // aligns with the key-equivalent column
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: 316, alignment: .leading)
    }

    @ViewBuilder
    private func windowSection(_ w: UsageWindow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(w.title).font(.subheadline.weight(.semibold))
                Spacer()
                PercentText(value: w.remainingPercent, font: .subheadline,
                            color: Level(remaining: w.remainingPercent).color ?? .secondary,
                            dimmed: store.isStale, pulseToken: store.pulseToken, animate: false)
                Text("left").font(.subheadline).foregroundStyle(.secondary)
            }
            // Menus render statically, like every native menu: SwiftUI animations don't tick
            // while AppKit tracks a menu, so the dropdown shows final values only.
            UsageBar(remaining: w.remainingPercent, animate: false)
            if let r = w.resetsAt {
                Text("Resets \(Fmt.moment(r, now: now)) · in \(Fmt.countdown(to: r, now: now) ?? "–")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Resets \(Fmt.exact(r))")
            }
        }
    }

    private func unavailableRow(_ title: String) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text("Unavailable").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resetsSection(_ s: Snapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Banked resets").font(.subheadline.weight(.semibold))
                Spacer()
                Text(s.resetsAvailable.map { "\($0)" } ?? "Unavailable")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !s.resets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(s.resets.prefix(4)) { ResetChip(reset: $0, now: now) }
                }
                Text("Expiry dates").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func creditsSection(_ s: Snapshot?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Credits").font(.subheadline.weight(.semibold))
                Spacer()
                Text(creditsText(s))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)

            }
            if let s, s.creditsBalance != nil, !s.creditsUnlimited, let b = store.burnPerDay {
                Text("About \(Fmt.number(b)) a day over the last week")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func creditsText(_ s: Snapshot?) -> String {
        guard let s else { return "Unavailable" }
        if s.creditsUnlimited { return "Unlimited" }
        return s.creditsBalance.map { Fmt.number($0) } ?? "Unavailable"
    }
}

// MARK: desktop tile

struct TileView: View {
    @ObservedObject var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hoverBox = Box(false)

    var body: some View {
        let now = store.now
        let snap = store.snapshot
        let detail = hoverBox.value || store.debugHover
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Codex").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(snap?.weekly?.title ?? "Weekly").font(.caption).foregroundStyle(.secondary)
            }
            if let w = snap?.weekly {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    PercentText(value: w.remainingPercent,
                                font: .system(.title, design: .rounded).weight(.semibold),
                                color: Level(remaining: w.remainingPercent).color,
                                dimmed: store.isStale, pulseToken: store.pulseToken)
                    Text("left").font(.callout).foregroundStyle(.secondary)
                }
                UsageBar(remaining: w.remainingPercent, fillOnAppear: true)
                if let r = w.resetsAt {
                    ZStack(alignment: .leading) {
                        if detail {
                            Text("Resets \(Fmt.exact(r))").lineLimit(1).minimumScaleFactor(0.85).transition(.opacity)
                        } else {
                            Text("Resets in \(Fmt.countdown(to: r, now: now) ?? "–")")
                                .contentTransition(.numericText())
                                .transition(.opacity)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("Unavailable").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(Array((snap?.shortWindows ?? []).enumerated()), id: \.offset) { _, w in
                HStack {
                    Text(w.title).font(.caption)
                    Spacer()
                    Text("\(w.remainingPercent)% left").font(.caption.monospacedDigit())
                        .foregroundStyle(Level(remaining: w.remainingPercent).color ?? .secondary)
                        .contentTransition(.numericText(value: Double(w.remainingPercent)))
                }
            }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 3) {
                if let s = snap, s.source == .live {
                    let soon = s.resets.first?.expiresAt.map { $0.timeIntervalSince(now) < 7 * 86400 } ?? false
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text(resetsLine(s))
                    }
                    .foregroundStyle(soon ? Color.orange : Color.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "creditcard")
                    Text(creditsLine(snap))
                        .contentTransition(.numericText(value: snap?.creditsBalance ?? 0))
                }
                .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            // Space is always reserved so hovering never changes the tile's size.
            FreshnessLine(store: store, exact: detail)
                .font(.caption2)
                .opacity(detail || store.isStale || snap == nil || store.isReading ? 1 : 0)
        }
        .padding(14)
        .frame(width: 196, alignment: .leading)
        .animation(Motion.ifAllowed(Motion.spring, reduceMotion) ?? .linear(duration: 0), value: detail)
        .animation(Motion.ifAllowed(Motion.spring, reduceMotion), value: snap?.weekly?.remainingPercent)
        .contentShape(Rectangle())
        .onHover { h in hoverBox.value = h }
    }

    private func resetsLine(_ s: Snapshot) -> String {
        guard let n = s.resetsAvailable else { return "Resets unavailable" }
        let base = n == 1 ? "1 reset" : "\(n) resets"
        guard let d = s.resets.first?.expiresAt else { return base }
        return "\(base) · next \(Fmt.shortDay(d))"
    }

    private func creditsLine(_ s: Snapshot?) -> String {
        guard let s else { return "Credits unavailable" }
        if s.creditsUnlimited { return "Unlimited credits" }
        guard let b = s.creditsBalance else { return "Credits unavailable" }
        return "\(Fmt.number(b)) credits"
    }
}
