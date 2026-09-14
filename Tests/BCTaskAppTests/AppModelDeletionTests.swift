import Testing
import Foundation
import BCTaskCore
@testable import BCTask

/// Focused regression evidence for AppModel deletion:
/// - `delete` persists durably and is gone for a fresh model on the same store,
/// - a locked store refuses deletion without crashing or mutating,
/// - deleting a pinned task removes it from the desired pinned-panel set.
@MainActor
final class AppModelDeletionTests {
    private let t0: Date
    private let clock: MutableDeletionClock
    private let dir: URL
    private let fileStore: TaskFileStore
    private let tempRoot: URL

    /// Disposable scenario fixture: each suite instance gets its own disk
    /// directory and clock.
    init() {
        t0 = Date(timeIntervalSince1970: 6_000_000)
        clock = MutableDeletionClock(start: t0)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskAppModelDeletionTests-\(UUID().uuidString)", isDirectory: true)
        dir = tempRoot.appendingPathComponent("store", isDirectory: true)
        fileStore = TaskFileStore(directory: dir)
    }

    deinit {
        // Restore write permission before the recursive temp cleanup (the
        // locked-delete test may leave the store directory read-only).
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func modelWithStorage() -> AppModel {
        AppModel(now: { [clock] in clock.read() }) { self.fileStore }
    }

    private func persistedStore() throws -> TaskStore {
        try fileStore.load(now: clock.read())
    }

    @Test func deletePersistsAndIsAbsentForFreshModel() throws {
        let first = TaskItem.make(title: "first", now: t0)
        let second = TaskItem.make(title: "second", now: t0)
        try fileStore.save(TaskStore(tasks: [first, second]))
        let model = modelWithStorage()

        model.delete(first)

        #expect(model.store.tasks.map(\.id) == [second.id])
        #expect(model.lastErrorMessage == nil)
        #expect(try persistedStore().tasks.map(\.id) == [second.id], "deletion is durable on disk")

        // A fresh model on the same store must not resurrect the task.
        let fresh = modelWithStorage()
        #expect(fresh.store.tasks.map(\.id) == [second.id])
        #expect(fresh.activeTasks.contains(where: { $0.id == first.id }) == false)
    }

    @Test func deleteIsRefusedWhileStorageIsLocked() throws {
        let task = TaskItem.make(title: "kept", now: t0)
        try fileStore.save(TaskStore(tasks: [task]))
        let model = modelWithStorage()

        // Corrupt the document and reload: mutations are locked while the
        // last accepted snapshot stays displayed.
        try Data("this is not a document".utf8).write(to: fileStore.fileURL)
        model.reload()
        #expect(model.canMutate == false)

        model.delete(task)

        #expect(model.activeTasks.map(\.id) == [task.id], "the task stays displayed after a refused delete")
        #expect(model.lastErrorMessage != nil)
        #expect(model.storageError != nil, "the lock remains until a successful reload")
        #expect(try Data(contentsOf: fileStore.fileURL) == Data("this is not a document".utf8),
                "locked storage must never rewrite unreadable bytes")
    }

    @Test func deletingPinnedTaskRemovesItFromDesiredPanelSet() throws {
        let pinned = TaskItem(title: "pinned", createdAt: t0, updatedAt: t0, isPinned: true)
        let survivor = TaskItem(title: "survivor", createdAt: t0, updatedAt: t0, isPinned: true)
        try fileStore.save(TaskStore(tasks: [pinned, survivor]))
        let model = modelWithStorage()
        #expect(StatusItemPanelsController.desiredPinnedPanelIDs(in: model.store) == [pinned.id, survivor.id])

        model.delete(pinned)

        #expect(model.store.tasks.contains(where: { $0.id == pinned.id }) == false)
        #expect(StatusItemPanelsController.desiredPinnedPanelIDs(in: model.store) == [survivor.id],
                "deleting a pinned task closes its floating panel via reconciliation")
    }
}

/// Tiny mutable clock so each scenario controls the observed instant.
private final class MutableDeletionClock: @unchecked Sendable {
    private(set) var instant: Date
    init(start: Date) { instant = start }
    func read() -> Date { instant }
    func advance(to newInstant: Date) { instant = newInstant }
}
