import Testing
import Foundation
import BCTaskCore
@testable import BCTask

/// Focused regression evidence for AppModel persistence safety:
/// - save failures never publish dirty state and never touch disk,
/// - load failures lock mutations and retain the last accepted snapshot,
/// - successful recovery clears errors and persists,
/// - the catch-up sweep runs before commands (rejection at the deadline),
/// - the sweep-and-persist seam reports archived panel IDs and avoids
///   no-op writes.
@MainActor
final class AppModelPersistenceSafetyTests {
    private let t0: Date
    private let deadline: Date
    private let clock: MutableClock
    private let dir: URL
    private let fileStore: TaskFileStore
    private let tempRoot: URL

    /// Disposable scenario fixture: each suite instance gets its own disk
    /// directory and clock.
    init() {
        t0 = Date(timeIntervalSince1970: 5_000_000)
        deadline = t0.addingTimeInterval(3600)
        clock = MutableClock(start: t0)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskAppModelTests-\(UUID().uuidString)", isDirectory: true)
        dir = tempRoot.appendingPathComponent("store", isDirectory: true)
        fileStore = TaskFileStore(directory: dir)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func modelWithStorage(at root: TaskFileStore) -> AppModel {
        AppModel(now: { [clock] in clock.read() }) { root }
    }

    private func persistedStore() throws -> TaskStore {
        try fileStore.load(now: clock.read())
    }

    private func persistedBytes() throws -> Data {
        try Data(contentsOf: fileStore.fileURL)
    }

    @Test func corruptedDocumentAtStartupLocksStorageAndLeavesBytesUntouched() throws {
        let junkData = try _rawDocument(schemaVersion: 999, tasks: [])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try junkData.write(to: fileStore.fileURL, options: .atomic)
        let originalBytes = try Data(contentsOf: fileStore.fileURL)

        let model = AppModel(now: { [clock] in clock.read() }) { self.fileStore }

        #expect(model.storageError != nil, "an unsupported document locks storage at startup")
        #expect(model.canMutate == false)
        #expect(model.store.tasks.isEmpty)

        model.add("must be refused")
        #expect(model.store.tasks.isEmpty)
        #expect(model.lastErrorMessage != nil)
        #expect(try Data(contentsOf: fileStore.fileURL) == originalBytes, "locked storage must never rewrite unreadable bytes")
    }

    @Test func failedSaveKeepsDisplayedStateAndDiskAtLastAcceptedState() throws {
        let model = AppModel(now: { [clock] in clock.read() }) { self.fileStore }
        #expect(model.canMutate)
        let emptyDocBytes = try persistedBytes()

        // Make the store directory unwritable so the atomic save fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }

        model.add("hello")
        #expect(model.store.tasks.isEmpty, "a failed save must not publish the candidate")
        #expect(model.lastErrorMessage != nil)
        #expect(model.storageError == nil, "a save failure does not lock storage; retry stays possible")
        #expect(try persistedBytes() == emptyDocBytes, "the disk document must remain at the last accepted state")
    }

    @Test func recoveryAfterSaveFailureClearsErrorAndPersists() throws {
        let model = AppModel(now: { [clock] in clock.read() }) { self.fileStore }

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        model.add("hello")
        #expect(model.lastErrorMessage != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        model.add("second") // succeeds now
        #expect(model.lastErrorMessage == nil, "stale errors clear only on success")
        #expect(model.store.tasks.map(\.title) == ["second"], "the refused write was never published; only accepted state flows through")
        let onDisk = try persistedStore()
        #expect(onDisk.tasks.map(\.title) == ["second"])
    }

    @Test func failedReloadRetainsAcceptedSnapshotAndLocks() throws {
        var done = TaskItem.make(title: "accepted", now: t0)
        done.status = .doing
        try fileStore.save(TaskStore(tasks: [done]))
        let model = AppModel(now: { [clock] in clock.read() }) { self.fileStore }
        let acceptedBytes = try persistedBytes()

        // Corrupt the document, then reload.
        try "{\"schemaVersion\":99,\"tasks\":[]}".write(to: fileStore.fileURL, atomically: true, encoding: .utf8)
        model.reload()

        #expect(model.storageError != nil, "failed reload locks mutations")
        #expect(model.canMutate == false)
        #expect(model.store.tasks == [done], "the last accepted snapshot must survive a failed reload")

        model.add("during lock")
        #expect(model.store.tasks == [done], "mutations are refused while storage is locked")
        #expect(try Data(contentsOf: fileStore.fileURL) != acceptedBytes, "the corrupting attempt still sits on disk")

        // Repair the document; successful reload recovers and unlocks.
        try FileManager.default.removeItem(at: fileStore.fileURL)
        try fileStore.save(TaskStore(tasks: [done]))
        model.reload()

        #expect(model.storageError == nil, "successful load clears the lock")
        #expect(model.lastErrorMessage == nil)
        #expect(model.store.tasks == [done])
        model.add("after recovery")
        #expect(model.store.tasks.map(\.title) == ["accepted", "after recovery"])
        #expect(try persistedStore().tasks.map(\.title) == ["accepted", "after recovery"])
    }

    @Test func catchUpRunsBeforeCommandAndRejectsReopenExactlyAtDeadline() throws {
        var done = TaskItem.make(title: "subject", now: t0)
        done.status = .done
        done.completedAt = t0
        try fileStore.save(TaskStore(tasks: [done]))
        let model = AppModel(now: { [clock] in clock.read() }) { self.fileStore }
        #expect(model.store.tasks.first?.isArchived == false)

        clock.advance(to: deadline) // inclusive boundary for the one-hour deadline
        model.setStatus(done, to: .todo)

        let state = try #require(model.store.tasks.first)
        #expect(state.isArchived == true, "the catch-up archived the subject before the command applied")
        #expect(model.lastErrorMessage != nil, "the reopen must be rejected; restoration is the only path")

        // Durable: the archival is on disk, not just in memory.
        let onDisk = try #require(try persistedStore().tasks.first)
        #expect(onDisk.isArchived == true)
        #expect(onDisk.archivedAt == deadline)

        #expect(model.archivedPanelClosures == [done.id], "the seam must carry the archived ID for Phase 3")
        let closure = try #require(model.consumeArchivedPanelClosures().first)
        #expect(closure == done.id)
        #expect(model.archivedPanelClosures.isEmpty)

        // Restoration is the only mutating path for the archived task.
        model.restore(state)
        let restored = try #require(model.store.tasks.first)
        #expect(restored.status == .todo)
        #expect(restored.archivedAt == nil)
        #expect(restored.completedAt == nil)
        #expect(try #require(try persistedStore().tasks.first).status == .todo)
    }

    @Test func reopenOneSecondBeforeDeadlineSucceeds() throws {
        var done = TaskItem.make(title: "subject", now: t0)
        done.status = .done
        done.completedAt = t0
        try fileStore.save(TaskStore(tasks: [done]))
        let model = AppModel(now: { [clock] in clock.read() }) { self.fileStore }

        clock.advance(to: deadline.addingTimeInterval(-1))
        model.setStatus(done, to: .todo)

        let state = try #require(model.store.tasks.first)
        #expect(state.status == .todo)
        #expect(state.completedAt == nil)
        #expect(state.isArchived == false)
        #expect(model.lastErrorMessage == nil)
        #expect(try persistedStore().tasks == [state], "the reopen persists durably")
        #expect(model.archivedPanelClosures.isEmpty)
    }

    @Test func sweepAndPersistReportsPanelIDsAndAvoidsNoOpWrites() throws {
        var done = TaskItem.make(title: "subject", now: t0)
        done.status = .done
        done.completedAt = t0
        try fileStore.save(TaskStore(tasks: [done]))
        let model = AppModel(now: { [clock] in clock.read() }) { self.fileStore }

        clock.advance(to: deadline.addingTimeInterval(-5))
        #expect(model.sweepAndPersist() == [], "nothing archived: no panel IDs, no write")

        clock.advance(to: deadline)
        let archived = model.sweepAndPersist()
        #expect(archived == [done.id], "the seam reports the archived task ID")
        let onDisk = try #require(try persistedStore().tasks.first)
        #expect(onDisk.isArchived == true)
        #expect(onDisk.archivedAt == deadline)

        let mtime1 = try FileManager.default.attributesOfItem(atPath: fileStore.fileURL.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        #expect(model.sweepAndPersist() == [], "an already-archived sweep must not rewrite the document")
        let mtime2 = try FileManager.default.attributesOfItem(atPath: fileStore.fileURL.path)[.modificationDate] as? Date
        #expect(mtime1 == mtime2)

        _ = model.consumeArchivedPanelClosures()
        #expect(model.archivedPanelClosures.isEmpty)
    }

    @Test func failedInitResolutionIntegratesWithLockedState() {
        let failed = AppModel(now: { self.t0 }) {
            throw CocoaError(.fileReadUnknown)
        }
        #expect(failed.storageError != nil, "storage resolution failure must surface as the locked state")
        #expect(failed.canMutate == false)
        #expect(failed.store.tasks.isEmpty)
        failed.add("never lands")
        #expect(failed.store.tasks.isEmpty)
    }

    @Test func reloadRecoversAfterExternalRepairOfCorruptStartupDocument() throws {
        // Corrupt/unsupported document at startup: storage was resolved, so
        // the model must retain it and Reload must be able to recover.
        let junk = try _rawDocument(schemaVersion: 999, tasks: [])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try junk.write(to: fileStore.fileURL, options: .atomic)
        let corruptBytes = try Data(contentsOf: fileStore.fileURL)

        let model = AppModel(now: { [clock] in clock.read() }) { self.fileStore }
        #expect(model.storageError != nil, "a corrupt startup document locks storage")
        #expect(model.store.tasks.isEmpty)

        model.add("while locked")
        #expect(model.store.tasks.isEmpty, "mutations are refused while locked")
        #expect(try Data(contentsOf: fileStore.fileURL) == corruptBytes, "locked storage must not rewrite unreadable bytes")

        // External repair: replace the document with valid (empty) bytes.
        let repaired = try TaskDocumentCodec.encode(TaskStore())
        try repaired.write(to: fileStore.fileURL, options: .atomic)

        model.reload()

        #expect(model.storageError == nil, "a successful reload after repair unlocks mutation")
        #expect(model.lastErrorMessage == nil)
        #expect(model.store.tasks.isEmpty, "the repaired document displays")
        #expect(model.canMutate)

        // The first post-recovery mutation must persist to disk.
        model.add("after repair")
        #expect(model.store.tasks.map(\.title) == ["after repair"])
        #expect(try persistedStore().tasks.map(\.title) == ["after repair"])
    }

    @Test func reloadRetriesStorageResolutionAfterInitialResolutionFailure() throws {
        var storageReady = false
        let resolvedStore = fileStore
        let model = AppModel(now: { [clock] in clock.read() }) {
            guard storageReady else { throw CocoaError(.fileReadUnknown) }
            return resolvedStore
        }

        #expect(model.storageError != nil, "initial resolution failure locks storage")
        #expect(model.canMutate == false)
        #expect(model.store.tasks.isEmpty)

        // While storage stays unavailable, reload keeps the lock and display.
        model.reload()
        #expect(model.storageError != nil)
        #expect(model.store.tasks.isEmpty)

        model.add("while unavailable")
        #expect(model.store.tasks.isEmpty, "mutations are still refused")

        // Storage becomes available; reload must retry resolution.
        storageReady = true
        model.reload()

        #expect(model.storageError == nil, "reload retries resolution instead of giving up permanently")
        #expect(model.lastErrorMessage == nil)
        #expect(model.canMutate)
        #expect(model.store.tasks.isEmpty, "the recovered store presents its document")
        #expect(FileManager.default.fileExists(atPath: fileStore.fileURL.path), "a resolved store establishes the document")

        // The first post-recovery mutation must persist to disk.
        model.add("after recovery")
        #expect(model.store.tasks.map(\.title) == ["after recovery"])
        #expect(try persistedStore().tasks.map(\.title) == ["after recovery"])
    }
}

/// Tiny mutable clock so each scenario controls the observed instant.
private final class MutableClock: @unchecked Sendable {
    private(set) var instant: Date
    init(start: Date) { instant = start }
    func read() -> Date { instant }
    func advance(to newInstant: Date) { instant = newInstant }
}

/// Raw unsupported-schema bytes that bypass the codec's public API.
private func _rawDocument(schemaVersion: Int, tasks: [TaskItem]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    return try encoder.encode(TaskDocument(schemaVersion: schemaVersion, tasks: tasks))
}
