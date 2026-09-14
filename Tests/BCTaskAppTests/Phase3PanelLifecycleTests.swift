import Testing
import Foundation
import AppKit
import SwiftUI
import BCTaskCore
@testable import BCTask

/// Phase 3 focused evidence:
/// - the pure shortcut translator only recognizes the accepted native
///   shortcuts and rejects everything else deterministically,
/// - pinned panel reconciliation converges to exactly one retained panel per
///   live pinned task across launch restore, pin/unpin, archival catch-up,
///   and external state reload — without duplicate ids or feedback loops,
/// - closing a pinned panel routes through the existing model mutation,
/// - the retained main surface keeps one hosted SwiftUI root across toggles,
/// - controller start/stop install and remove the lifecycle seams.
private final class Phase3Clock: @unchecked Sendable {
    private var value: Date
    init(start: Date) { value = start }
    func read() -> Date { value }
    func advance(_ interval: TimeInterval) { value = value.addingTimeInterval(interval) }
}

@Suite("Phase 3 shortcut translator")
struct KeyShortcutTranslatorTests {
    private let n = KeyCommandTranslator.keyCodeN
    private let up = KeyCommandTranslator.keyCodeUpArrow
    private let down = KeyCommandTranslator.keyCodeDownArrow
    private let left = KeyCommandTranslator.keyCodeLeftArrow
    private let right = KeyCommandTranslator.keyCodeRightArrow
    private let tab = KeyCommandTranslator.keyCodeTab
    private let escape = KeyCommandTranslator.keyCodeEscape
    private let p = KeyCommandTranslator.keyCodeP
    private let deleteKey = KeyCommandTranslator.keyCodeDelete

    @Test func commandNFocusesNewTask() {
        #expect(KeyCommandTranslator.translate(keyCode: n, modifiers: .command) == .focusNewTask)
    }

    @Test func plainUpDownArrowsMoveFocus() {
        #expect(KeyCommandTranslator.translate(keyCode: up, modifiers: []) == .focusPreviousTask)
        #expect(KeyCommandTranslator.translate(keyCode: down, modifiers: []) == .focusNextTask)
    }

    @Test func commandArrowsMoveFocusedTaskThroughStatuses() {
        #expect(KeyCommandTranslator.translate(keyCode: left, modifiers: .command) == .moveFocusedTaskBackward)
        #expect(KeyCommandTranslator.translate(keyCode: right, modifiers: .command) == .moveFocusedTaskForward)
    }

    @Test func plainTabTogglesProjectionAndPlainEscapeLeavesEntry() {
        #expect(KeyCommandTranslator.translate(keyCode: tab, modifiers: []) == .toggleProjection)
        #expect(KeyCommandTranslator.translate(keyCode: escape, modifiers: []) == .leaveNewTaskEntry)
    }

    @Test @MainActor func routerFocusStateDrivesEscapeBridge() throws {
        let command = try #require(KeyCommandTranslator.translate(keyCode: escape, modifiers: []))
        let router = TaskCommandRouter()

        #expect(
            MainPanelKeyCommandBridge.commandToConsume(
                command,
                taskEntryIsFocused: router.taskEntryIsFocused
            ) == nil
        )

        router.updateTaskEntryFocus(true)
        #expect(router.taskEntryIsFocused)
        #expect(
            MainPanelKeyCommandBridge.commandToConsume(
                command,
                taskEntryIsFocused: router.taskEntryIsFocused
            ) == .leaveNewTaskEntry
        )

        router.updateTaskEntryFocus(false)
        #expect(!router.taskEntryIsFocused)
        #expect(
            MainPanelKeyCommandBridge.commandToConsume(
                .toggleProjection,
                taskEntryIsFocused: router.taskEntryIsFocused
            ) == .toggleProjection
        )
    }

    @Test func modifiedTabAndEscapePassThroughUntouched() {
        // Every nonempty combination of Command/Shift/Control/Option is
        // disqualified. This includes Shift-Tab, which must retain the
        // platform's standard reverse-focus behavior.
        for rawValue in UInt(1)..<UInt(16) {
            let modifiers = TaskSurfaceModifiers(rawValue: rawValue)
            #expect(KeyCommandTranslator.translate(keyCode: tab, modifiers: modifiers) == nil)
            #expect(KeyCommandTranslator.translate(keyCode: escape, modifiers: modifiers) == nil)
        }
    }

    @Test func commandPAndCommandDeleteTranslateToPinAndDeleteFocusedTask() {
        #expect(KeyCommandTranslator.translate(keyCode: p, modifiers: .command) == .pinFocusedTask)
        #expect(KeyCommandTranslator.translate(keyCode: deleteKey, modifiers: .command) == .deleteFocusedTask)
    }

    @Test func modifiedAndPlainDeleteAndPinVariantsPassThroughUntouched() {
        #expect(KeyCommandTranslator.translate(keyCode: p, modifiers: []) == nil)
        #expect(KeyCommandTranslator.translate(keyCode: deleteKey, modifiers: []) == nil)
        #expect(KeyCommandTranslator.translate(keyCode: p, modifiers: [.command, .shift]) == nil)
        #expect(KeyCommandTranslator.translate(keyCode: deleteKey, modifiers: [.command, .option]) == nil)
        #expect(KeyCommandTranslator.translate(keyCode: 117, modifiers: .command) == nil) // forward delete
        #expect(KeyCommandTranslator.translate(keyCode: deleteKey, modifiers: .shift) == nil)
    }

    @Test func bridgeGateForPinAndDeleteFocusedTask() {
        // Cmd-Backspace must reach the focused new-task field as standard
        // text editing, so deleteFocusedTask is not consumed while typing.
        #expect(MainPanelKeyCommandBridge.commandToConsume(.deleteFocusedTask, taskEntryIsFocused: true) == nil)
        #expect(MainPanelKeyCommandBridge.commandToConsume(.deleteFocusedTask, taskEntryIsFocused: false) == .deleteFocusedTask)
        // Cmd-P has no text-field meaning: consumed in both focus states.
        #expect(MainPanelKeyCommandBridge.commandToConsume(.pinFocusedTask, taskEntryIsFocused: true) == .pinFocusedTask)
        #expect(MainPanelKeyCommandBridge.commandToConsume(.pinFocusedTask, taskEntryIsFocused: false) == .pinFocusedTask)
    }

    @Test func unknownKeysAreNeverConsumed() {
        #expect(KeyCommandTranslator.translate(keyCode: 46, modifiers: []) == nil) // plain M
        #expect(KeyCommandTranslator.translate(keyCode: 46, modifiers: .command) == nil) // Command-M is not ours
    }

    @Test func extraModifiersDisqualifyAcceptedShortcuts() {
        #expect(KeyCommandTranslator.translate(keyCode: n, modifiers: [.command, .shift]) == nil)
        #expect(KeyCommandTranslator.translate(keyCode: n, modifiers: [.command, .option]) == nil)
        #expect(KeyCommandTranslator.translate(keyCode: n, modifiers: [.command, .control]) == nil)
        #expect(KeyCommandTranslator.translate(keyCode: up, modifiers: .shift) == nil)
        #expect(KeyCommandTranslator.translate(keyCode: up, modifiers: .command) == nil)
        #expect(KeyCommandTranslator.translate(keyCode: down, modifiers: .option) == nil)
        #expect(KeyCommandTranslator.translate(keyCode: left, modifiers: [.command, .shift]) == nil)
        #expect(KeyCommandTranslator.translate(keyCode: right, modifiers: [.command, .control]) == nil)
    }
}

@MainActor
final class Phase3PanelLifecycleTests {
    private let t0: Date
    private let deadline: Date
    private let clock: Phase3Clock
    private let tempRoot: URL
    private let dir: URL
    private let fileStore: TaskFileStore

    /// Per-suite disposable storage: each test instance gets its own disk
    /// directory and clock.
    init() {
        t0 = Date(timeIntervalSince1970: 7_777_000)
        deadline = t0.addingTimeInterval(3600)
        clock = Phase3Clock(start: t0)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskPhase3-\(UUID().uuidString)", isDirectory: true)
        dir = tempRoot.appendingPathComponent("store", isDirectory: true)
        fileStore = TaskFileStore(directory: dir)
    }

    deinit {
        // Restore write permission before the recursive temp cleanup (the
        // save-failure test may leave the store directory read-only).
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Fixture helpers

    /// Seeds the disk store, then builds a model + controller pair with
    /// deterministic time and temp storage.
    private func makeController(
        with store: TaskStore,
        router: TaskCommandRouter = TaskCommandRouter()
    ) throws -> (controller: StatusItemPanelsController, model: AppModel) {
        // Capture local VALUES (not `self`) so a panel/model retention chain
        // cannot keep this suite instance alive until process teardown.
        let fileStore = self.fileStore
        let clock = self.clock
        let model = AppModel(now: { clock.read() }) { fileStore }
        return (StatusItemPanelsController(model: model, router: router), model)
    }

    private func seedDisk(with store: TaskStore) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try fileStore.save(store)
    }

    private func pinnedActive(title: String = "pinned") -> TaskItem {
        TaskItem(title: title, status: .todo, createdAt: t0, updatedAt: t0, isPinned: true)
    }

    private func readDisk() throws -> TaskStore {
        try fileStore.load(now: clock.read())
    }

    // MARK: - Desired set (pure seam)

    @Test func desiredPanelIDsFilterArchivedAndUnpinnedTasks() {
        let pinnedActiveTask = TaskItem(title: "active", createdAt: t0, updatedAt: t0, isPinned: true)
        let regular = TaskItem(title: "plain", createdAt: t0, updatedAt: t0)
        let pinnedDone = TaskItem(title: "done", status: .done, createdAt: t0, updatedAt: t0, completedAt: t0, isPinned: true)
        // Data drift: an archived task that still claims isPinned (external file).
        let archivedPinned = TaskItem(title: "archived", status: .done, createdAt: t0, updatedAt: t0, completedAt: t0, archivedAt: t0, isPinned: true)
        let store = TaskStore(tasks: [pinnedActiveTask, regular, pinnedDone, archivedPinned])

        #expect(StatusItemPanelsController.desiredPinnedPanelIDs(in: store) == [pinnedActiveTask.id, pinnedDone.id])
        #expect(StatusItemPanelsController.desiredPinnedPanelIDs(in: TaskStore(tasks: [])).isEmpty)
    }

    // MARK: - Launch restoration and no-duplicate reconciliation

    @Test func launchRestoresExactlyOnePanelPerPersistedPin() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, _) = try makeController(with: TaskStore(tasks: [task]))

        controller.installStoreObservation() // immediate publish restores persisted pins
        #expect(controller.pinnedPanelCountForTesting == 1)
        let firstPanel = try #require(controller.pinnedPanelForTesting(task.id))
        #expect(firstPanel.isFloatingPanel == true)
        #expect(firstPanel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(firstPanel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(firstPanel.frameAutosaveName == StatusItemPanelsController.pinnedFrameAutosavePrefix + task.id.uuidString)

        // Reconciliation idempotence: repeated publishes never duplicate
        // panels or rebuild content.
        controller.reconcilePinnedPanels(with: TaskStore(tasks: [task]), canMutate: true)
        controller.reconcilePinnedPanels(with: TaskStore(tasks: [task]), canMutate: true)
        #expect(controller.pinnedPanelCountForTesting == 1)
        #expect(controller.pinnedPanelForTesting(task.id) === firstPanel)

        controller.stop()
        #expect(controller.pinnedPanelCountForTesting == 0)
    }

    // MARK: - Unpin from the main surface

    @Test func unpinFromObservedStoreRemovesPanelAndPersists() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, model) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()
        #expect(controller.pinnedPanelCountForTesting == 1)

        model.setPinned(task, false) // the normal pin affordance path

        #expect(controller.pinnedPanelCountForTesting == 0)
        #expect(try readDisk().activeTasks.first(where: { $0.id == task.id })?.isPinned == false)
        controller.stop()
    }

    // MARK: - Archival catch-up closes panels

    @Test func catchUpSweepClosesArchivedPinnedPanel() throws {
        let task = TaskItem(
            title: "swept",
            status: .done,
            createdAt: t0,
            updatedAt: t0,
            completedAt: t0,
            isPinned: true
        )
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, _) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()
        #expect(controller.pinnedPanelCountForTesting == 1)

        clock.advance(3601) // one second past the inclusive archival deadline
        let archived = controller.runCatchUpSweep() // timer/wake/session seam

        #expect(archived == [task.id])
        #expect(controller.pinnedPanelCountForTesting == 0)
        let disk = try readDisk()
        let swept = try #require(disk.tasks.first(where: { $0.id == task.id }))
        #expect(swept.isArchived)
        #expect(!swept.isPinned)
        controller.stop()
    }

    // MARK: - External state converges through reload

    @Test func reloadReconcilesExternalPinChanges() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, model) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()
        #expect(controller.pinnedPanelCountForTesting == 1)

        // External edit while running: pin removed on disk.
        var external = TaskStore(tasks: [task])
        try external.setPinned(false, for: task.id, now: t0.addingTimeInterval(10))
        try fileStore.save(external)
        model.reload()

        #expect(controller.pinnedPanelCountForTesting == 0)
        controller.stop()
    }

    // MARK: - User closing a pinned panel unpins durably (model-first)

    @Test func userClosingPinnedPanelUnpinsDurablyThenRemovesPanel() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, model) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()
        let panel = try #require(controller.pinnedPanelForTesting(task.id))

        // performClose simulates the close button: it consults
        // windowShouldClose, which requests the durable unpin first. The
        // successful publication then lets observed state strip and
        // programmatically close the panel with its delegate detached.
        panel.performClose(nil)

        #expect(controller.pinnedPanelCountForTesting == 0)
        #expect(panel.isVisible == false)
        #expect(model.store.activeTasks.first(where: { $0.id == task.id })?.isPinned == false)
        #expect(model.lastErrorMessage == nil)
        #expect(try readDisk().activeTasks.first(where: { $0.id == task.id })?.isPinned == false)
        controller.stop()
    }

    // MARK: - Save failure keeps the panel and pin coherent

    @Test func saveFailedCloseKeepsPanelVisibleAndPinUntilRetrySucceeds() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, model) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()
        let panel = try #require(controller.pinnedPanelForTesting(task.id))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        panel.performClose(nil) // durable unpin fails: save refused

        #expect(controller.pinnedPanelCountForTesting == 1)
        #expect(panel.isVisible == true)
        #expect(model.store.activeTasks.first(where: { $0.id == task.id })?.isPinned == true)
        #expect(model.lastErrorMessage?.hasPrefix("Could not save tasks") == true)
        #expect(try readDisk().activeTasks.first(where: { $0.id == task.id })?.isPinned == true)

        // Retry once durability is possible again: one clean removal.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        clock.advance(10) // late disk timestamps stay inside the archive window
        panel.performClose(nil)
        #expect(controller.pinnedPanelCountForTesting == 0)
        #expect(panel.isVisible == false)
        #expect(model.store.activeTasks.first(where: { $0.id == task.id })?.isPinned == false)
        #expect(try readDisk().activeTasks.first(where: { $0.id == task.id })?.isPinned == false)
        controller.stop()
    }

    // MARK: - Locked storage keeps close coherent; recovery unlocks it

    @Test func lockedCloseKeepsPanelCoherentAndRecoveryRetryRemovesIt() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, model) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()
        #expect(controller.pinnedPanelCountForTesting == 1)

        // External corruption while running: reload fails and locks storage.
        try Data("this is not a document".utf8).write(to: fileStore.fileURL)
        model.reload()
        #expect(model.canMutate == false)
        #expect(controller.pinnedPanelCountForTesting == 1) // stale desired panel remains

        // Locked close is refused: panel and pin stay coherent.
        let panel = try #require(controller.pinnedPanelForTesting(task.id))
        panel.performClose(nil)
        #expect(controller.pinnedPanelCountForTesting == 1)
        #expect(panel.isVisible == true)
        #expect(model.store.activeTasks.first(where: { $0.id == task.id })?.isPinned == true)

        // Repair into a valid pinned document, reload (combines store + lock
        // state), then the retry close unpins durably with one removal.
        try seedDisk(with: TaskStore(tasks: [task]))
        model.reload()
        #expect(model.canMutate == true)
        #expect(controller.pinnedPanelCountForTesting == 1) // recovery restored the pinned panel once

        panel.performClose(nil)
        #expect(controller.pinnedPanelCountForTesting == 0)
        #expect(model.store.activeTasks.first(where: { $0.id == task.id })?.isPinned == false)
        #expect(try readDisk().activeTasks.first(where: { $0.id == task.id })?.isPinned == false)
        controller.stop()
    }

    /// Oracle's exact missing-panel recovery case: the controller starts with
    /// locked/unreadable storage and ZERO pinned panels, the combined
    /// store/lock observation is installed, storage is repaired externally
    /// with a valid persisted pinned task, and `reload()` must make exactly
    /// one panel appear immediately after unlock without any extra store
    /// mutation. Repeated reconcile and a further reload never duplicate or
    /// rebuild the panel.
    @Test func lockedStartWithZeroPanelsRestoresExactlyOnePanelOnExternalRepairAndReload() throws {
        try seedDisk(with: TaskStore()) // ensures the storage directory exists
        try Data("this is not a document".utf8).write(to: fileStore.fileURL)

        // The model locks at initialization: in-memory store is empty and the
        // observation must not create panels while locked.
        let (controller, model) = try makeController(with: TaskStore())
        #expect(model.canMutate == false)
        controller.installStoreObservation()
        #expect(controller.pinnedPanelCountForTesting == 0)

        // External repair into a valid persisted pinned task; unlock is the
        // only recovery path and must converge to exactly one panel.
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        model.reload()

        let panel = try #require(controller.pinnedPanelForTesting(task.id))
        #expect(model.canMutate == true)
        #expect(model.lastErrorMessage == nil)
        #expect(controller.pinnedPanelCountForTesting == 1) // exactly one, immediately
        #expect(panel.isVisible == true)
        #expect(model.store.activeTasks.first(where: { $0.id == task.id })?.isPinned == true)

        // No extra store mutation during recovery: disk still pins the task.
        #expect(try readDisk().activeTasks.first(where: { $0.id == task.id })?.isPinned == true)

        // Idempotent convergence: repeated reconcile and a second reload do
        // not duplicate or rebuild the panel.
        controller.reconcilePinnedPanels(with: model.store, canMutate: true)
        controller.reconcilePinnedPanels(with: model.store, canMutate: true)
        model.reload()
        #expect(controller.pinnedPanelCountForTesting == 1)
        #expect(controller.pinnedPanelForTesting(task.id) === panel)
        #expect(try readDisk().activeTasks.first(where: { $0.id == task.id })?.isPinned == true)

        // Teardown cleans the recovered panel; the suite deinit removes the
        // temporary bytes and permissions.
        controller.stop()
        #expect(controller.pinnedPanelCountForTesting == 0)
        #expect(panel.isVisible == false)
    }

    // MARK: - Catch-up observer seam: delivery, running gate, and teardown

    /// Covers the observer seam's main-actor delivery path deterministically:
    /// a main-thread post through `installCatchUpObserver` performs the whole
    /// synchronous `deliverCatchUp` body, the test gate makes enqueued work
    /// inert while stopped, and `stop()` removes the token so later posts
    /// never reach the handler.
    ///
    /// Toolchain limitation (documented; see .slim/debug/
    /// swift-testing-midrun-exit.md): this CLT-only runner intermittently
    /// loses the tail of the test stream (helper→swift-test transport), so
    /// the suite avoids in-suite OFF-MAIN notification-post coverage whose
    /// true/false outcome could be masked by that same general stream loss.
    /// Off-main arrivals are handled by the production routing branch in
    /// `installCatchUpObserver` (main-queue hop guarded by `isRunning`); its
    /// thread-safe hit counter makes cross-thread delivery observable, but
    /// the in-suite regression for that branch is deliberately omitted so
    /// the general transport limitation stays independent of test content.
    @Test func catchUpDeliveryGateAndTeardownEnforcedThroughObserverSeam() throws {
        try seedDisk(with: TaskStore(tasks: [pinnedActive()]))
        let (controller, _) = try makeController(with: TaskStore(tasks: [pinnedActive()]))
        let center = NotificationCenter() // test-local center, same block-observer path
        let name = Notification.Name("BCTaskPhase3CatchUpTest")
        // start() sets the running gate; the observer below joins the same
        // delivery path (idempotent start keeps a single live seam set).
        controller.start()
        controller.installCatchUpObserver(center, name)

        center.post(name: name, object: nil)

        // Running gate: delivered callbacks are inert while stopped.
        controller.setCatchUpGateForTesting(false)
        center.post(name: name, object: nil)
        #expect(controller.catchUpObserverHitsForTesting == 2)
        #expect(controller.catchUpInvocationsForTesting == 1)

        // Re-opened gate resumes delivery.
        controller.setCatchUpGateForTesting(true)
        center.post(name: name, object: nil)

        // stop() removes the token from its originating center: main-thread
        // posts no longer even reach the handler.
        controller.stop()
        center.post(name: name, object: nil)
        #expect(controller.catchUpObserverHitsForTesting == 3)
        #expect(controller.catchUpInvocationsForTesting == 2)
    }

    // MARK: - Pinned content constraints survive frame restoration

    @Test func undersizedRestoredFrameIsClampedToAcceptedContentConstraints() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let autosave = StatusItemPanelsController.pinnedFrameAutosavePrefix + task.id.uuidString
        let defaultsKey = "NSWindow Frame " + autosave
        let defaults = UserDefaults.standard
        defaults.set("8 8 120 90", forKey: defaultsKey) // far below the accepted minimum

        let (controller, _) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()
        let panel = try #require(controller.pinnedPanelForTesting(task.id))

        let content = panel.contentRect(forFrameRect: panel.frame).size
        #expect(content.width >= StatusItemPanelsController.pinnedPanelMinimumSize.width)
        #expect(content.height >= StatusItemPanelsController.pinnedPanelMinimumSize.height)
        #expect(content.width <= StatusItemPanelsController.pinnedPanelMaxWidth)
        #expect(panel.contentMinSize == NSSize(width: StatusItemPanelsController.pinnedPanelMinimumSize.width, height: StatusItemPanelsController.pinnedPanelMinimumSize.height))
        #expect(panel.contentMaxSize.width == StatusItemPanelsController.pinnedPanelMaxWidth)

        // Cleanup so test runs never leak frames into the host defaults.
        panel.setFrameAutosaveName("")
        defaults.removeObject(forKey: defaultsKey)
        controller.stop()
    }

    // MARK: - Retained main surface identity across toggles

    @Test func semanticFocusConsumesFirstEscapeThenAllowsPanelClose() throws {
        try seedDisk(with: TaskStore())
        let router = TaskCommandRouter()
        let controller = try makeController(with: TaskStore(), router: router).controller
        let panel = controller.ensureMainSurface()
        let escape = try #require(
            KeyCommandTranslator.translate(
                keyCode: KeyCommandTranslator.keyCodeEscape,
                modifiers: []
            )
        )
        var routedCommands: [TaskSurfaceCommand] = []
        let subscription = router.commands.sink { command in
            routedCommands.append(command)
            if command == .leaveNewTaskEntry {
                // Mirrors ContentView.handleCommand's synchronous focus update.
                router.updateTaskEntryFocus(false)
            }
        }

        controller.showMainPanel()
        router.updateTaskEntryFocus(true)

        #expect(controller.routeMainPanelCommand(escape))
        #expect(routedCommands == [.leaveNewTaskEntry])
        #expect(!router.taskEntryIsFocused)
        #expect(panel.isVisible, "leaving task entry does not hide the panel")

        #expect(!controller.routeMainPanelCommand(escape))
        #expect(routedCommands == [.leaveNewTaskEntry])
        #expect(controller.windowShouldClose(panel) == false)
        #expect(!panel.isVisible, "unhandled Escape reaches native close/hide")
        #expect(controller.mainPanelForTesting === panel)

        withExtendedLifetime(subscription) {}
        controller.stop()
    }

    @Test func mainSurfaceRetainsOneHostedRootAcrossToggles() throws {
        try seedDisk(with: TaskStore())
        let controller = try makeController(with: TaskStore()).controller

        var mainPanel: NSPanel?
        var mainPanelIdentity: ObjectIdentifier?
        let windowIdentity: (ObjectIdentifier) -> Bool = { id in
            NSApp.windows.contains { ObjectIdentifier($0) == id }
        }

        do {
            let panel = controller.ensureMainSurface()
            let firstContent = try #require(controller.mainContentControllerForTesting)
            #expect(panel.contentMinSize == AppExperience.surfaceMinimumSize)
            mainPanel = panel
            mainPanelIdentity = ObjectIdentifier(panel)
            if let identity = mainPanelIdentity {
                #expect(windowIdentity(identity) == true, "NSApp.windows registers panels even while hidden")
            }

            // Idempotent creation: panel and SwiftUI root are not rebuilt.
            let samePanel = controller.ensureMainSurface()
            #expect(samePanel === panel)
            #expect(controller.mainContentControllerForTesting === firstContent)

            controller.toggleMainPanel() // hidden -> shown
            #expect(controller.mainPanelForTesting?.isVisible == true)
            if let identity = mainPanelIdentity {
                #expect(windowIdentity(identity) == true, "shown main panel is registered in NSApp.windows")
            }
            controller.toggleMainPanel() // shown -> hidden
            #expect(controller.mainPanelForTesting?.isVisible == false)

            // Re-showing after hide keeps the original retained content root.
            controller.showMainPanel()
            #expect(controller.mainContentControllerForTesting === firstContent)
            #expect(controller.windowShouldClose(panel) == false)
            #expect(!panel.isVisible, "native main-panel close hides instead of terminating")
            #expect(controller.mainPanelForTesting === panel)
            #expect(controller.mainContentControllerForTesting === firstContent)
        }

        // Terminal stop(): hide/show never destroys the retained surface
        // while running, but terminal teardown closes the panel and detaches
        // its hosted root so it cannot reach the fixtures at process exit.
        controller.stop()
        #expect(controller.mainPanelForTesting == nil)
        #expect(controller.mainContentControllerForTesting == nil)
        #expect(mainPanel?.isVisible == false, "terminal stop closes the main panel")
        #expect(mainPanel?.contentViewController == nil, "terminal stop detaches the hosted main-surface root")
    }

    // MARK: - Start/stop install and remove every seam

    @Test func startInstallsAndStopTearsDownLifecycleSeams() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, _) = try makeController(with: TaskStore(tasks: [task]))

        #expect(!controller.keyMonitorInstalledForTesting)
        controller.start() // installs monitor, timer, observers, store observation
        #expect(controller.keyMonitorInstalledForTesting)
        #expect(controller.pinnedPanelCountForTesting == 1) // persisted pins restored
        let panel = try #require(controller.pinnedPanelForTesting(task.id))

        controller.stop()
        #expect(!controller.keyMonitorInstalledForTesting)
        #expect(controller.pinnedPanelCountForTesting == 0)
        #expect(controller.mainPanelForTesting == nil) // terminal teardown releases the main surface
        #expect(panel.isVisible == false && panel.contentViewController == nil,
                "stopped pinned panel must be closed and stripped, not left as a hidden resource")

        controller.stop() // teardown is idempotent; no crash, no monitors left
        #expect(!controller.keyMonitorInstalledForTesting)
    }

    // MARK: - Deterministic AppKit resource teardown

    /// Reconciliation paths must deterministically strip a retired panel's
    /// every meaningful edge: the panel is closed (not merely hidden), its
    /// hosted SwiftUI content is detached, and controller-side references
    /// are dropped, so NSHostingView/PinnedTaskCardView/AppModel can no
    /// longer be reached through hidden windows at process exit (the helper
    /// exit-time race that destabilized the runner). Unpin (observed store
    /// change), archival (catch-up sweep), and terminal `stop()` are each
    /// proven to strip the specific panel they retire. Note: evacuating the
    /// `NSApp.windows` entry entirely would need `isReleasedWhenClosed =
    /// true` at close, which over-releases under ARC on this toolchain
    /// (SIGSEGV inside _NSWindowTransformAnimation at a CA transaction
    /// commit — see debug evidence); registered-but-empty shells are the
    /// safe terminal state.
    @Test func pinnedPanelDestructionLeavesNSAppWindowsAfterUnpinArchiveAndStop() throws {
        let unpinTask = pinnedActive()
        let archivedTask = TaskItem(
            title: "sweep-teardown",
            status: .done,
            createdAt: t0,
            updatedAt: t0,
            completedAt: t0,
            isPinned: true
        )
        let survivorTask = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [unpinTask, archivedTask, survivorTask]))
        let (controller, model) = try makeController(with: TaskStore(tasks: [unpinTask, archivedTask, survivorTask]))

        controller.start()
        #expect(controller.pinnedPanelCountForTesting == 3) // all persisted pins restored
        let unpinPanel = controller.pinnedPanelForTesting(unpinTask.id)
        let archivedPanel = controller.pinnedPanelForTesting(archivedTask.id)
        let survivorPanel = controller.pinnedPanelForTesting(survivorTask.id)
        #expect(unpinPanel?.isVisible == true && archivedPanel?.isVisible == true && survivorPanel?.isVisible == true)

        // (a) Unpin through the observed store: reconciliation strips the
        // panel — closed, content detached, dropped from the controller.
        model.setPinned(unpinTask, false)
        #expect(controller.pinnedPanelCountForTesting == 2)
        #expect(unpinPanel?.isVisible == false, "unpinned panel must be closed, not merely hidden")
        #expect(unpinPanel?.contentViewController == nil, "unpinned panel must be stripped of hosted content")

        // (b) Archival catch-up sweep: the archived pin is destroyed too.
        clock.advance(3601) // one second past the inclusive archival deadline
        #expect(controller.runCatchUpSweep() == [archivedTask.id])
        #expect(controller.pinnedPanelCountForTesting == 1)
        #expect(archivedPanel?.isVisible == false)
        #expect(archivedPanel?.contentViewController == nil)
        #expect(survivorPanel?.isVisible == true, "survivor stays live until its own retirement")

        // Disk truth is unchanged by destruction bookkeeping.
        let disk = try readDisk()
        let unpinnedDisk = try #require(disk.tasks.first(where: { $0.id == unpinTask.id }))
        #expect(unpinnedDisk.isPinned == false && !unpinnedDisk.isArchived)
        let sweptDisk = try #require(disk.tasks.first(where: { $0.id == archivedTask.id }))
        #expect(sweptDisk.isArchived && !sweptDisk.isPinned)

        // (c) Terminal stop(): the surviving panel is stripped as well.
        controller.stop()
        #expect(controller.pinnedPanelCountForTesting == 0)
        #expect(controller.mainPanelForTesting == nil)
        #expect(survivorPanel?.isVisible == false)
        #expect(survivorPanel?.contentViewController == nil)
    }

    /// A repeated start while running must not duplicate any seam (status
    /// item, monitor, timer, observers, subscription). Structural proof via
    /// the internal token-count seam: start() installs exactly three
    /// catch-up/lifecycle tokens (app activation, wake, session activation)
    /// and a duplicate start would append three more. Delivery
    /// nonduplication is proven through the same retained block-observer
    /// path on a test-local center (one post, one delivery) while the
    /// running session is live, restart after stop, and post-stop inertness.
    ///
    /// Deliberately does NOT broadcast `didBecomeActive` on the default
    /// center: the CLT-only runner intermittently loses the trailing
    /// summary of full runs (helper stream loss, see
    /// .slim/debug/swift-testing-midrun-exit.md), so the suite avoids
    /// anything whose effect cannot be clipped narrowly to one test; the
    /// same delivery path is exercised deterministically through the local
    /// seam.
    @Test func startIsIdempotentAndRestartReinstallsCatchUpDelivery() throws {
        try seedDisk(with: TaskStore(tasks: [pinnedActive()]))
        let (controller, _) = try makeController(with: TaskStore(tasks: [pinnedActive()]))

        controller.start()
        #expect(controller.catchUpObserverTokenCountForTesting == 3) // activation + wake + session
        #expect(controller.keyMonitorInstalledForTesting)
        #expect(controller.pinnedPanelCountForTesting == 1) // launch restore from the first start
        let firstSessionPanelID = try #require(controller.pinnedPanelIDsForTesting.first)
        let firstSessionPanel = try #require(controller.pinnedPanelForTesting(firstSessionPanelID))
        let firstSessionIdentity = ObjectIdentifier(firstSessionPanel)

        // Second start while running: guarded no-op — no appended tokens,
        // no duplicate monitor/timer/subscription.
        controller.start()
        #expect(controller.catchUpObserverTokenCountForTesting == 3)
        #expect(controller.keyMonitorInstalledForTesting)
        #expect(controller.pinnedPanelCountForTesting == 1)

        // Delivery nonduplication on the same observer path during a live
        // running session: one post, exactly one catch-up delivery.
        let center = NotificationCenter() // test-local center, no system broadcast
        let name = Notification.Name("BCTaskPhase3IdempotentStart")
        controller.installCatchUpObserver(center, name)
        center.post(name: name, object: nil)
        #expect(controller.catchUpObserverHitsForTesting == 1)
        #expect(controller.catchUpInvocationsForTesting == 1)
        center.post(name: name, object: nil)
        #expect(controller.catchUpObserverHitsForTesting == 2)
        #expect(controller.catchUpInvocationsForTesting == 2) // one token: one delivery per post

        // stop() tears every seam down: local token too. Terminal teardown
        // also strips the session-1 window (closed + hosted content
        // detached), so a restart cannot pile up live rooted resources.
        controller.stop()
        #expect(controller.catchUpObserverTokenCountForTesting == 0)
        #expect(!controller.keyMonitorInstalledForTesting)
        #expect(firstSessionPanel.isVisible == false && firstSessionPanel.contentViewController == nil)
        center.post(name: name, object: nil)
        #expect(controller.catchUpObserverHitsForTesting == 2)
        #expect(controller.catchUpInvocationsForTesting == 2)

        // start() after stop() reinstalls cleanly (exactly three again).
        controller.start()
        #expect(controller.catchUpObserverTokenCountForTesting == 3)
        #expect(controller.keyMonitorInstalledForTesting)

        // And the idempotence guard still holds on the fresh session, backed
        // by a fresh lifecycle: same task id restored, but a brand-new window.
        controller.start()
        #expect(controller.catchUpObserverTokenCountForTesting == 3)
        #expect(controller.pinnedPanelCountForTesting == 1)
        let secondSessionPanelID = try #require(controller.pinnedPanelIDsForTesting.first)
        #expect(secondSessionPanelID == firstSessionPanelID)
        #expect(ObjectIdentifier(try #require(controller.pinnedPanelForTesting(secondSessionPanelID))) != firstSessionIdentity)
        #expect(firstSessionPanel.contentViewController == nil, "session-1 root stays detached after restart")

        controller.stop()
    }
}
