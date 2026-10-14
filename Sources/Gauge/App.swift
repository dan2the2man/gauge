import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Sparkle

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var panelItem: NSMenuItem!
    private var hosting: NSHostingView<MenuPanel>!
    private var tile: TileController!
    private var tileItem: NSMenuItem!
    private var lockItem: NSMenuItem!
    private var resetTileItem: NSMenuItem!
    private var clickItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var bag = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard
    /// Sparkle 2. Feed URL and public EdDSA key live in Info.plist (SUFeedURL / SUPublicEDKey).
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var shownSetupAlert = false

    func applicationDidFinishLaunching(_ note: Notification) {
        signal(SIGPIPE, SIG_IGN)
        applyAppearance(defaults.string(forKey: "appearance"))
        defaults.register(defaults: ["showTile": true, "tileClickThrough": false])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "GaugeStatusItem"
        buildMenu()
        statusItem.menu = menu

        tile = TileController(store: store)
        tile.setClickThrough(defaults.bool(forKey: "tileClickThrough"))
        tile.setVisible(defaults.bool(forKey: "showTile"))

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.render(); self?.maybeShowSetupAlert() } }
            .store(in: &bag)
        render()
        store.start()

        if !defaults.bool(forKey: "loginConfigured") {
            defaults.set(true, forKey: "loginConfigured")
            try? SMAppService.mainApp.register()
        }

        #if DEBUG
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(debugCommand(_:)),
                                                            name: .init("com.dohalloran.gauge.debug"), object: nil)
        #endif
    }

    /// First launch (and until fixed): explain plainly when Codex is missing or signed out.
    private func maybeShowSetupAlert() {
        guard !shownSetupAlert, let issue = store.setupIssue else { return }
        shownSetupAlert = true
        let key = "setupAlertShown." + (issue == .codexMissing ? "missing" : "signedOut")
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = issue.title
        alert.informativeText = issue.detail + "\n\nGauge stays in your menu bar and picks up your usage as soon as Codex is ready."
        alert.addButton(withTitle: "OK")
        if issue == .codexMissing { alert.addButton(withTitle: "Get Codex") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let u = URL(string: "https://developers.openai.com/codex") {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: menu bar

    private func render() {
        guard let button = statusItem.button else { return }
        let snap = store.snapshot
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        if let w = snap?.headline {
            var text = "\(w.remainingPercent)% left"
            if let c = Fmt.countdown(to: w.resetsAt, now: store.now) { text += " · \(c)" }
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            if let c = Level(remaining: w.remainingPercent).nsColor { attrs[.foregroundColor] = c }
            button.image = nil
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
            button.appearsDisabled = store.isStale
            button.toolTip = store.isStale ? "Codex usage (stale)" : "Codex usage"
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                                   accessibilityDescription: "Codex usage unavailable")
            button.image?.isTemplate = true
            button.appearsDisabled = true
            button.toolTip = "Codex usage unavailable"
        }
        if let h = hosting {
            let size = h.fittingSize
            if h.frame.size != size { h.setFrameSize(size) }
        }
    }

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        hosting = NSHostingView(rootView: MenuPanel(store: store))
        hosting.setFrameSize(hosting.fittingSize)
        panelItem = NSMenuItem()
        panelItem.view = hosting
        menu.addItem(panelItem)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Usage Settings…", action: #selector(openUsageSettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())

        tileItem = NSMenuItem(title: "Show Desktop Tile", action: #selector(toggleTile), keyEquivalent: "")
        tileItem.target = self
        menu.addItem(tileItem)
        clickItem = NSMenuItem(title: "Tile Ignores Clicks", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickItem.target = self
        menu.addItem(clickItem)
        lockItem = NSMenuItem(title: "Lock Tile Position", action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self
        menu.addItem(lockItem)
        resetTileItem = NSMenuItem(title: "Reset Tile Position", action: #selector(resetTile), keyEquivalent: "")
        resetTileItem.target = self
        menu.addItem(resetTileItem)
        loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let upd = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        upd.target = updater
        menu.addItem(upd)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Gauge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        tileItem.state = tile.isVisible ? .on : .off
        clickItem.state = defaults.bool(forKey: "tileClickThrough") ? .on : .off
        clickItem.isEnabled = tile.isVisible
        lockItem.state = defaults.bool(forKey: TileController.lockKey) ? .on : .off
        lockItem.isEnabled = tile.isVisible
        resetTileItem.isEnabled = tile.isVisible
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        store.menuOpened()
        store.refreshIfOlder(than: 60)
        render()
    }

    func menuDidClose(_ menu: NSMenu) { store.menuClosed() }

    // MARK: actions

    /// Only navigates; the app itself decides everything about resets and credits.
    @objc private func openUsageSettings() {
        if let url = URL(string: "codex://settings/usage"), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let web = URL(string: "https://chatgpt.com/codex/settings/usage") {
            NSWorkspace.shared.open(web)
        }
    }

    @objc private func refreshNow() { store.refresh() }

    @objc private func toggleLock() {
        defaults.set(!defaults.bool(forKey: TileController.lockKey), forKey: TileController.lockKey)
    }
    @objc private func resetTile() { tile.resetPosition() }

    @objc private func toggleTile() {
        let on = !tile.isVisible
        tile.setVisible(on)
        defaults.set(on, forKey: "showTile")
    }

    @objc private func toggleClickThrough() {
        let on = !defaults.bool(forKey: "tileClickThrough")
        defaults.set(on, forKey: "tileClickThrough")
        tile.setClickThrough(on)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { Log.write("login item error: \(error.localizedDescription)") }
    }

    private func applyAppearance(_ name: String?) {
        switch name {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
        menu?.appearance = NSApp.appearance
    }

    #if DEBUG
    /// Local proof hooks (debug builds only): open the menu briefly, refresh, or preview an appearance.
    @objc private func debugCommand(_ note: Notification) {
        guard let cmd = note.object as? String else { return }
        switch cmd {
        case "openMenu":
            let t = Timer(timeInterval: 4, repeats: false) { [weak self] _ in self?.menu.cancelTracking() }
            RunLoop.main.add(t, forMode: .common)
            statusItem.button?.performClick(nil)
        case "refresh": store.refresh()
        case "appearance:dark": applyAppearance("dark")
        case "appearance:light": applyAppearance("light")
        case "appearance:system": applyAppearance(nil)
        case "statusInfo":
            if let w = statusItem.button?.window { Log.write("status item frame \(NSStringFromRect(w.frame))") }
        case "hoverOn": store.debugHover = true
        case "hoverOff": store.debugHover = false
        case "dragTest":
            let before = tile.frame
            tile.simulateDrag(dx: -300, dy: -200)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                Log.write("dragTest locked=\(self.defaults.bool(forKey: TileController.lockKey)) before=\(NSStringFromRect(before)) after=\(NSStringFromRect(self.tile.frame)) saved=\(self.defaults.string(forKey: "tileTopLeft") ?? "nil")")
            }
        case "tileInfo": Log.write("tile window \(tile.windowNumber) visible=\(tile.isVisible) frame=\(tile.frameDescription)")
        default:
            if cmd.hasPrefix("moveTo:") {
                let parts = cmd.dropFirst(7).split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 { tile.move(to: NSPoint(x: parts[0], y: parts[1])) }
            }
        }
    }
    #endif
}
