import AppKit
import SwiftUI
import Combine

private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class TilePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A small glass tile that lives at desktop level: below every window, on all Spaces,
/// never in Cmd-Tab or Mission Control's window list.
final class TileController {
    private let panel: NSPanel
    private let store: Store
    private var hosting: NSView!
    private lazy var measurer = NSHostingView(rootView: TileView(store: store))
    private var sizeObserver: Any?
    private static let frameKey = "tileTopLeft"

    init(store: Store) {
        self.store = store
        panel = TilePanel(contentRect: NSRect(x: 0, y: 0, width: 196, height: 200),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true

        let hosting = DraggableHostingView(rootView: TileView(store: store))
        hosting.sizingOptions = []
        self.hosting = hosting
        let container: NSView
        if #available(macOS 26.0, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            glass.contentView = hosting
            container = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .popover
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 22
            fx.layer?.cornerCurve = .continuous
            fx.layer?.masksToBounds = true
            hosting.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: fx.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            ])
            container = fx
        }
        panel.contentView = container
        fitToContent(anchorTop: false)
        restorePosition()
        sizeObserver = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitToContent(anchorTop: true) }
        }

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            self?.savePosition()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keepOnScreen()
        }
    }

    /// Resize the panel to the SwiftUI content, keeping the top edge where the user put it.
    private func fitToContent(anchorTop: Bool) {
        let target = measurer.fittingSize
        guard target.width > 20, target.height > 20 else { return }
        var f = panel.frame
        if abs(f.size.width - target.width) < 0.5, abs(f.size.height - target.height) < 0.5 { return }
        let top = f.maxY
        f.size = target
        if anchorTop { f.origin.y = top - target.height }
        panel.setFrame(f, display: true)
    }

    var frameDescription: String { NSStringFromRect(panel.frame) + " fit=" + NSStringFromSize(measurer.fittingSize) }
    var isVisible: Bool { panel.isVisible }
    func move(to topLeft: NSPoint) {
        guard let screen = NSScreen.main else { return }
        panel.setFrameTopLeftPoint(NSPoint(x: topLeft.x, y: screen.frame.maxY - topLeft.y))
    }
    var windowNumber: Int { panel.windowNumber }

    func setVisible(_ on: Bool) { on ? panel.orderFrontRegardless() : panel.orderOut(nil) }
    func setClickThrough(_ on: Bool) { panel.ignoresMouseEvents = on }

    private func restorePosition() {
        if let s = UserDefaults.standard.string(forKey: Self.frameKey) {
            let p = NSPointFromString(s)
            panel.setFrameTopLeftPoint(p)
            keepOnScreen()
            return
        }
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: vf.maxX - panel.frame.width - 24, y: vf.maxY - 24))
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)), forKey: Self.frameKey)
    }

    private func keepOnScreen() {
        let f = panel.frame
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) { return }
        UserDefaults.standard.removeObject(forKey: Self.frameKey)
        restorePosition()
    }
}
