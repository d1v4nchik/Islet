import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Borderless, click-through panel centered on the notch.
final class IslandPanel: NSPanel {
    static let size = CGSize(width: 640, height: 660)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// SwiftUI view inside the status item that lets clicks fall through to the button.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class IslandController: NSObject {
    let model: CalendarModel
    let ui = IslandUI()
    let panel = IslandPanel()
    private var host: IslandHostingView<IslandRoot>!
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var statusHost: PassthroughHostingView<StatusLabel>?
    /// Off-screen copy of the label, used only to measure the width it's heading to.
    private let measureHost = NSHostingView(rootView: StatusLabelContent(state: StatusState(kind: .idle)))
    private var lastStatus: StatusState?
    private var statusTarget: CGFloat = 0
    private var widthTimer: Timer?
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var wantsHover = false
    private var enteredWhilePinned = false
    private var hoverWork: DispatchWorkItem?
    private var fastTimer: Timer?
    private var resetWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(model: CalendarModel) {
        self.model = model
        super.init()
        host = IslandHostingView(rootView: IslandRoot(model: model, ui: ui))
        host.sizingOptions = []
        host.safeAreaRegions = []
        panel.contentView = host
        layoutPanel()
        panel.orderFrontRegardless()
        setUpStatusItem()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        installMonitors()
    }

    // MARK: Menu bar item

    private func setUpStatusItem() {
        guard let button = statusItem.button else { return }
        let h = PassthroughHostingView(rootView: StatusLabel(model: model))
        button.addSubview(h)
        statusHost = h
        button.target = self
        button.action = #selector(statusClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        resizeStatusItem()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizeStatusItem() }
            .store(in: &cancellables)
    }

    private func resizeStatusItem() {
        let state = model.statusState
        guard state != lastStatus else { return }
        lastStatus = state
        var steady = state
        steady.compact = false
        measureHost.rootView = StatusLabelContent(state: steady)
        animateStatusWidth(to: ceil(measureHost.fittingSize.width))
    }

    /// macOS resizes menu bar items instantly; step the width ourselves so it glides (ease-out),
    /// while the label's text fades and slides in step with it.
    private func animateStatusWidth(to target: CGFloat) {
        guard let host = statusHost, let button = statusItem.button, abs(target - statusTarget) > 0.5 else { return }
        statusTarget = target
        widthTimer?.invalidate()
        let from = statusItem.length
        let height = button.bounds.height
        guard from > 1, abs(from - target) > 0.5 else {
            statusItem.length = target
            host.frame = NSRect(x: 0, y: 0, width: target, height: height)
            return
        }
        // Lay the label out at the wider of the two sizes; the item's edge reveals or hides the rest.
        host.frame = NSRect(x: 0, y: 0, width: max(from, target), height: height)
        let start = CACurrentMediaTime()
        let duration = 0.3
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let p = min(1, (CACurrentMediaTime() - start) / duration)
                let eased = p * p * (3 - 2 * p)   // ease in-out
                self.statusItem.length = from + (target - from) * eased
                if p >= 1 {
                    timer.invalidate()
                    self.statusHost?.frame = NSRect(x: 0, y: 0, width: target, height: height)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        widthTimer = t
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            guard let button = statusItem.button else { return }
            buildMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
            return
        }
        if isOpen { close() } else { openPinned() }
    }

    private var isOpen: Bool { ui.hovering || ui.pinned }

    /// Opened from the menu bar item: stays open until you click elsewhere, or visit it and leave.
    private func openPinned() {
        hoverWork?.cancel()
        enteredWhilePinned = islandContains(NSEvent.mouseLocation)
        prepareToOpen()
        withAnimation(Anim.morph) { ui.pinned = true }
    }

    private func close() {
        hoverWork?.cancel()
        enteredWhilePinned = false
        withAnimation(Anim.morph) {
            ui.pinned = false
            ui.hovering = false
        }
        // Once it has finished closing, go back to Today so the next open always starts there.
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.ui.hovering, !self.ui.pinned else { return }
                self.resetWork = nil
                self.showToday()
            }
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// Reopened before the close finished: still start on Today.
    private func prepareToOpen() {
        model.dismissPeek()
        if let work = resetWork {
            work.cancel()
            resetWork = nil
            showToday()
        }
    }

    private func showToday() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            ui.tab = .today
            ui.selectedDay = nil
        }
    }

    // MARK: Placement

    @objc private func screensChanged() { layoutPanel() }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    private func layoutPanel() {
        guard let s = targetScreen() else { return }
        var notchW: CGFloat = 0
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notchW = max(0, s.frame.width - l.width - r.width)
        }
        let hasNotch = notchW > 0
        let barH = s.frame.maxY - s.visibleFrame.maxY
        let height = hasNotch ? s.safeAreaInsets.top : max(barH, 24)
        let g = NotchGeometry(hasNotch: hasNotch, notchWidth: notchW, height: height)
        if ui.geo != g { ui.geo = g }

        let size = IslandPanel.size
        panel.setFrame(NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    // MARK: Hover + clicks

    private var mode: IslandMode { ui.mode(peeking: model.peek != nil) }

    /// The island is the notch plus (when open) the panel below the menu bar. Nothing else.
    private func islandContains(_ p: NSPoint) -> Bool {
        let f = panel.frame
        let n = ui.geo.neckWidth, h = ui.geo.height
        let neck = NSRect(x: f.midX - n / 2, y: f.maxY - h, width: n, height: h + 4)
        let m = mode
        if m == .collapsed { return n > 0 && neck.contains(p) }
        let b = ui.bodySize(for: m)
        let body = NSRect(x: f.midX - b.width / 2, y: f.maxY - h - b.height, width: b.width, height: b.height)
        let slack: CGFloat = m == .expanded ? -4 : -2
        return (n > 0 && neck.contains(p)) || body.insetBy(dx: slack, dy: slack).contains(p)
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.updateHover() }
            return e
        }) { monitors.append(m) }

        // Clicking anywhere else closes a panel opened from the menu bar item.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, !self.islandContains(NSEvent.mouseLocation) else { return }
                self.close()
            }
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] e in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, e.window === self.panel else { return false }
                let p = NSEvent.mouseLocation
                guard self.islandContains(p) else { return false }
                self.showMenu(at: p)
                return true
            }
            return consumed ? nil : e
        }) { monitors.append(m) }

        // Safety net: catches size changes under a still cursor (e.g. a peek popping up).
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func updateHover() {
        let p = NSEvent.mouseLocation
        let inside = islandContains(p)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        // macOS doesn't send mouse-moved events to a window that isn't focused, so while the cursor
        // is near or on the island we sample it every frame instead.
        let f = panel.frame
        let near = p.y > f.maxY - 120 && abs(p.x - f.midX) < 260
        setFastPolling(inside || near || ui.hovering || ui.pinned || model.peek != nil)
        guard inside != wantsHover else { return }
        wantsHover = inside
        hoverWork?.cancel()

        if model.peek != nil && !isOpen {
            // Hovering a heads-up keeps it open (so Join stays put) instead of expanding it.
            if inside { model.holdPeek() } else { model.releasePeek() }
            return
        }

        if inside {
            if ui.pinned {
                enteredWhilePinned = true
                return
            }
            schedule(after: 0.12) { [weak self] in
                guard let self else { return }
                self.prepareToOpen()
                withAnimation(Anim.morph) { self.ui.hovering = true }
            }
        } else {
            // Opened from the menu bar and not visited yet: wait for a click elsewhere.
            if ui.pinned && !enteredWhilePinned && !ui.hovering { return }
            schedule(after: 0.28) { [weak self] in self?.close() }
        }
    }

    private func setFastPolling(_ on: Bool) {
        if on, fastTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateHover() }
            }
            RunLoop.main.add(t, forMode: .common)
            fastTimer = t
        } else if !on, let t = fastTimer {
            t.invalidate()
            fastTimer = nil
        }
    }

    private func schedule(after delay: Double, _ block: @escaping @MainActor () -> Void) {
        let work = DispatchWorkItem { MainActor.assumeIsolated { block() } }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Right-click menu

    private func showMenu(at screenPoint: NSPoint) {
        let wp = panel.convertPoint(fromScreen: screenPoint)
        buildMenu().popUp(positioning: nil, at: host.convert(wp, from: nil), in: host)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func item(_ title: String, _ action: Selector, symbol: String? = nil, to target: NSMenu? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            (target ?? menu).addItem(i)
            return i
        }

        _ = item("Open Google Calendar", #selector(openGoogle), symbol: "arrow.up.right.square")
        if model.auth.isSignedIn {
            _ = item("Refresh", #selector(refresh), symbol: "arrow.clockwise")
        }
        if model.connection == .connected {
            _ = item("Preview Heads-up", #selector(previewHeadsUp), symbol: "bell")
        }
        menu.addItem(.separator())

        if !model.calendars.isEmpty {
            let calsItem = NSMenuItem(title: "Calendars", action: nil, keyEquivalent: "")
            calsItem.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
            let sub = NSMenu()
            sub.autoenablesItems = false
            for c in model.calendars {
                let it = NSMenuItem(title: c.name, action: #selector(toggleCalendar(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = c.id
                it.state = model.isVisible(c) ? .on : .off
                it.image = swatch(c.nsColor)
                sub.addItem(it)
            }
            calsItem.submenu = sub
            menu.addItem(calsItem)
        }

        let account = NSMenuItem(title: "Google Account", action: nil, keyEquivalent: "")
        account.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
        let acct = NSMenu()
        acct.autoenablesItems = false
        if model.auth.isSignedIn {
            _ = item("Sign Out", #selector(signOut), to: acct)
        } else if model.auth.hasClient {
            _ = item("Sign In with Google…", #selector(signIn), to: acct)
        }
        _ = item("Use a Different Client JSON…", #selector(chooseClient), to: acct)
        account.submenu = acct
        menu.addItem(account)

        let notionItem = NSMenuItem(title: "Notion Tasks", action: nil, keyEquivalent: "")
        notionItem.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
        let nm = NSMenu()
        nm.autoenablesItems = false
        if model.notion.isConnected {
            _ = item("Open in Notion", #selector(openNotion), to: nm)
            _ = item("Disconnect", #selector(disconnectNotion), to: nm)
        } else {
            _ = item("Connect…", #selector(connectNotion), to: nm)
        }
        notionItem.submenu = nm
        menu.addItem(notionItem)

        let login = item("Launch at Login", #selector(toggleLogin), symbol: "power")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        _ = item("Quit Islet", #selector(quit))
        return menu
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
    }

    @objc private func openGoogle() { GCal.open(day: Date()) }
    @objc private func refresh() { model.refresh(force: true) }
    @objc private func previewHeadsUp() {
        close()
        model.previewHeadsUp()
    }
    @objc private func signIn() { model.signIn() }
    @objc private func signOut() { model.signOut() }
    @objc private func chooseClient() { model.chooseClientFile() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func connectNotion() { close(); model.connectNotion() }
    @objc private func disconnectNotion() { model.disconnectNotion() }
    @objc private func openNotion() { model.openTasksInNotion() }

    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.toggleCalendar(id)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }
}
