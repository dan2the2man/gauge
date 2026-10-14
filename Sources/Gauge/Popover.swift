import AppKit
import SwiftUI
import Combine

/// State + actions the popover drives. Owned by AppController.
final class PopoverModel: ObservableObject {
    @Published var tileVisible = false
    @Published var tileLocked = false
    @Published var clickThrough = false
    @Published var loginOn = false
    var refresh: () -> Void = {}
    var openUsageSettings: () -> Void = {}
    var setTileVisible: (Bool) -> Void = { _ in }
    var setLocked: (Bool) -> Void = { _ in }
    var setClickThrough: (Bool) -> Void = { _ in }
    var resetTile: () -> Void = {}
    var toggleLogin: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var quit: () -> Void = {}
}

/// Popover colors: green above 25% left, orange 10–25%, red below 10%.
enum HeroLevel {
    static func color(_ remaining: Int) -> Color { remaining < 10 ? .red : (remaining <= 25 ? .orange : .green) }
}

/// Borderless glass panel that drops from the status item. Becomes key (for ⌘R, Tab, Esc)
/// without activating the app; closes on outside click, Esc, or a second status-item click.
final class PopoverPanel: NSPanel {
    var onClose: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onClose() }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "w" {
            onClose(); return true
        }
        return super.performKeyEquivalent(with: e)
    }
}

final class PopoverController {
    let panel: PopoverPanel
    private var monitors: [Any] = []
    private let hosting: NSHostingView<PopoverView>
    private let measurer: NSHostingView<PopoverView>
    private var bag = Set<AnyCancellable>()
    var isShown: Bool { panel.isVisible }
    var onShow: () -> Void = {}
    var onHide: () -> Void = {}

    init(store: Store, model: PopoverModel) {
        panel = PopoverPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        hosting = NSHostingView(rootView: PopoverView(store: store, model: model))
        hosting.sizingOptions = []
        measurer = NSHostingView(rootView: PopoverView(store: store, model: model))
        panel.contentView = hosting
        panel.onClose = { [weak self] in self?.hide() }
        // Keep the top edge pinned under the status item as content grows or shrinks.
        store.objectWillChange.merge(with: model.objectWillChange)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fit() } }
            .store(in: &bag)
    }

    func toggle(below button: NSStatusBarButton) { isShown ? hide() : show(below: button) }

    func show(below button: NSStatusBarButton) {
        onShow()
        let size = measurer.fittingSize
        guard let bw = button.window else { return }
        let b = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let vf = (bw.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = b.midX - size.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: b.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        button.highlight(true)
        let close: (NSEvent) -> Void = { [weak self] _ in self?.hide() }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: close)!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self else { return e }
            // Clicks inside the popover (or its gear menu) pass through; elsewhere closes.
            if e.window === self.panel || e.window?.level ?? .normal >= .popUpMenu && e.window !== button.window { return e }
            if e.window === button.window { return e }            // status item toggles itself
            self.hide(); return e
        } as Any)
        NotificationCenter.default.addObserver(self, selector: #selector(resignedKey), name: NSWindow.didResignKeyNotification, object: panel)
    }

    @objc private func resignedKey() {
        // Gear menu opening takes key briefly; only close if no menu is tracking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isShown, !self.panel.isKeyWindow, NSApp.windows.first(where: { $0.level == .popUpMenu && $0 !== self.panel && $0.isVisible }) == nil else { return }
            if NSApp.isActive { self.hide() }
        }
    }

    private func fit() {
        guard panel.isVisible else { return }
        let size = measurer.fittingSize
        guard size.height > 20, abs(size.height - panel.frame.height) > 0.5 else { return }
        var f = panel.frame
        f.origin.y = f.maxY - size.height; f.size = size
        panel.setFrame(f, display: true)
    }

    func hide() {
        guard panel.isVisible else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        panel.orderOut(nil)
        onHide()
    }
}

// MARK: view

struct PopoverView: View {
    @ObservedObject var store: Store
    @ObservedObject var model: PopoverModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let now = store.now
        let snap = store.snapshot
        VStack(alignment: .leading, spacing: 12) {
            header(snap, now: now)
            if let issue = store.setupIssue { setupCard(issue) }
            if let w = snap?.weekly { hero(w, now: now) } else { unavailableHero }
            ForEach(Array((snap?.shortWindows ?? []).enumerated()), id: \.offset) { _, w in shortWindow(w, now: now) }
            HStack(alignment: .top, spacing: 8) {
                banked(snap, now: now)
                credits(snap)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.6)
            tileDock
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            if reduceTransparency { shape.fill(Color(nsColor: .windowBackgroundColor)) }
            else { shape.fill(.ultraThinMaterial) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0.08), lineWidth: contrast == .increased ? 1 : 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // Header: title, freshness, icon buttons.
    private func header(_ snap: Snapshot?, now: Date) -> some View {
        HStack(spacing: 6) {
            Text(snap?.weekly?.title ?? "Weekly").font(.headline)
            Spacer(minLength: 4)
            freshness(snap, now: now)
            IconButton(symbol: "arrow.clockwise", label: "Refresh", help: "Refresh (⌘R)", spinning: store.isReading && !reduceMotion) { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
            IconButton(symbol: "arrow.up.forward.app", label: "Open Usage Settings", help: "Open Usage Settings (⌘,)") { model.openUsageSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Menu {
                Toggle("Open at Login", isOn: Binding(get: { model.loginOn }, set: { _ in model.toggleLogin() }))
                Button("Check for Updates…") { model.checkForUpdates() }
                Divider()
                Button("Quit Gauge") { model.quit() }.keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 24, height: 24)
            .help("More")
            .accessibilityLabel("More options")
        }
    }

    @ViewBuilder
    private func freshness(_ snap: Snapshot?, now: Date) -> some View {
        if let s = snap {
            if store.isStale {
                Label(s.source == .sessionLogs ? "Logs, \(Fmt.asOf(s.asOf, now: now))" : relative(s.asOf, now: now),
                      systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption).foregroundStyle(.orange)
                    .help(store.lastError.map { "Stale. Last read failed: \($0)" } ?? "Stale reading")
                    .accessibilityLabel("Stale, as of \(Fmt.exact(s.asOf))")
            } else {
                Text("As of \(s.asOf.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("As of \(s.asOf.formatted(date: .abbreviated, time: .standard))")
            }
        } else if store.lastError != nil {
            Text("Couldn’t reach Codex").font(.caption).foregroundStyle(.orange)
        } else {
            Text("Reading…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func relative(_ d: Date, now: Date) -> String {
        let m = Int(now.timeIntervalSince(d) / 60)
        return m < 60 ? "\(max(m, 1))m ago" : "\(m / 60)h ago"
    }

    private func hero(_ w: UsageWindow, now: Date) -> some View {
        let color = HeroLevel.color(w.remainingPercent)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(w.remainingPercent)%")
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(store.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(w.remainingPercent)))
                Text("left").font(.title3).foregroundStyle(.secondary)
                if w.remainingPercent < 10 {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        .font(.title3).accessibilityLabel("Low")
                        .help("Under 10% left")
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(w.title) usage")
            .accessibilityValue("\(w.remainingPercent) percent left")
            HeroBar(remaining: w.remainingPercent, color: color)
            if let r = w.resetsAt {
                Label("Resets \(Fmt.moment(r, now: now)) · in \(Fmt.countdown(to: r, now: now) ?? "–")", systemImage: "clock")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("Resets \(Fmt.exact(r))")
            }
        }
    }

    private var unavailableHero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Unavailable").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            Text("Gauge never shows 0 when it can’t read usage.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func shortWindow(_ w: UsageWindow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(w.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(w.remainingPercent)% left").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            HeroBar(remaining: w.remainingPercent, color: HeroLevel.color(w.remainingPercent), height: 4)
        }
        .accessibilityElement(children: .combine)
    }

    private func setupCard(_ issue: Setup.Issue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(issue.title, systemImage: "exclamationmark.triangle").font(.subheadline.weight(.semibold))
            Text(issue.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    private func banked(_ s: Snapshot?, now: Date) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Banked resets").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(s?.resetsAvailable.map(String.init) ?? "–").font(.caption.weight(.semibold).monospacedDigit())
            }
            if let s, s.source == .live, !s.resets.isEmpty {
                FlowPills(resets: Array(s.resets.prefix(6)), now: now)
            } else {
                Text(s?.source == .live ? "None" : "Unavailable").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Banked resets, \(s?.resetsAvailable.map(String.init) ?? "unavailable")")
    }

    private func credits(_ s: Snapshot?) -> some View {
        Card {
            Text("Credits").font(.caption).foregroundStyle(.secondary)
            Text(creditsText(s)).font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            if let s, s.creditsBalance != nil, !s.creditsUnlimited, let b = store.burnPerDay {
                Text("~\(Fmt.number(b)) / day").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("Average over the last week")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func creditsText(_ s: Snapshot?) -> String {
        guard let s else { return "–" }
        if s.creditsUnlimited { return "Unlimited" }
        return s.creditsBalance.map { Fmt.number($0) } ?? "–"
    }

    private var tileDock: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { model.tileVisible }, set: { model.setTileVisible($0) })) {
                Label("Desktop Tile", systemImage: "macwindow")
            }
            .toggleStyle(PillToggleStyle())
            .help(model.tileVisible ? "Hide the desktop tile" : "Show the desktop tile")
            Spacer()
            Group {
                Toggle(isOn: Binding(get: { model.tileLocked }, set: { model.setLocked($0) })) {
                    Image(systemName: model.tileLocked ? "lock.fill" : "lock.open")
                }
                .toggleStyle(IconToggleStyle())
                .help(model.tileLocked ? "Unlock tile position" : "Lock tile position")
                .accessibilityLabel("Lock Tile Position")
                Toggle(isOn: Binding(get: { model.clickThrough }, set: { model.setClickThrough($0) })) {
                    Image(systemName: model.clickThrough ? "cursorarrow.slash" : "cursorarrow.rays")
                }
                .toggleStyle(IconToggleStyle())
                .help(model.clickThrough ? "Tile ignores clicks (on)" : "Tile ignores clicks (off)")
                .accessibilityLabel("Tile Ignores Clicks")
                IconButton(symbol: "scope", label: "Reset Tile Position", help: "Reset tile position") { model.resetTile() }
            }
            .disabled(!model.tileVisible)
            .opacity(model.tileVisible ? 1 : 0.35)
        }
    }
}

// MARK: pieces

struct HeroBar: View {
    var remaining: Int
    var color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color)
                    .frame(width: remaining > 0 ? max(height, g.size.width * CGFloat(min(remaining, 100)) / 100) : 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) { content }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// Date pills that wrap onto new lines. Orange when expiring within 3 days.
struct FlowPills: View {
    var resets: [BankedReset]
    var now: Date
    var body: some View {
        let rows = stride(from: 0, to: resets.count, by: 2).map { Array(resets[$0..<min($0 + 2, resets.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 4) { ForEach(rows[i]) { pill($0) } }
            }
        }
    }
    private func pill(_ r: BankedReset) -> some View {
        let soon = r.expiresAt.map { $0.timeIntervalSince(now) < 3 * 86400 } ?? false
        let text = r.expiresAt.map(Fmt.shortDay) ?? "No expiry"
        return Text(text)
            .font(.caption2.weight(.medium).monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(soon ? Color.orange : Color.primary.opacity(0.8))
            .background(Capsule().fill(soon ? Color.orange.opacity(0.2) : Color.primary.opacity(0.09)))
            .help(r.expiresAt.map { "Expires \(Fmt.exact($0))" } ?? "No expiry date")
            .accessibilityLabel(r.expiresAt.map { "Reset expires \(Fmt.exact($0))\(soon ? ", soon" : "")" } ?? "Reset, no expiry")
    }
}

struct IconButton: View {
    var symbol: String
    var label: String
    var help: String
    var spinning = false
    var action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover.value ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration c: Configuration) -> some View {
        Button { c.isOn.toggle() } label: {
            c.label.font(.callout.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(c.isOn ? Color.accentColor : .secondary)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(c.isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(c.isOn ? "On" : "Off")
        .accessibilityAddTraits(c.isOn ? .isSelected : [])
    }
}

struct IconToggleStyle: ToggleStyle {
    func makeBody(configuration c: Configuration) -> some View {
        Button { c.isOn.toggle() } label: {
            c.label.font(.system(size: 13, weight: .medium))
                .foregroundStyle(c.isOn ? Color.accentColor : .primary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(c.isOn ? Color.accentColor.opacity(0.18) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(c.isOn ? "On" : "Off")
        .accessibilityAddTraits(c.isOn ? .isSelected : [])
    }
}
