import AppKit
import SwiftUI
import BCTaskCore
import Combine


/// One retained card panel + hosting controller pair for a live pinned task
/// whose ticker the user clicked; it lives, shown or hidden, until the pin
/// retires.
private struct PinnedPanelEntry {
    let panel: NSPanel
    let content: NSHostingController<PinnedTaskCardView>
}

/// One fixed-width menu-bar ticker for a live pinned task.
private struct PinnedTickerEntry {
    let item: NSStatusItem
    let label: MarqueeLabelView
}

/// Minimal thread-safe counter for observer-delivery test seams.
private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Phase 3 AppKit application controller for the menu-bar utility app.
///
/// Responsibilities (all main-actor confined):
/// - Retains the `NSStatusItem` for the app lifetime and toggles ONE retained,
///   movable, resizable main panel on left-clicks. Show/Hide and Quit are
///   additionally reachable through a right-click context menu.
/// - Hosts the accepted SwiftUI surface exactly once through a retained
///   `NSHostingController`; hiding/showing never re-creates the SwiftUI root,
///   so draft text, projection, and focused-task state survive toggles.
/// - Reconciles ONE fixed-width menu-bar ticker per live pinned task
///   (`isPinned == true`, `archivedAt == nil`) with the observed store, so
///   pin, unpin, archive, restore, reload, launch, and lock recovery paths
///   all converge without one-shot plumbing. A ticker shows the task title,
///   scrolling when it does not fit. Clicking a ticker shows or hides that
///   task's floating card below it; closing a card only hides it, and the
///   controller never mutates the model for either. Retiring a pin strips
///   its card (ordered out and closed, hosted content detached) along with
///   its ticker.
/// - Translates only the accepted native shortcuts into the retained
///   `TaskCommandRouter` while the main panel is key.
/// - Runs the archival catch-up sweep on a restrained interval, on app
///   activation (filtered to `NSApp`), on wake, and on session activation
///   through main-queue block observers gated by running state, plus a final
///   sweep right before the main panel is shown.
@MainActor
final class StatusItemPanelsController: NSObject, NSWindowDelegate, NSMenuDelegate {
    /// Stable frame-autosave name for the main panel.
    static let mainFrameAutosaveName = "BCTaskMainMenuPanel"

    /// Fixed menu-bar width of each pinned task's ticker.
    static let pinnedTickerWidth = CGFloat(160)
    /// Mirrors `PinnedTaskCardView`'s accepted sizing contract.
    static let pinnedPanelMinimumSize = CGSize(width: 300, height: 210)
    static let pinnedPanelIdealSize = CGSize(width: 320, height: 230)
    static let pinnedPanelMaxWidth = CGFloat(360)
    /// Space between the menu bar and a card dropped below its ticker.
    static let pinnedCardGap = CGFloat(6)

    /// Restrained catch-up cadence while the app is running.
    private static let catchUpInterval: TimeInterval = 45

    private let model: AppModel
    private let router: TaskCommandRouter

    /// Retained for the app lifetime (NSStatusBar does not auto-retain).
    private var statusItem: NSStatusItem?
    /// Retained so the SwiftUI root is created exactly once and survives toggles.
    private var mainContentController: NSHostingController<AppMenuSurfaceView>?
    private var mainPanel: NSPanel?
    /// One menu-bar ticker per live pinned task id; no duplicates.
    private var pinnedTickers: [UUID: PinnedTickerEntry] = [:]
    /// Floating cards opened from their tickers (showing or hidden), by task id.
    private var pinnedPanels: [UUID: PinnedPanelEntry] = [:]

    private var keyMonitor: Any?
    private var catchUpTimer: Timer?
    /// Retained block-observer tokens; each must be removed from the center
    /// that produced it.
    private var observerTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var storeSubscription: AnyCancellable?
    /// Running gate for catch-up delivery: set before observers land, cleared
    /// before teardown so a notification already queued cannot sweep afterward.
    private var isRunning = false
    /// Internal invocation counters for the catch-up delivery seam (testing):
    /// handler hits count deliveries on any thread (thread-safe), delivery
    /// invocations count main-actor catch-up executions.
    private(set) var catchUpInvocationsForTesting = 0
    nonisolated private let catchUpObserverHits = ThreadSafeCounter()
    var catchUpObserverHitsForTesting: Int { catchUpObserverHits.count }

    private let showHideItem = NSMenuItem(title: "Hide BCTask", action: #selector(toggleMainPanelAction), keyEquivalent: "")

    init(model: AppModel, router: TaskCommandRouter) {
        self.model = model
        self.router = router
        super.init()
    }

    // MARK: - Lifecycle install/teardown

    /// Installs every app-lifetime seam: status item, key monitor, catch-up
    /// timer and observers, and the store observation that reconciles pinned
    /// tickers (this immediate first observation restores persisted pins).
    /// Idempotent: a repeated start while running is a no-op so no seam can
    /// ever be installed twice; `stop()` clears the gate, so start after
    /// stop reinstalls everything.
    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true
        installStatusItem()
        installKeyMonitor()
        installCatchUpTimerAndObservers()
        installStoreObservation()
    }

    /// Removes every installed seam: monitor, timer, observers, store
    /// subscription, pinned tickers, and on-screen panels. This is terminal
    /// lifecycle teardown: pinned cards and the main surface are closed and stripped
    /// (not merely hidden); because AppKit-safe programmatic release keeps
    /// `isReleasedWhenClosed = false`, closed panels can remain registered
    /// as empty shells in `NSApp.windows`; persisted frames
    /// stay in autosave storage and a later `start()` builds a fresh
    /// lifecycle.
    func stop() {
        // Clear the gate BEFORE teardown so callbacks already queued on the
        // main queue cannot sweep afterwards.
        isRunning = false
        router.updateTaskEntryFocus(false)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let catchUpTimer {
            catchUpTimer.invalidate()
            self.catchUpTimer = nil
        }
        // Selector-based observers were replaced by retained block tokens;
        // remove each from its originating center.
        for (center, token) in observerTokens {
            center.removeObserver(token)
        }
        observerTokens = []
        storeSubscription?.cancel()
        storeSubscription = nil
        for id in Array(pinnedPanels.keys) {
            destroyAndReleasePinnedPanel(id)
        }
        for id in Array(pinnedTickers.keys) {
            removePinnedTicker(id)
        }
        if let mainPanel {
            // Terminal lifecycle teardown: close and strip the retained
            // main surface (may remain as an empty registered shell), not merely
            // hidden. Reuse after stop constructs a fresh lifecycle.
            if mainPanel.delegate === self { mainPanel.delegate = nil }
            mainPanel.contentViewController = nil
            mainPanel.animationBehavior = .none
            if mainPanel.isVisible { mainPanel.orderOut(nil) }
            mainPanel.close()
            self.mainPanel = nil
            mainContentController = nil
        }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    // MARK: - Status item

    private func installStatusItem() {
        // The item is retained for the app lifetime by holding it here.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageOnly
            let symbol = NSImage(
                systemSymbolName: AppExperience.menuBarSymbol,
                accessibilityDescription: AppExperience.menuBarTitle
            )
            button.image = symbol?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            )
            button.image?.isTemplate = true
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = AppExperience.menuBarTitle
            button.setAccessibilityLabel(AppExperience.menuBarTitle)
            button.setAccessibilityHelp("Show or hide BCTask")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Left-click toggles the retained main panel; right-click (or
    /// Control-click) opens Show/Hide + Quit.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp
           || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            openStatusContextMenu()
        } else {
            toggleMainPanel()
        }
    }

    private func openStatusContextMenu() {
        guard let statusItem else { return }
        showHideItem.title = mainPanel?.isVisible == true ? "Hide BCTask" : "Show BCTask"
        // Proven status-item pattern: temporarily attach the menu, simulate
        // the click so the system presents it under the status item, then
        // detach so plain left-clicks return to toggling.
        statusItem.menu = statusContextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private lazy var statusContextMenu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false
        showHideItem.target = self
        menu.addItem(showHideItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit BCTask", action: #selector(quitAction), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        return menu
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        showHideItem.title = mainPanel?.isVisible == true ? "Hide BCTask" : "Show BCTask"
    }

    @objc private func toggleMainPanelAction() { toggleMainPanel() }
    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // MARK: - Main panel

    /// The retained main surface. Idempotent: repeated calls return the same
    /// panel and never rebuild the SwiftUI root.
    func ensureMainSurface() -> NSPanel {
        if let mainPanel { return mainPanel }
        let content = NSHostingController(
            rootView: AppMenuSurfaceView(model: model, commandRouter: router)
        )
        mainContentController = content
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: AppExperience.surfaceIdealSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = AppExperience.menuBarTitle
        panel.contentViewController = content
        panel.contentMinSize = AppExperience.surfaceMinimumSize
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Center on first launch; attaching the autosave name restores the
        // persisted frame when one exists (all later moves/resizes).
        panel.center()
        panel.setFrameAutosaveName(Self.mainFrameAutosaveName)
        panel.delegate = self
        mainPanel = panel
        return panel
    }

    func showMainPanel() {
        // Final catch-up seam before the surface appears.
        model.sweepAndPersist()
        let panel = ensureMainSurface()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hideMainPanel() {
        mainPanel?.orderOut(nil)
    }

    func toggleMainPanel() {
        if mainPanel?.isVisible == true {
            hideMainPanel()
        } else {
            showMainPanel()
        }
    }

    // MARK: - Key monitoring

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.translates(event: event) else { return event }
            return nil // recognized and consumed
        }
    }

    /// Gate for the local monitor: only translate while the retained main
    /// panel is the key window.
    private func translates(event: NSEvent) -> Bool {
        guard keyMonitor != nil,
              let mainPanel,
              mainPanel.isKeyWindow,
              let translatedCommand = KeyCommandTranslator.translate(event: event)
        else { return false }
        return routeMainPanelCommand(translatedCommand)
    }

    /// Contextual routing seam after the key-window/event gate. The router's
    /// semantic focus bit is updated synchronously by `ContentView`, avoiding
    /// all inspection of SwiftUI's private AppKit responder hierarchy.
    @discardableResult
    func routeMainPanelCommand(_ translatedCommand: TaskSurfaceCommand) -> Bool {
        guard let command = MainPanelKeyCommandBridge.commandToConsume(
            translatedCommand,
            taskEntryIsFocused: router.taskEntryIsFocused,
            notesEditingIsFocused: router.notesEditingIsFocused
        ) else { return false }
        router.send(command)
        return true
    }

    // MARK: - Catch-up sweeps

    private func installCatchUpTimerAndObservers() {
        catchUpTimer = Timer.scheduledTimer(
            timeInterval: Self.catchUpInterval,
            target: self,
            selector: #selector(periodicCatchUpTick),
            userInfo: nil,
            repeats: true
        )

        // Block observers hop explicitly to the main actor (posting threads
        // vary); the running gate makes already-enqueued callbacks inert
        // after stop().
        installCatchUpObserver(NotificationCenter.default, NSApplication.didBecomeActiveNotification, object: NSApp)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        installCatchUpObserver(workspaceCenter, NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        installCatchUpObserver(workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification, object: NSWorkspace.shared)
    }

    /// Installs one retained catch-up observer on `center`. Delivery hops
    /// explicitly to the main actor (notifications may post from arbitrary
    /// threads), and the running gate makes already-enqueued callbacks inert
    /// after `stop()`. Internal so focused tests exercise the same delivery
    /// path through a test-local notification center.
    func installCatchUpObserver(_ center: NotificationCenter, _ name: Notification.Name, object: Any? = nil) {
        let token = center.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.catchUpObserverHits.increment()
            if Thread.isMainThread {
                // Already on the main thread: synchronous, deterministic.
                MainActor.assumeIsolated { self.deliverCatchUp() }
            } else {
                // Posting threads vary: route to the main queue. The block
                // runs on the main thread (so `assumeIsolated` is legal) and
                // avoids unstructured Task machinery, which a buggy host
                // toolchain elsewhere treats… badly. `deliverCatchUp` is
                // guarded by `isRunning`, so anything still queued after
                // `stop()` is inert.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.deliverCatchUp() }
                }
            }
        }
        observerTokens.append((center, token))
    }

    private func deliverCatchUp() {
        guard isRunning else {
            return
        } // queued after stop(): inert
        catchUpInvocationsForTesting += 1
        runCatchUpSweep()
    }

    /// Timer fire point (main run loop; the timer targets the main actor).
    @objc private func periodicCatchUpTick() { deliverCatchUp() }

    /// Catch-up seam triggered by the timer, app activation, wake, and
    /// session-activation events. Returns the ids archived by this sweep
    /// (empty = no-op, no write).
    @discardableResult
    func runCatchUpSweep() -> [UUID] {
        model.sweepAndPersist()
    }

    // MARK: - Pinned tickers and cards

    /// Desired ticker set: every live task flagged pinned.
    /// Archived tasks are never pinned (`sweep` unpins them), but the filter
    /// below also defends against external data drift.
    static func desiredPinnedTaskIDs(in store: TaskStore) -> Set<UUID> {
        Set(store.tasks.filter { $0.isPinned && !$0.isArchived }.map(\.id))
    }

    /// Subscribes to the observed store so every publication (launch,
    /// mutation, sweep, reload, recovery) reconciles pinned tickers and
    /// cards. Internal so focused tests exercise the same observation path
    /// without the app's own status item. Cancels any previous subscription
    /// first, so repeated installation stays safe.
    func installStoreObservation() {
        storeSubscription?.cancel()
        storeSubscription = model.$store.sink { [weak self] store in
            self?.reconcilePinnedTasks(with: store)
        }
    }

    /// Converges tickers to the live pinned tasks of `store`: retired pins
    /// lose their ticker and any open card, new pins get a ticker but never a
    /// card (cards open only from a ticker click), and titles follow the
    /// store. Storage lock needs no gate: a locked store cannot change, and an
    /// open card shows its own locked state with Reload.
    func reconcilePinnedTasks(with store: TaskStore) {
        let desired = Self.desiredPinnedTaskIDs(in: store)
        for id in pinnedPanels.keys.filter({ !desired.contains($0) }) {
            destroyAndReleasePinnedPanel(id)
        }
        for id in pinnedTickers.keys.filter({ !desired.contains($0) }) {
            removePinnedTicker(id)
        }
        // Store order keeps ticker creation deterministic.
        for task in store.tasks where desired.contains(task.id) && pinnedTickers[task.id] == nil {
            createPinnedTicker(task.id)
        }
        refreshTitles(with: store)
    }

    private func refreshTitles(with store: TaskStore) {
        for task in store.tasks {
            if let ticker = pinnedTickers[task.id] {
                ticker.label.text = task.title
                ticker.item.button?.toolTip = task.title
                ticker.item.button?.setAccessibilityLabel(task.title)
            }
            pinnedPanels[task.id]?.panel.title = task.title
        }
    }

    private func createPinnedTicker(_ id: UUID) {
        let item = NSStatusBar.system.statusItem(withLength: Self.pinnedTickerWidth)
        let label = MarqueeLabelView(frame: item.button?.bounds ?? .zero)
        if let button = item.button {
            button.title = ""
            button.image = nil
            label.autoresizingMask = [.width, .height]
            button.addSubview(label)
            button.setAccessibilityHelp("Show or hide this task's card")
            button.target = self
            button.action = #selector(pinnedTickerClicked(_:))
        }
        pinnedTickers[id] = PinnedTickerEntry(item: item, label: label)
    }

    private func removePinnedTicker(_ id: UUID) {
        guard let entry = pinnedTickers.removeValue(forKey: id) else { return }
        NSStatusBar.system.removeStatusItem(entry.item)
    }

    @objc private func pinnedTickerClicked(_ sender: NSStatusBarButton) {
        guard let id = pinnedTickers.first(where: { $0.value.item.button === sender })?.key else { return }
        togglePinnedCard(id)
    }

    /// Ticker click: shows the task's floating card just below its ticker, or
    /// hides it when it is showing. Hiding only orders the card out and never
    /// tears its hosted content down, so an open notes draft is never
    /// dropped. The controller mutates nothing here; the ticker stays until
    /// the pin itself goes away.
    func togglePinnedCard(_ id: UUID) {
        guard let ticker = pinnedTickers[id] else { return }
        if let card = pinnedPanels[id]?.panel, card.isVisible {
            card.orderOut(nil)
            return
        }
        guard let card = pinnedPanels[id]?.panel ?? makePinnedCard(id) else { return }
        placePinnedCard(card, below: ticker)
        card.orderFrontRegardless() // visible without activating the app
    }

    private func makePinnedCard(_ id: UUID) -> NSPanel? {
        guard let task = model.store.tasks.first(where: { $0.id == id }) else { return nil }
        let content = NSHostingController(rootView: PinnedTaskCardView(model: model, taskID: id))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.pinnedPanelIdealSize),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = task.title
        panel.contentViewController = content
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false // cards stay fully usable
        // The accepted PinnedTaskCardView sizing contract.
        panel.contentMinSize = NSSize(width: Self.pinnedPanelMinimumSize.width, height: Self.pinnedPanelMinimumSize.height)
        panel.contentMaxSize = NSSize(width: Self.pinnedPanelMaxWidth, height: .greatestFiniteMagnitude)
        panel.delegate = self
        pinnedPanels[id] = PinnedPanelEntry(panel: panel, content: content)
        return panel
    }

    /// Every show drops the card below its ticker, wherever it was dragged
    /// to last time.
    private func placePinnedCard(_ panel: NSPanel, below ticker: PinnedTickerEntry) {
        guard let button = ticker.item.button,
              let tickerWindow = button.window,
              let screen = tickerWindow.screen ?? NSScreen.main
        else {
            panel.center() // no on-screen ticker to hang from
            return
        }
        let tickerFrame = tickerWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel.setFrameOrigin(
            Self.pinnedCardOrigin(below: tickerFrame, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame)
        )
    }

    /// Drops a card just below its ticker, centered on it, inside the usable
    /// part of the ticker's screen.
    static func pinnedCardOrigin(below ticker: NSRect, panelSize: CGSize, visibleFrame: NSRect) -> NSPoint {
        clampedPinnedPanelOrigin(
            NSPoint(
                x: ticker.midX - panelSize.width / 2,
                y: ticker.minY - pinnedCardGap - panelSize.height
            ),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
    }

    /// Clamps a new panel's origin to the usable part of its selected screen.
    static func clampedPinnedPanelOrigin(
        _ origin: NSPoint,
        panelSize: CGSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maximumX),
            y: min(max(origin.y, visibleFrame.minY), maximumY)
        )
    }

    /// Programmatic destruction of a pinned card, shown or hidden, once its
    /// pin retires (reconciliation: the change is already in the store) and
    /// on `stop()` teardown: the delegate is detached FIRST so
    /// `windowWillClose` cleanup cannot fire on this path, hosted content is
    /// detached (its `onDisappear` commits an open notes draft), the panel is
    /// ordered out when visible, and `close()` completes the close. The last
    /// strong reference is dropped via `pinnedPanels.removeValue`, so the
    /// window keeps no live content instead of surviving teardown as a rooted
    /// resource. The helper itself never calls the model.
    private func destroyAndReleasePinnedPanel(_ id: UUID) {
        guard let entry = pinnedPanels.removeValue(forKey: id) else { return }
        let panel = entry.panel
        if panel.delegate === self { panel.delegate = nil }
        panel.contentViewController = nil
        // Instantaneous order-out (no window transform animation whose
        // blocks could outlive the torn-down window graph) and an explicit
        // AppKit-registry-safe release model: `isReleasedWhenClosed` stays
        // false — flipping it true here over-releases under ARC on this
        // toolchain (SIGSEGV at the next CA transaction commit, see debug
        // evidence), so the panel remains registered-but-empty while the
        // hosted content, delegate, and controller references are all
        // detached deterministically.
        panel.animationBehavior = .none
        if panel.isVisible { panel.orderOut(nil) }
        panel.close()
    }

    /// NSWindowDelegate close semantics:
    /// - Main panel: refuses native close and hides instead (never destroyed).
    /// - Pinned card: refuses native close and hides instead, exactly like a
    ///   second ticker click: the controller leaves the model alone, so the
    ///   pin and its ticker stay, and the card's hosted content (with any open
    ///   notes draft) is kept for the next show.
    /// - Any other window closes natively.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === mainPanel {
            hideMainPanel()
            return false
        }
        guard pinnedPanels.values.contains(where: { $0.panel === sender }) else {
            return true
        }
        sender.orderOut(nil)
        return false
    }

    /// Mutation-free defensive cleanup for a tracked card that closes by any
    /// path other than `windowShouldClose`.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
              let id = pinnedPanels.first(where: { $0.value.panel === closing })?.key
        else { return }
        pinnedPanels.removeValue(forKey: id)
    }

    // MARK: - Test seams

    var pinnedTickerIDsForTesting: Set<UUID> { Set(pinnedTickers.keys) }
    func pinnedTickerForTesting(_ id: UUID) -> NSStatusItem? { pinnedTickers[id]?.item }
    func pinnedTickerTextForTesting(_ id: UUID) -> String? { pinnedTickers[id]?.label.text }
    var pinnedPanelCountForTesting: Int { pinnedPanels.count }
    var mainPanelForTesting: NSPanel? { mainPanel }
    var mainContentControllerForTesting: NSHostingController<AppMenuSurfaceView>? { mainContentController }
    func pinnedPanelForTesting(_ id: UUID) -> NSPanel? { pinnedPanels[id]?.panel }
    var keyMonitorInstalledForTesting: Bool { keyMonitor != nil }
    /// Internal seam: number of retained catch-up/lifecycle observer tokens.
    /// start() installs exactly three (app activation, wake, session
    /// activation); a duplicate start would append three more, so this count
    /// proves idempotent start structurally without a system-wide broadcast.
    var catchUpObserverTokenCountForTesting: Int { observerTokens.count }
    func setCatchUpGateForTesting(_ on: Bool) { isRunning = on }
}
