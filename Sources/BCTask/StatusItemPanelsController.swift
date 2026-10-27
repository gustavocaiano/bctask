import AppKit
import SwiftUI
import BCTaskCore
import Combine


/// One retained panel + hosting controller pair for a live pinned task.
private struct PinnedPanelEntry {
    let panel: NSPanel
    let content: NSHostingController<PinnedTaskCardView>
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
/// - Reconciles ONE floating `NSPanel` per live pinned task (`isPinned ==
///   true`, `archivedAt == nil`) with the observed store AND storage-lock
///   state, so pin, unpin, archive, restore, reload, launch, and lock
///   recovery paths all converge without one-shot plumbing and without
///   feedback loops or duplicate mutations. User closing is model-first:
///   a successful durable unpin lets the observed state strip the panel
///   (ordered out and closed, hosted content detached); refusal (save
///   failure or storage lock) keeps the panel and pin coherent.
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
    /// Prefix for stable, task-specific frame-autosave names of pinned panels.
    static let pinnedFrameAutosavePrefix = "BCTaskPinnedPanel-"
    /// Last user-positioned pinned panel, used as the bootstrap placement for
    /// a newly pinned task when no floating cards are currently open.
    static let pinnedPanelPlacementAnchorDefaultsKey = "BCTaskPinnedPanelPlacementAnchor"

    /// Mirrors `PinnedTaskCardView`'s accepted sizing contract.
    static let pinnedPanelMinimumSize = CGSize(width: 300, height: 210)
    static let pinnedPanelIdealSize = CGSize(width: 320, height: 230)
    static let pinnedPanelMaxWidth = CGFloat(360)
    /// The stagger between cards in a pinned-panel cascade.
    static let pinnedPanelCascadeOffset = CGFloat(24)

    /// Restrained catch-up cadence while the app is running.
    private static let catchUpInterval: TimeInterval = 45

    private let model: AppModel
    private let router: TaskCommandRouter

    /// Retained for the app lifetime (NSStatusBar does not auto-retain).
    private var statusItem: NSStatusItem?
    /// Retained so the SwiftUI root is created exactly once and survives toggles.
    private var mainContentController: NSHostingController<AppMenuSurfaceView>?
    private var mainPanel: NSPanel?
    /// One retained floating panel per live pinned task id; no duplicates.
    private var pinnedPanels: [UUID: PinnedPanelEntry] = [:]
    /// Cascade offset for newly created (unsaved-frame) pinned panels.
    private var pinnedCascadeIndex = 0

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
    /// panels (this immediate first observation restores persisted pins).
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
    /// subscription, and on-screen panels. This is terminal lifecycle
    /// teardown: pinned panels and the main surface are closed and stripped
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

    // MARK: - Pinned panel reconciliation

    /// Desired pinned panel set: every live task flagged pinned.
    /// Archived tasks are never pinned (`sweep` unpins them), but the filter
    /// below also defends against external data drift.
    static func desiredPinnedPanelIDs(in store: TaskStore) -> Set<UUID> {
        Set(store.tasks.filter { $0.isPinned && !$0.isArchived }.map(\.id))
    }

    /// Subscribes to the observed store AND lock state so every publication
    /// of either (launch, mutation, sweep, reload success/failure, recovery)
    /// reconciles pinned panels. Internal so focused tests exercise the same
    /// observation path without a real status item. Cancels any previous
    /// subscription first, so repeated installation stays safe.
    func installStoreObservation() {
        storeSubscription?.cancel()
        storeSubscription = model.$store.combineLatest(model.$storageError).sink { [weak self] store, storageError in
            self?.reconcilePinnedPanels(with: store, canMutate: storageError == nil)
        }
    }

    /// Converges the retained pinned-panel dictionary to the desired set.
    /// Removals always run (stale desired panels may be removed while
    /// locked); creations only run while mutation is unlocked. Removals strip
    /// and programmatically close panels with delegates detached, so the
    /// model-first user-close path remains the only path that mutates the model.
    func reconcilePinnedPanels(with store: TaskStore, canMutate: Bool) {
        let desired = Self.desiredPinnedPanelIDs(in: store)
        let stale = pinnedPanels.keys.filter { !desired.contains($0) }
        for id in stale {
            closePinnedPanel(id)
        }
        // While storage is locked the displayed snapshot keeps pinned tasks,
        // but mutations (including closing-panel unpin) are refused; do not
        // re-open panels closed by the user during a lock.
        guard canMutate else { return }
        for id in desired.subtracting(pinnedPanels.keys) {
            createPinnedPanel(id)
        }
        refreshTitles(with: store)
    }

    private func refreshTitles(with store: TaskStore) {
        for (id, entry) in pinnedPanels {
            if let task = store.tasks.first(where: { $0.id == id }) {
                entry.panel.title = task.title
            }
        }
    }

    private func createPinnedPanel(_ id: UUID) {
        guard let task = model.store.tasks.first(where: { $0.id == id }) else { return }
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
        // The accepted PinnedTaskCardView sizing contract, enforced BEFORE any
        // frame restoration so a restored frame is already inside bounds.
        panel.contentMinSize = NSSize(width: Self.pinnedPanelMinimumSize.width, height: Self.pinnedPanelMinimumSize.height)
        panel.contentMaxSize = NSSize(width: Self.pinnedPanelMaxWidth, height: .greatestFiniteMagnitude)
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        if let origin = Self.anchoredPinnedPanelOrigin(
            existingFrames: pinnedPanels.values.map { $0.panel.frame },
            savedAnchor: Self.pinnedPanelPlacementAnchor(),
            panelSize: Self.pinnedPanelIdealSize,
            screens: screens
        ) {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            // First run has neither open cards nor a user-positioned anchor,
            // so retain the original top-right cascade as a safe bootstrap.
            let visible = screen.visibleFrame
            let shift = CGFloat(pinnedCascadeIndex) * Self.pinnedPanelCascadeOffset
            pinnedCascadeIndex += 1
            panel.setFrameOrigin(
                NSPoint(
                    x: visible.maxX - Self.pinnedPanelIdealSize.width - 32 - shift,
                    y: visible.maxY - Self.pinnedPanelIdealSize.height - 96 - shift
                )
            )
        }
        // Stable, task-specific autosave name; restores the persisted frame
        // when one exists, otherwise the cascade origin above is kept.
        panel.setFrameAutosaveName(Self.pinnedFrameAutosavePrefix + id.uuidString)
        clampPinnedContent(panel)
        panel.delegate = self
        panel.orderFrontRegardless() // visible without activating the app
        pinnedPanels[id] = PinnedPanelEntry(panel: panel, content: content)
    }

    /// Selects an on-screen staggered origin for an unsaved pinned card.
    /// Existing cards take precedence so newly pinned tasks join the visible
    /// cluster; when none are open, the most recently user-moved card supplies
    /// the same-screen approximation across launches. `nil` leaves the caller
    /// to use its first-run fallback.
    static func anchoredPinnedPanelOrigin(
        existingFrames: [NSRect],
        savedAnchor: NSRect?,
        panelSize: CGSize,
        screens: [(frame: NSRect, visibleFrame: NSRect)]
    ) -> NSPoint? {
        let liveAnchor = existingFrames.max { lhs, rhs in
            if lhs.maxY != rhs.maxY { return lhs.maxY < rhs.maxY }
            return lhs.maxX < rhs.maxX
        }
        guard let anchor = liveAnchor ?? savedAnchor else { return nil }
        let anchorCenter = NSPoint(x: anchor.midX, y: anchor.midY)
        guard let screen = screens.first(where: { $0.frame.contains(anchorCenter) })
            ?? screens.first(where: { $0.frame.intersects(anchor) })
        else { return nil }

        let firstOrigin = Self.clampedPinnedPanelOrigin(
            NSPoint(
                x: anchor.minX - Self.pinnedPanelCascadeOffset,
                y: anchor.minY - Self.pinnedPanelCascadeOffset
            ),
            panelSize: panelSize,
            visibleFrame: screen.visibleFrame
        )

        // Match the original down-left cascade while walking past overlapping
        // cards, so a newly pinned task extends the cluster instead of covering
        // its most recent neighbour.
        for step in 1...16 {
            let shift = CGFloat(step) * Self.pinnedPanelCascadeOffset
            let origin = Self.clampedPinnedPanelOrigin(
                NSPoint(x: anchor.minX - shift, y: anchor.minY - shift),
                panelSize: panelSize,
                visibleFrame: screen.visibleFrame
            )
            let candidate = NSRect(origin: origin, size: panelSize)
            if !existingFrames.contains(where: { $0.intersects(candidate) }) {
                return origin
            }
        }
        return firstOrigin
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

    /// Reads a user-positioned card frame saved by `windowDidMove(_:)`.
    static func pinnedPanelPlacementAnchor(defaults: UserDefaults = .standard) -> NSRect? {
        guard let stored = defaults.string(forKey: pinnedPanelPlacementAnchorDefaultsKey) else { return nil }
        let frame = NSRectFromString(stored)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    /// Persists the most recent user placement without coupling it to a task's
    /// own autosaved frame, which still wins when that exact task is re-pinned.
    static func savePinnedPanelPlacementAnchor(_ frame: NSRect, defaults: UserDefaults = .standard) {
        defaults.set(NSStringFromRect(frame), forKey: pinnedPanelPlacementAnchorDefaultsKey)
    }

    /// Destroys a tracked pinned panel. Called from reconciliation (no model
    /// mutation needed — the change is already in the store) and from
    /// `stop()` teardown; delegates to `destroyAndReleasePinnedPanel(_:)`
    /// for deterministic release.
    private func closePinnedPanel(_ id: UUID) {
        destroyAndReleasePinnedPanel(id)
    }

    /// Programmatic destruction of a pinned panel: the delegate is detached
    /// FIRST so neither `windowShouldClose` model mutations nor
    /// `windowWillClose` cleanup can fire on this path, hosted content is
    /// detached, the panel is ordered out when visible, and `close()`
    /// completes the close (autosaved frame is persisted by AppKit, exactly
    /// as with user closes). The last strong reference is dropped via
    /// `pinnedPanels.removeValue`, so the window keeps no live content
    /// instead of surviving teardown as a rooted resource. User close keeps
    /// its model-first semantics; this helper never calls `model.setPinned`.
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

    /// Normalizes a restored (or default) pinned frame to the accepted
    /// content constraints, preserving the window's top-left corner.
    private func clampPinnedContent(_ panel: NSPanel) {
        let content = panel.contentRect(forFrameRect: panel.frame)
        var clamped = content.size
        clamped.width = min(max(clamped.width, Self.pinnedPanelMinimumSize.width), Self.pinnedPanelMaxWidth)
        clamped.height = max(clamped.height, Self.pinnedPanelMinimumSize.height)
        guard clamped != content.size else { return }
        // AppKit anchors setContentSize at the content's top-left corner.
        panel.setContentSize(clamped)
    }

    /// NSWindowDelegate, model-first close semantics:
    /// - Main panel: refuses native close and hides instead (never destroyed).
    /// - Pinned panel: asks the model for the durable unpin FIRST. A successful
    ///   publication lets the store/lock observation strip the panel
    ///   (ordered out, closed, content detached); native close is prevented
    ///   so AppKit cannot close the panel behind the controller. Save
    ///   failure or a storage lock keeps
    ///   the panel and its pin coherent (nothing closed, nothing overwritten).
    /// - A panel without a live pinned task has nothing durable to change;
    ///   native close proceeds and `windowWillClose` performs the
    ///   mutation-free dictionary cleanup.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === mainPanel {
            hideMainPanel()
            return false
        }
        guard let id = pinnedPanels.first(where: { $0.value.panel === sender })?.key,
              let task = model.store.tasks.first(where: { $0.id == id }),
              task.isPinned,
              !task.isArchived
        else {
            return true
        }
        guard model.canMutate else {
            return false // locked: keep panel + pin coherent
        }
        model.setPinned(task, false) // failed save keeps displayed state pinned and disk unchanged
        return false
    }

    /// Mutation-free defensive cleanup reserved for panels that legitimately
    /// close without a durable change (i.e. the task was no longer pinned).
    /// The previous willClose unpin mutation was removed: user close is
    /// model-first via `windowShouldClose`, so this cannot double-unpin or
    /// race the reconciliation.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
              let id = pinnedPanels.first(where: { $0.value.panel === closing })?.key
        else { return }
        pinnedPanels.removeValue(forKey: id)
    }

    /// Captures only user moves of already tracked cards. Creation and frame
    /// restoration happen before a panel enters `pinnedPanels`, preventing an
    /// automatic fallback placement from overwriting the user's preference.
    func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? NSWindow,
              pinnedPanels.values.contains(where: { $0.panel === moved })
        else { return }
        Self.savePinnedPanelPlacementAnchor(moved.frame)
    }

    // MARK: - Test seams

    var pinnedPanelIDsForTesting: Set<UUID> { Set(pinnedPanels.keys) }
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
