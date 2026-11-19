import Testing
import Foundation
import AppKit
import SwiftUI
import BCTaskCore
@testable import BCTask

/// Phase 3 focused evidence:
/// - the pure shortcut translator only recognizes the accepted native
///   shortcuts and rejects everything else deterministically,
/// - pinned reconciliation converges to exactly one menu-bar ticker per live
///   pinned task across launch restore, pin/unpin, archival catch-up, lock,
///   and external state reload — without duplicate ids or feedback loops,
/// - a ticker toggles its task's floating card, and hiding or closing the
///   card never touches the model,
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

    @Test @MainActor func notesEditingFocusDefersEveryCommandToTheTextSystem() {
        // While a multiline task-notes editor holds keyboard focus, no
        // task-surface command is consumed: arrow keys move the caret, Tab
        // and Escape keep their text-editing meanings, and Cmd-Backspace /
        // Cmd-arrows stay standard edits.
        let router = TaskCommandRouter()
        router.updateNotesEditingFocus(true)
        #expect(router.notesEditingIsFocused)

        for command in [
            TaskSurfaceCommand.focusNewTask,
            .focusPreviousTask,
            .focusNextTask,
            .moveFocusedTaskBackward,
            .moveFocusedTaskForward,
            .pinFocusedTask,
            .deleteFocusedTask,
            .leaveNewTaskEntry,
            .toggleProjection,
        ] {
            #expect(
                MainPanelKeyCommandBridge.commandToConsume(
                    command,
                    taskEntryIsFocused: true,
                    notesEditingIsFocused: router.notesEditingIsFocused
                ) == nil
            )
            #expect(
                MainPanelKeyCommandBridge.commandToConsume(
                    command,
                    taskEntryIsFocused: false,
                    notesEditingIsFocused: router.notesEditingIsFocused
                ) == nil
            )
        }

        // Leaving the notes editor restores the legacy routing exactly.
        router.updateNotesEditingFocus(false)
        #expect(!router.notesEditingIsFocused)
        #expect(
            MainPanelKeyCommandBridge.commandToConsume(
                .leaveNewTaskEntry,
                taskEntryIsFocused: false,
                notesEditingIsFocused: router.notesEditingIsFocused
            ) == nil
        )
        #expect(
            MainPanelKeyCommandBridge.commandToConsume(
                .pinFocusedTask,
                taskEntryIsFocused: false,
                notesEditingIsFocused: router.notesEditingIsFocused
            ) == .pinFocusedTask
        )
    }

    @Test func notesEditingFlagDefaultsToLegacyBridgeBehavior() {
        // Omitting the defaulted parameter (every pre-notes call site) keeps
        // the documented legacy semantics byte-for-byte.
        #expect(MainPanelKeyCommandBridge.commandToConsume(.deleteFocusedTask, taskEntryIsFocused: true) == nil)
        #expect(MainPanelKeyCommandBridge.commandToConsume(.deleteFocusedTask, taskEntryIsFocused: false) == .deleteFocusedTask)
        #expect(MainPanelKeyCommandBridge.commandToConsume(.leaveNewTaskEntry, taskEntryIsFocused: true) == .leaveNewTaskEntry)
        #expect(MainPanelKeyCommandBridge.commandToConsume(.leaveNewTaskEntry, taskEntryIsFocused: false) == nil)
        #expect(MainPanelKeyCommandBridge.commandToConsume(.toggleProjection, taskEntryIsFocused: false) == .toggleProjection)
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

    @Test func desiredTickerIDsFilterArchivedAndUnpinnedTasks() {
        let pinnedActiveTask = TaskItem(title: "active", createdAt: t0, updatedAt: t0, isPinned: true)
        let regular = TaskItem(title: "plain", createdAt: t0, updatedAt: t0)
        let pinnedDone = TaskItem(title: "done", status: .done, createdAt: t0, updatedAt: t0, completedAt: t0, isPinned: true)
        // Data drift: an archived task that still claims isPinned (external file).
        let archivedPinned = TaskItem(title: "archived", status: .done, createdAt: t0, updatedAt: t0, completedAt: t0, archivedAt: t0, isPinned: true)
        let store = TaskStore(tasks: [pinnedActiveTask, regular, pinnedDone, archivedPinned])

        #expect(StatusItemPanelsController.desiredPinnedTaskIDs(in: store) == [pinnedActiveTask.id, pinnedDone.id])
        #expect(StatusItemPanelsController.desiredPinnedTaskIDs(in: TaskStore(tasks: [])).isEmpty)
    }

    // MARK: - Launch restoration and no-duplicate reconciliation

    @Test func launchRestoresOneTickerPerPersistedPinWithoutOpeningCards() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, _) = try makeController(with: TaskStore(tasks: [task]))

        controller.installStoreObservation() // immediate publish restores persisted pins
        #expect(controller.pinnedTickerIDsForTesting == [task.id])
        let ticker = try #require(controller.pinnedTickerForTesting(task.id))
        #expect(ticker.length == StatusItemPanelsController.pinnedTickerWidth)
        #expect(controller.pinnedTickerTextForTesting(task.id) == task.title)
        #expect(controller.pinnedPanelCountForTesting == 0, "a pin no longer opens a floating card by itself")

        // Reconciliation idempotence: repeated publishes never duplicate or
        // rebuild tickers.
        controller.reconcilePinnedTasks(with: TaskStore(tasks: [task]))
        controller.reconcilePinnedTasks(with: TaskStore(tasks: [task]))
        #expect(controller.pinnedTickerIDsForTesting == [task.id])
        #expect(controller.pinnedTickerForTesting(task.id) === ticker)

        controller.stop()
        #expect(controller.pinnedTickerIDsForTesting.isEmpty)
    }

    // MARK: - The ticker toggles its card; the card never touches the pin

    @Test func tickerTogglesItsCardWithoutTouchingThePin() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, model) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()

        controller.togglePinnedCard(task.id) // ticker click
        let card = try #require(controller.pinnedPanelForTesting(task.id))
        #expect(card.isVisible)
        #expect(card.isFloatingPanel == true)
        #expect(card.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(card.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(card.title == task.title)
        #expect(card.contentMinSize == NSSize(width: StatusItemPanelsController.pinnedPanelMinimumSize.width, height: StatusItemPanelsController.pinnedPanelMinimumSize.height))
        #expect(card.contentMaxSize.width == StatusItemPanelsController.pinnedPanelMaxWidth)

        controller.togglePinnedCard(task.id) // second click hides it
        #expect(card.isVisible == false)
        #expect(controller.pinnedPanelForTesting(task.id) === card)
        #expect(card.contentViewController != nil, "a hidden card keeps its hosted content for the next show")
        #expect(controller.pinnedTickerIDsForTesting == [task.id])
        #expect(model.store.tasks.first?.isPinned == true)
        #expect(try readDisk().tasks.first?.isPinned == true)

        controller.togglePinnedCard(task.id) // third click shows the same card again
        #expect(card.isVisible)
        #expect(controller.pinnedPanelCountForTesting == 1)
        controller.stop()
    }

    @Test func closingTheCardHidesItAndKeepsThePinAndTicker() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, model) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()
        controller.togglePinnedCard(task.id)
        let card = try #require(controller.pinnedPanelForTesting(task.id))

        // performClose simulates the close button: it consults
        // windowShouldClose, which only hides the card, with no model write.
        card.performClose(nil)

        #expect(card.isVisible == false)
        #expect(controller.pinnedPanelForTesting(task.id) === card)
        #expect(card.contentViewController != nil)
        #expect(controller.pinnedTickerIDsForTesting == [task.id])
        #expect(model.store.tasks.first?.isPinned == true)
        #expect(model.lastErrorMessage == nil)
        #expect(try readDisk().tasks.first?.isPinned == true)

        controller.togglePinnedCard(task.id) // the next click shows it again
        #expect(card.isVisible)
        #expect(controller.pinnedPanelForTesting(task.id) === card)
        controller.stop()
    }

    // MARK: - Unpin from the main surface

    @Test func unpinRemovesTickerAndOpenCardAndPersists() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, model) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()
        controller.togglePinnedCard(task.id)
        let card = try #require(controller.pinnedPanelForTesting(task.id))

        model.setPinned(task, false) // the normal pin affordance path

        #expect(controller.pinnedTickerIDsForTesting.isEmpty)
        #expect(controller.pinnedPanelCountForTesting == 0)
        #expect(card.isVisible == false && card.contentViewController == nil)
        #expect(try readDisk().activeTasks.first(where: { $0.id == task.id })?.isPinned == false)
        controller.stop()
    }

    // MARK: - Archival catch-up retires tickers

    @Test func catchUpSweepRetiresArchivedTicker() throws {
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
        #expect(controller.pinnedTickerIDsForTesting == [task.id])

        clock.advance(3601) // one second past the inclusive archival deadline
        let archived = controller.runCatchUpSweep() // timer/wake/session seam

        #expect(archived == [task.id])
        #expect(controller.pinnedTickerIDsForTesting.isEmpty)
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
        #expect(controller.pinnedTickerIDsForTesting == [task.id])

        // External edit while running: pin removed on disk.
        var external = TaskStore(tasks: [task])
        try external.setPinned(false, for: task.id, now: t0.addingTimeInterval(10))
        try fileStore.save(external)
        model.reload()

        #expect(controller.pinnedTickerIDsForTesting.isEmpty)
        controller.stop()
    }

    @Test func tickerAndOpenCardFollowTitleChanges() throws {
        let task = pinnedActive(title: "short")
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, model) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()
        controller.togglePinnedCard(task.id)
        let ticker = try #require(controller.pinnedTickerForTesting(task.id))

        // External rename while running (the app itself has no rename).
        let renamed = TaskItem(
            id: task.id,
            title: "A much longer title that has to scroll through the ticker",
            status: task.status,
            createdAt: t0,
            updatedAt: t0.addingTimeInterval(10),
            isPinned: true
        )
        try fileStore.save(TaskStore(tasks: [renamed]))
        model.reload()

        #expect(controller.pinnedTickerTextForTesting(task.id) == renamed.title)
        #expect(controller.pinnedTickerForTesting(task.id) === ticker, "a rename updates the ticker in place")
        #expect(ticker.button?.toolTip == renamed.title)
        #expect(controller.pinnedPanelForTesting(task.id)?.title == renamed.title)
        controller.stop()
    }

    // MARK: - Locked storage keeps the ticker; recovery reuses it

    @Test func lockedStorageKeepsTheTickerAndItsCardMutationFree() throws {
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        let (controller, model) = try makeController(with: TaskStore(tasks: [task]))
        controller.installStoreObservation()
        let ticker = try #require(controller.pinnedTickerForTesting(task.id))

        // External corruption while running: reload fails and locks storage.
        try Data("this is not a document".utf8).write(to: fileStore.fileURL)
        model.reload()
        #expect(model.canMutate == false)
        #expect(controller.pinnedTickerIDsForTesting == [task.id]) // the displayed snapshot keeps its ticker

        // The card still opens (it shows the locked state with Reload), and
        // closing it only hides it.
        controller.togglePinnedCard(task.id)
        let card = try #require(controller.pinnedPanelForTesting(task.id))
        #expect(card.isVisible)
        card.performClose(nil)
        #expect(card.isVisible == false)
        #expect(model.store.tasks.first?.isPinned == true)

        // Repair and reload: unlocked, and the same ticker carries on.
        try seedDisk(with: TaskStore(tasks: [task]))
        model.reload()
        #expect(model.canMutate == true)
        #expect(controller.pinnedTickerIDsForTesting == [task.id])
        #expect(controller.pinnedTickerForTesting(task.id) === ticker)
        controller.stop()
    }

    /// The controller starts with locked/unreadable storage and ZERO tickers,
    /// storage is repaired externally with a valid persisted pinned task, and
    /// `reload()` must make exactly one ticker appear immediately, without
    /// any store mutation. Repeated reconcile and a further reload never
    /// duplicate or rebuild it.
    @Test func lockedStartWithZeroTickersRestoresExactlyOneOnExternalRepairAndReload() throws {
        try seedDisk(with: TaskStore()) // ensures the storage directory exists
        try Data("this is not a document".utf8).write(to: fileStore.fileURL)

        // The model locks at initialization with an empty in-memory store.
        let (controller, model) = try makeController(with: TaskStore())
        #expect(model.canMutate == false)
        controller.installStoreObservation()
        #expect(controller.pinnedTickerIDsForTesting.isEmpty)

        // External repair into a valid persisted pinned task; unlock is the
        // only recovery path and must converge to exactly one ticker.
        let task = pinnedActive()
        try seedDisk(with: TaskStore(tasks: [task]))
        model.reload()

        let ticker = try #require(controller.pinnedTickerForTesting(task.id))
        #expect(model.canMutate == true)
        #expect(model.lastErrorMessage == nil)
        #expect(controller.pinnedTickerIDsForTesting == [task.id]) // exactly one, immediately
        #expect(controller.pinnedPanelCountForTesting == 0)
        // No store mutation during recovery: disk still pins the task.
        #expect(try readDisk().activeTasks.first(where: { $0.id == task.id })?.isPinned == true)

        // Idempotent convergence: repeated reconcile and a second reload do
        // not duplicate or rebuild the ticker.
        controller.reconcilePinnedTasks(with: model.store)
        controller.reconcilePinnedTasks(with: model.store)
        model.reload()
        #expect(controller.pinnedTickerIDsForTesting == [task.id])
        #expect(controller.pinnedTickerForTesting(task.id) === ticker)

        controller.stop()
        #expect(controller.pinnedTickerIDsForTesting.isEmpty)
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
        #expect(controller.pinnedTickerIDsForTesting == [task.id]) // persisted pins restored
        controller.togglePinnedCard(task.id)
        let card = try #require(controller.pinnedPanelForTesting(task.id))

        controller.stop()
        #expect(!controller.keyMonitorInstalledForTesting)
        #expect(controller.pinnedTickerIDsForTesting.isEmpty)
        #expect(controller.pinnedPanelCountForTesting == 0)
        #expect(controller.mainPanelForTesting == nil) // terminal teardown releases the main surface
        #expect(card.isVisible == false && card.contentViewController == nil,
                "a stopped card must be closed and stripped, not left as a hidden resource")

        controller.stop() // teardown is idempotent; no crash, no monitors left
        #expect(!controller.keyMonitorInstalledForTesting)
    }

    // MARK: - Deterministic AppKit resource teardown

    /// Reconciliation paths must deterministically strip a retired card's
    /// every meaningful edge: the card is closed (not merely hidden), its
    /// hosted SwiftUI content is detached, and controller-side references
    /// are dropped, so NSHostingView/PinnedTaskCardView/AppModel can no
    /// longer be reached through hidden windows at process exit (the helper
    /// exit-time race that destabilized the runner). Unpin (observed store
    /// change), archival (catch-up sweep), and terminal `stop()` are each
    /// proven to strip the specific card they retire, along with its ticker.
    /// Note: evacuating the `NSApp.windows` entry entirely would need
    /// `isReleasedWhenClosed = true` at close, which over-releases under ARC
    /// on this toolchain (SIGSEGV inside _NSWindowTransformAnimation at a CA
    /// transaction commit — see debug evidence); registered-but-empty shells
    /// are the safe terminal state.
    @Test func pinnedCardDestructionStripsPanelsAfterUnpinArchiveAndStop() throws {
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
        #expect(controller.pinnedTickerIDsForTesting == [unpinTask.id, archivedTask.id, survivorTask.id])
        for task in [unpinTask, archivedTask, survivorTask] {
            controller.togglePinnedCard(task.id)
        }
        #expect(controller.pinnedPanelCountForTesting == 3)
        let unpinPanel = controller.pinnedPanelForTesting(unpinTask.id)
        let archivedPanel = controller.pinnedPanelForTesting(archivedTask.id)
        let survivorPanel = controller.pinnedPanelForTesting(survivorTask.id)
        #expect(unpinPanel?.isVisible == true && archivedPanel?.isVisible == true && survivorPanel?.isVisible == true)

        // (a) Unpin through the observed store: reconciliation strips the
        // card — closed, content detached, dropped from the controller.
        model.setPinned(unpinTask, false)
        #expect(controller.pinnedPanelCountForTesting == 2)
        #expect(controller.pinnedTickerIDsForTesting == [archivedTask.id, survivorTask.id])
        #expect(unpinPanel?.isVisible == false, "an unpinned card must be closed, not merely hidden")
        #expect(unpinPanel?.contentViewController == nil, "an unpinned card must be stripped of hosted content")

        // (b) Archival catch-up sweep: the archived pin's card is destroyed
        // too, even while hidden.
        controller.togglePinnedCard(archivedTask.id)
        #expect(archivedPanel?.isVisible == false)
        clock.advance(3601) // one second past the inclusive archival deadline
        #expect(controller.runCatchUpSweep() == [archivedTask.id])
        #expect(controller.pinnedPanelCountForTesting == 1)
        #expect(controller.pinnedTickerIDsForTesting == [survivorTask.id])
        #expect(archivedPanel?.isVisible == false)
        #expect(archivedPanel?.contentViewController == nil)
        #expect(survivorPanel?.isVisible == true, "survivor stays live until its own retirement")

        // Disk truth is unchanged by destruction bookkeeping.
        let disk = try readDisk()
        let unpinnedDisk = try #require(disk.tasks.first(where: { $0.id == unpinTask.id }))
        #expect(unpinnedDisk.isPinned == false && !unpinnedDisk.isArchived)
        let sweptDisk = try #require(disk.tasks.first(where: { $0.id == archivedTask.id }))
        #expect(sweptDisk.isArchived && !sweptDisk.isPinned)

        // (c) Terminal stop(): the surviving card and ticker go as well.
        controller.stop()
        #expect(controller.pinnedPanelCountForTesting == 0)
        #expect(controller.pinnedTickerIDsForTesting.isEmpty)
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
        #expect(controller.pinnedTickerIDsForTesting.count == 1) // launch restore from the first start
        let pinnedID = try #require(controller.pinnedTickerIDsForTesting.first)
        let firstSessionTicker = try #require(controller.pinnedTickerForTesting(pinnedID))
        controller.togglePinnedCard(pinnedID)
        let firstSessionCard = try #require(controller.pinnedPanelForTesting(pinnedID))

        // Second start while running: guarded no-op — no appended tokens,
        // no duplicate monitor/timer/subscription/ticker.
        controller.start()
        #expect(controller.catchUpObserverTokenCountForTesting == 3)
        #expect(controller.keyMonitorInstalledForTesting)
        #expect(controller.pinnedTickerIDsForTesting == [pinnedID])
        #expect(controller.pinnedTickerForTesting(pinnedID) === firstSessionTicker)

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
        // also strips the session-1 card (closed + hosted content detached),
        // so a restart cannot pile up live rooted resources.
        controller.stop()
        #expect(controller.catchUpObserverTokenCountForTesting == 0)
        #expect(!controller.keyMonitorInstalledForTesting)
        #expect(firstSessionCard.isVisible == false && firstSessionCard.contentViewController == nil)
        center.post(name: name, object: nil)
        #expect(controller.catchUpObserverHitsForTesting == 2)
        #expect(controller.catchUpInvocationsForTesting == 2)

        // start() after stop() reinstalls cleanly (exactly three again).
        controller.start()
        #expect(controller.catchUpObserverTokenCountForTesting == 3)
        #expect(controller.keyMonitorInstalledForTesting)

        // And the idempotence guard still holds on the fresh session, backed
        // by a fresh lifecycle: same task id restored, but a brand-new
        // ticker, and no card until it is clicked again.
        controller.start()
        #expect(controller.catchUpObserverTokenCountForTesting == 3)
        #expect(controller.pinnedTickerIDsForTesting == [pinnedID])
        #expect(controller.pinnedTickerForTesting(pinnedID) !== firstSessionTicker)
        #expect(controller.pinnedPanelCountForTesting == 0)
        #expect(firstSessionCard.contentViewController == nil, "session-1 root stays detached after restart")

        controller.stop()
    }
}
