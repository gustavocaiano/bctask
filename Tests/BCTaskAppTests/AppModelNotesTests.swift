import Testing
import Foundation
import BCTaskCore
@testable import BCTask

/// Focused evidence for the AppModel notes seam:
/// - a notes commit publishes and persists verbatim,
/// - identical notes are a no-op and never rewrite the document,
/// - locked storage refuses notes edits and keeps the accepted snapshot.
@MainActor
final class AppModelNotesTests {
    private let t0: Date
    private let clock: NotesClock
    private let tempRoot: URL
    private let fileStore: TaskFileStore

    /// Disposable scenario fixture: each suite instance gets its own disk
    /// directory and clock (same shape as the persistence-safety suites).
    init() {
        t0 = Date(timeIntervalSince1970: 6_000_000)
        clock = NotesClock(start: t0)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskAppModelNotesTests-\(UUID().uuidString)", isDirectory: true)
        fileStore = TaskFileStore(directory: tempRoot.appendingPathComponent("store", isDirectory: true))
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeModel() -> AppModel {
        AppModel(now: { [clock] in clock.read() }) { self.fileStore }
    }

    @Test func setNotesPublishesAndPersistsTheNewNotes() throws {
        let model = makeModel()
        model.add("task")
        let task = try #require(model.store.activeTasks.first)

        model.setNotes(task, "Detail: https://example.com/how")

        let updated = try #require(model.store.activeTasks.first)
        #expect(updated.notes == "Detail: https://example.com/how", "the commit publishes verbatim notes")
        #expect(model.lastErrorMessage == nil)

        let onDisk = try #require(try fileStore.load(now: clock.read()).tasks.first)
        #expect(onDisk.notes == "Detail: https://example.com/how", "the commit persists to disk")

        // A fresh model over the same document displays the same notes.
        let relaunched = makeModel()
        #expect(try #require(relaunched.store.activeTasks.first).notes == "Detail: https://example.com/how")
    }

    @Test func setNotesWithUnchangedTextWritesNothing() throws {
        let model = makeModel()
        model.add("task")
        let task = try #require(model.store.activeTasks.first)
        model.setNotes(task, "same text")
        let bytesAfterSet = try Data(contentsOf: fileStore.fileURL)

        clock.advance(to: t0.addingTimeInterval(90))
        model.setNotes(task, "same text")

        #expect(try Data(contentsOf: fileStore.fileURL) == bytesAfterSet, "identical notes must not rewrite the document")
        #expect(try #require(model.store.activeTasks.first).updatedAt == t0, "identical notes must not bump updatedAt")
        #expect(model.lastErrorMessage == nil)
    }

    @Test func setNotesClearingToEmptyPersists() throws {
        let model = makeModel()
        model.add("task")
        let task = try #require(model.store.activeTasks.first)
        model.setNotes(task, "to be cleared")
        model.setNotes(task, "")

        #expect(try #require(model.store.activeTasks.first).notes == "")
        #expect(try #require(try fileStore.load(now: clock.read()).tasks.first).notes == "")
    }

    @Test func setNotesIsRefusedWhileStorageIsLocked() throws {
        var task = TaskItem.make(title: "locked subject", now: t0)
        task.status = .doing
        try fileStore.save(TaskStore(tasks: [task]))
        let model = makeModel()
        #expect(model.canMutate)

        // Corrupt the document, then reload: storage locks and keeps the last
        // accepted snapshot on screen.
        try "{\"schemaVersion\":99,\"tasks\":[]}".write(to: fileStore.fileURL, atomically: true, encoding: .utf8)
        model.reload()
        #expect(model.storageError != nil)

        model.setNotes(task, "refused note")

        #expect(model.store.tasks == [task], "locked storage keeps the last accepted snapshot untouched")
        #expect(try #require(model.store.tasks.first).notes == "", "the refused notes commit must not publish")
        #expect(model.lastErrorMessage != nil)
    }
}

/// Tiny mutable clock so each scenario controls the observed instant.
private final class NotesClock: @unchecked Sendable {
    private(set) var instant: Date
    init(start: Date) { instant = start }
    func read() -> Date { instant }
    func advance(to newInstant: Date) { instant = newInstant }
}
