import Testing
import Foundation
import BCTaskCore
@testable import BCTask

/// App-level seam evidence for the "pin mirrors Doing" domain rule: moving a
/// task to Doing through the model enters the desired pinned-panel set, and
/// moving it out leaves it — so the existing pinned-panel reconciliation
/// opens/closes the floating panel automatically.
@MainActor
final class AppModelPinResyncTests {
    private let t0: Date
    private let clock: MutableResyncClock
    private let dir: URL
    private let fileStore: TaskFileStore
    private let tempRoot: URL

    /// Disposable scenario fixture: each suite instance gets its own disk
    /// directory and clock.
    init() {
        t0 = Date(timeIntervalSince1970: 7_000_000)
        clock = MutableResyncClock(start: t0)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskAppModelPinResyncTests-\(UUID().uuidString)", isDirectory: true)
        dir = tempRoot.appendingPathComponent("store", isDirectory: true)
        fileStore = TaskFileStore(directory: dir)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func modelWithStorage() -> AppModel {
        AppModel(now: { [clock] in clock.read() }) { self.fileStore }
    }

    private func persistedStore() throws -> TaskStore {
        try fileStore.load(now: clock.read())
    }

    @Test func moveToDoingEntersAndLeavesTheDesiredPinnedPanelSet() throws {
        let task = TaskItem.make(title: "task", now: t0)
        try fileStore.save(TaskStore(tasks: [task]))
        let model = modelWithStorage()
        #expect(StatusItemPanelsController.desiredPinnedPanelIDs(in: model.store).isEmpty)

        clock.advance(to: t0.addingTimeInterval(10))
        model.setStatus(task, to: .doing)
        #expect(StatusItemPanelsController.desiredPinnedPanelIDs(in: model.store) == [task.id],
                "the Doing move pins, so reconciliation opens the floating panel")
        #expect(try persistedStore().tasks.first?.isPinned == true, "the auto-pin is durable")

        clock.advance(to: t0.addingTimeInterval(20))
        model.setStatus(try #require(model.activeTasks.first), to: .done)
        #expect(StatusItemPanelsController.desiredPinnedPanelIDs(in: model.store).isEmpty,
                "the Done move unpins, so reconciliation closes the floating panel")
        #expect(try persistedStore().tasks.first?.isPinned == false)
        #expect(model.lastErrorMessage == nil)
    }
}

/// Tiny mutable clock so each scenario controls the observed instant.
private final class MutableResyncClock: @unchecked Sendable {
    private(set) var instant: Date
    init(start: Date) { instant = start }
    func read() -> Date { instant }
    func advance(to newInstant: Date) { instant = newInstant }
}
