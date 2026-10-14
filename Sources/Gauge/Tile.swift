import AppKit
import SwiftUI
import Combine

private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }   // TilePanel drags itself
}

/// Moves itself on mouse drags. Window-server dragging (isMovableByWindowBackground /
/// mouseDownCanMoveWindow) never engages for this non-activating, never-key panel at desktop
/// level under SwiftUI content, so the drag is tracked here explicitly.
final class TilePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var isLocked: () -> Bool = { false }
    var didFinishDrag: () -> Void = {}

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, !isLocked() else { return super.sendEvent(event) }
        trackDrag(from: event)
    }

    /// Screen position of a mouse event, independent of where the window has moved since.
    private func screenPoint(_ e: NSEvent, origin: NSPoint) -> NSPoint {
        NSPoint(x: origin.x + e.locationInWindow.x, y: origin.y + e.locationInWindow.y)
    }

    private func trackDrag(from down: NSEvent) {
        let startOrigin = frame.origin
        let startMouse = screenPoint(down, origin: startOrigin)
        var moved = false
        while let e = nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let p = screenPoint(e, origin: frame.origin)
            let dx = p.x - startMouse.x, dy = p.y - startMouse.y
            if !moved, hypot(dx, dy) < 3 { if e.type == .leftMouseUp { break } else { continue } }
            moved = true
            setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            if e.type == .leftMouseUp { break }
        }
        if moved { didFinishDrag() } else { super.sendEvent(down) }
    }
}

/// A small glass tile that lives at desktop level: below every window, on all Spaces,
/// never in Cmd-Tab or Mission Control's window list.
final class TileController {
    private let panel: TilePanel
    private let store: Store
    private var hosting: NSView!
    private lazy var measurer = NSHostingView(rootView: TileView(store: store))
    private var sizeObserver: Any?
    private static let frameKey = "tileTopLeft"
    static let lockKey = "tileLocked"

    init(store: Store) {
        self.store = store
        panel = TilePanel(contentRect: NSRect(x: 0, y: 0, width: 196, height: 200),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isMovableByWindowBackground = false
        panel.isLocked = { UserDefaults.standard.bool(forKey: TileController.lockKey) }
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

        panel.didFinishDrag = { [weak self] in self?.clampToVisible(); self?.savePosition() }
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
    var frame: NSRect { panel.frame }

    #if DEBUG
    /// Self-test: feeds a synthetic down → drags → up through the panel's real event path.
    func simulateDrag(dx: CGFloat, dy: CGFloat) {
        let o = panel.frame.origin
        let start = NSPoint(x: 40, y: panel.frame.height - 30)       // window coords
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Window-relative points computed against the ORIGINAL origin, as the window server would
        // for a cursor moving across a window that is itself moving.
        var origin = o
        for i in 1...10 {
            let target = NSPoint(x: o.x + start.x + dx * CGFloat(i) / 10, y: o.y + start.y + dy * CGFloat(i) / 10)
            origin = NSPoint(x: o.x + dx * CGFloat(i - 1) / 10, y: o.y + dy * CGFloat(i - 1) / 10)
            NSApp.postEvent(ev(i == 10 ? .leftMouseUp : .leftMouseDragged,
                               NSPoint(x: target.x - origin.x, y: target.y - origin.y)), atStart: false)
        }
        panel.sendEvent(ev(.leftMouseDown, start))
    }
    #endif

    /// Menu: Reset Tile Position.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.frameKey)
        restorePosition()
    }
    var windowNumber: Int { panel.windowNumber }

    func setVisible(_ on: Bool) { on ? panel.orderFrontRegardless() : panel.orderOut(nil) }
    func setClickThrough(_ on: Bool) { panel.ignoresMouseEvents = on }

    private func restorePosition() {
        if let s = UserDefaults.standard.string(forKey: Self.frameKey) {
            panel.setFrameTopLeftPoint(NSPointFromString(s))
            keepOnScreen()
            clampToVisible()
            return
        }
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: vf.maxX - panel.frame.width - 24, y: vf.maxY - 24))
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)), forKey: Self.frameKey)
    }

    /// Pull the tile fully inside the visible frame of the screen it is mostly on.
    private func clampToVisible() {
        var f = panel.frame
        let screen = NSScreen.screens.max { $0.visibleFrame.intersection(f).area < $1.visibleFrame.intersection(f).area }
        guard let vf = screen?.visibleFrame else { return }
        f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.origin.y, vf.minY), vf.maxY - f.height)
        if f.origin != panel.frame.origin { panel.setFrameOrigin(f.origin) }
    }

    private func keepOnScreen() {
        let f = panel.frame
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) { return }
        UserDefaults.standard.removeObject(forKey: Self.frameKey)
        restorePosition()
    }
}

private extension NSRect { var area: CGFloat { isNull ? 0 : width * height } }
