import Testing
import Foundation
@testable import BCTaskCore

@Suite("JSON persistence, strict invariants, and catch-up")
final class PersistenceTests {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    private let t1 = Date(timeIntervalSince1970: 3_000_000 + 600)
    private let tempRoot: URL
    private let dirA: URL
    private let dirB: URL

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskTests-\(UUID().uuidString)", isDirectory: true)
        tempRoot = root
        dirA = root.appendingPathComponent("A", isDirectory: true)
        dirB = root.appendingPathComponent("B", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Round trip

    @Test func roundTripPreservesEveryTaskState() throws {
        var todo = TaskItem.make(title: "todo task", now: t0)
        todo.isPinned = true
        var doing = TaskItem.make(title: "doing task", now: t0 + 5)
        doing.status = .doing
        var done = TaskItem.make(title: "done task", now: t0 + 10)
        done.status = .done
        done.completedAt = t0 + 3600 - 60 // deadline still ahead relative to reload
        var archived = TaskItem.make(title: "archived task", now: t0 - 10)
        archived.status = .done
        archived.completedAt = t0 - 7200
        archived.archivedAt = t0 - 3000
        let original = TaskStore(tasks: [todo, doing, done, archived])

        let fileStore = TaskFileStore(directory: dirA)
        try fileStore.save(original)
        let reloaded = try fileStore.load(now: t0 + 11)

        #expect(reloaded == original, "round trip must preserve all state exactly")

        // And the on-disk bytes round trip byte-for-byte.
        let reencoded = try TaskDocumentCodec.encode(reloaded)
        let persistedData = try Data(contentsOf: fileStore.fileURL)
        #expect(reencoded == persistedData)
    }

    @Test func saveCreatesDirectoryAndAtomicFileOnDemand() throws {
        let fileStore = TaskFileStore(directory: dirA)
        let store = TaskStore(tasks: [TaskItem.make(title: "task", now: t0)])

        try fileStore.save(store)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileStore.fileURL.path)
        #expect((attributes[.size] as? Int) ?? 0 > 0)
        let reloaded = try fileStore.load(now: t0)
        #expect(reloaded.tasks.count == 1)
    }

    @Test func injectedDirectoriesAreFullyIndependent() throws {
        let storeA = TaskStore(tasks: [TaskItem.make(title: "in A", now: t0)])
        let storeB = TaskStore(tasks: [TaskItem.make(title: "in B", now: t0)])
        let fileA = TaskFileStore(directory: dirA)
        let fileB = TaskFileStore(directory: dirB)

        try fileA.save(storeA)
        try fileB.save(storeB)

        #expect(try fileA.load(now: t0).tasks.map(\.title) == ["in A"])
        #expect(try fileB.load(now: t0).tasks.map(\.title) == ["in B"])
    }

    // MARK: - Catch-up archival

    @Test func loadCatchesUpLongPastDeadlineFromPersistedCompletedAt() throws {
        var done = TaskItem.make(title: "overdue", now: t0 - 5400)
        done.status = .done
        done.completedAt = t0 - 5400 // completed 90 minutes before load-now
        done.isPinned = true
        let fileStore = TaskFileStore(directory: dirA)
        try fileStore.save(TaskStore(tasks: [done]))

        let reloaded = try fileStore.load(now: t0)
        let task = try #require(reloaded.tasks.first)
        #expect(task.isArchived == true)
        #expect(task.archivedAt == t0, "archival time records the injected reload instant")
        #expect(task.isPinned == false, "catch-up archival must unpin")
        #expect(task.completedAt == t0 - 5400, "completedAt survives archival")
    }

    @Test func catchUpIsPersistedSoRelaunchesDoNotRearchive() throws {
        var done = TaskItem.make(title: "overdue", now: t0 - 7200)
        done.status = .done
        done.completedAt = t0 - 7200
        let fileStore = TaskFileStore(directory: dirA)
        try fileStore.save(TaskStore(tasks: [done]))

        _ = try fileStore.load(now: t0) // first load archives + persists
        let second = try fileStore.load(now: t0 + 30)

        let task = try #require(second.tasks.first)
        #expect(task.archivedAt == t0, "catch-up archival must be durable; a later reload keeps the original archivedAt")
    }

    @Test func loadLeavesFileUntouchedWhenSweepChangesNothing() throws {
        var done = TaskItem.make(title: "fresh", now: t0)
        done.status = .done
        done.completedAt = t0
        let fileStore = TaskFileStore(directory: dirA)
        try fileStore.save(TaskStore(tasks: [done]))
        Thread.sleep(forTimeInterval: 0.05)
        let before = try FileManager.default.attributesOfItem(atPath: fileStore.fileURL.path)[.modificationDate] as? Date

        _ = try fileStore.load(now: t0 + 10) // nothing archived: no write allowed

        let after = try FileManager.default.attributesOfItem(atPath: fileStore.fileURL.path)[.modificationDate] as? Date
        #expect(before == after, "a catch-up sweep that changes nothing must not rewrite the document")
    }

    @Test func loadKeepsFreshlyCompletedTasksActive() throws {
        var done = TaskItem.make(title: "fresh", now: t0 - 59)
        done.status = .done
        done.completedAt = t0 - 59 // deadline is one hour after load-now t0, so still ahead
        let fileStore = TaskFileStore(directory: dirA)
        try fileStore.save(TaskStore(tasks: [done]))

        let reloaded = try fileStore.load(now: t0)
        #expect(try #require(reloaded.tasks.first).isArchived == false)
    }

    @Test func roundTripIsDeterministicAcrossInjectedStores() throws {
        var done = TaskItem.make(title: "overdue", now: t0 - 7200)
        done.status = .done
        done.completedAt = t0 - 7200
        let documentStore = TaskStore(tasks: [done])

        try TaskFileStore(directory: dirA).save(documentStore)
        try TaskFileStore(directory: dirB).save(documentStore)

        let loadedA = try TaskFileStore(directory: dirA).load(now: t0)
        let loadedB = try TaskFileStore(directory: dirB).load(now: t0)
        #expect(loadedA == loadedB, "same document + same injected now must produce identical stores")
    }

    // MARK: - Storage resolution

    @Test func standardResolutionHasNoTemporaryFallback() {
        // Structural contract: standard() resolves Application Support or
        // throws; nothing substitutes a transient location. Verify the
        // resolved layout directly.
        let resolved = try? TaskFileStore.standard(fileManager: .default)
        let directory = resolved?.directory
        #expect(directory?.lastPathComponent == TaskFileStore.applicationDirectoryName)
        #expect(directory?.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func loadFromMissingFileInitializesAndPersistsEmptyStore() throws {
        let fileStore = TaskFileStore(directory: dirA)

        let store = try fileStore.load(now: t0)
        #expect(store.tasks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileStore.fileURL.path), "first launch must establish a valid document")
        _ = try fileStore.load(now: t0) // reloading an existing empty document stays stable
    }

    // MARK: - Strict document invariants (both directions)

    /// Raw, unvalidated document bytes for decode-side rejection tests.
    private func rawDocument(tasks: [TaskItem], schemaVersion: Int = 1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(TaskDocument(schemaVersion: schemaVersion, tasks: tasks))
    }

    private func task(_ title: String,
                      status: TaskStatus,
                      completedAt: Date? = nil,
                      archivedAt: Date? = nil,
                      pinned: Bool = false) -> TaskItem {
        var task = TaskItem.make(title: title, now: t0)
        task.status = status
        task.completedAt = completedAt
        task.archivedAt = archivedAt
        task.isPinned = pinned
        return task
    }

    /// Invalid schema-1 shapes paired with the documented reason the codec
    /// uses for each, so rejection tests assert exact error values and stay
    /// honest about which invariant was violated.
    ///
    /// Note: a Done task with completedAt + archivedAt + unpinned is a VALID
    /// archived task (archivedness is classified by archivedAt), so it is not
    /// in this list. The "archived task must be Done" rule already covers
    /// Todo/Doing tasks carrying archivedAt.
    private var invalidFixtures: [(task: TaskItem, reason: String)] {
        [
            (task("todo-with-completion", status: .todo, completedAt: t0), "active todo task must not carry completedAt"),
            (task("doing-with-completion", status: .doing, completedAt: t0), "active doing task must not carry completedAt"),
            (task("doing-with-archive", status: .doing, archivedAt: t0), "archived task must be Done"),
            (task("done-without-completion", status: .done), "active Done task requires completedAt"),
            (task("archived-pinned", status: .done, completedAt: t0, archivedAt: t1, pinned: true), "archived task must be unpinned"),
            (task("archived-without-completed", status: .done, archivedAt: t1), "archived task must carry completedAt"),
        ]
    }

    @Test func decodingRejectsEveryInvalidShape() throws {
        for fixture in invalidFixtures {
            #expect(throws: TaskFileError.invalidTaskShape(id: fixture.task.id, reason: fixture.reason)) {
                try TaskDocumentCodec.decode(try rawDocument(tasks: [fixture.task]))
            }
        }
    }

    @Test func decodingRejectsDuplicateTaskIDs() throws {
        let first = task("first", status: .todo)
        var second = first
        second.title = "second"
        #expect(throws: TaskFileError.duplicateTaskID(id: first.id)) {
            try TaskDocumentCodec.decode(try rawDocument(tasks: [first, second]))
        }
    }

    @Test func decodingRejectsUnknownSchemaVersion() throws {
        let document = TaskDocument(schemaVersion: 999, tasks: [])
        let data = try JSONEncoder().encode(document)

        #expect(throws: TaskFileError.unsupportedSchema(999)) {
            try TaskDocumentCodec.decode(data)
        }
    }

    @Test func encodingRejectsEveryInvalidShape() {
        for fixture in invalidFixtures {
            #expect(throws: TaskFileError.invalidTaskShape(id: fixture.task.id, reason: fixture.reason)) {
                try TaskDocumentCodec.encode(TaskStore(tasks: [fixture.task]))
            }
        }
    }

    @Test func encodingRejectsDuplicateTaskIDs() throws {
        let first = task("first", status: .todo)
        var second = first
        second.title = "second"
        #expect(throws: TaskFileError.duplicateTaskID(id: first.id)) {
            try TaskDocumentCodec.encode(TaskStore(tasks: [first, second]))
        }
    }

    @Test func rejectedSaveLeavesExistingFileUntouched() throws {
        let good = TaskStore(tasks: [task("good", status: .todo)])
        let fileStore = TaskFileStore(directory: dirA)
        try fileStore.save(good)
        let originalBytes = try Data(contentsOf: fileStore.fileURL)

        for fixture in invalidFixtures {
            #expect(throws: TaskFileError.self) {
                try fileStore.save(TaskStore(tasks: [fixture.task]))
            }
            let currentBytes = try Data(contentsOf: fileStore.fileURL)
            #expect(currentBytes == originalBytes, "a rejected save must leave the existing document untouched")
        }
    }

    @Test func validMixedStateEncodesRoundTripsAndReloads() throws {
        let original = TaskStore(tasks: [
            task("todo", status: .todo),
            task("doing", status: .doing),
            task("done", status: .done, completedAt: t0),
            task("archived", status: .done, completedAt: t0 - 7200, archivedAt: t0 - 3000),
        ])
        let fileStore = TaskFileStore(directory: dirA)
        try fileStore.save(original)
        let reloaded = try fileStore.load(now: t0)
        #expect(reloaded.tasks == original.tasks)
    }
}
