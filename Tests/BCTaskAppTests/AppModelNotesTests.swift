import Testing
import Foundation
import BCTaskCore
@testable import BCTask

/// Focused evidence for the AppModel notes seam:
/// - a notes commit publishes and persists verbatim and reports success,
/// - identical notes are a no-op that never rewrites the document yet still
///   count as committed (true without a write),
/// - locked storage, failed disk saves, and archived tasks all refuse the
///   commit and report false so editors can keep the user's draft mounted,
/// - a stale-baseline commit (a concurrent editor changed the stored notes
///   first) is refused instead of silently overwriting it, and the
///   re-anchored retry wins.
@MainActor
final class AppModelNotesTests {
    private let t0: Date
    private let clock: NotesClock
    private let tempRoot: URL
    private let storeDirectory: URL
    private let fileStore: TaskFileStore

    /// Disposable scenario fixture: each suite instance gets its own disk
    /// directory and clock (same shape as the persistence-safety suites).
    init() {
        t0 = Date(timeIntervalSince1970: 6_000_000)
        clock = NotesClock(start: t0)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskAppModelNotesTests-\(UUID().uuidString)", isDirectory: true)
        storeDirectory = tempRoot.appendingPathComponent("store", isDirectory: true)
        fileStore = TaskFileStore(directory: storeDirectory)
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

        let committed = model.setNotes(task, from: task.notes, to: "Detail: https://example.com/how")
        #expect(committed, "a successful commit reports true")

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
        model.setNotes(task, from: task.notes, to: "same text")
        let bytesAfterSet = try Data(contentsOf: fileStore.fileURL)

        clock.advance(to: t0.addingTimeInterval(90))
        let committed = model.setNotes(task, from: "same text", to: "same text")
        #expect(committed, "identical notes count as committed without writing")

        #expect(try Data(contentsOf: fileStore.fileURL) == bytesAfterSet, "identical notes must not rewrite the document")
        #expect(try #require(model.store.activeTasks.first).updatedAt == t0, "identical notes must not bump updatedAt")
        #expect(model.lastErrorMessage == nil)
    }

    @Test func setNotesClearingToEmptyPersists() throws {
        let model = makeModel()
        model.add("task")
        let task = try #require(model.store.activeTasks.first)
        model.setNotes(task, from: task.notes, to: "to be cleared")
        model.setNotes(task, from: "to be cleared", to: "")

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

        let committed = model.setNotes(task, from: task.notes, to: "refused note")
        #expect(committed == false, "a refused commit reports false so the editor can keep the draft")

        #expect(model.store.tasks == [task], "locked storage keeps the last accepted snapshot untouched")
        #expect(try #require(model.store.tasks.first).notes == "", "the refused notes commit must not publish")
        #expect(model.lastErrorMessage != nil)
    }

    @Test func setNotesReportsFailureWhenTheDiskSaveFails() throws {
        let model = makeModel()
        model.add("task")
        let task = try #require(model.store.activeTasks.first)
        let acceptedBytes = try Data(contentsOf: fileStore.fileURL)

        // Make the store directory unwritable so the atomic save fails
        // (same fixture shape as the persistence-safety suites).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: storeDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: storeDirectory.path
            )
        }

        let committed = model.setNotes(task, from: task.notes, to: "draft worth retrying")
        #expect(
            committed == false,
            "a failed save reports false so the editor keeps the draft"
        )

        #expect(try #require(model.store.activeTasks.first).notes == "", "a failed save never publishes the note")
        #expect(model.storageError == nil, "a save failure does not lock storage; retry stays possible")
        #expect(model.lastErrorMessage != nil)
        #expect(try Data(contentsOf: fileStore.fileURL) == acceptedBytes, "the disk document stays at the last accepted state")
    }

    @Test func setNotesIsRefusedForArchivedTasksAndReportsFailure() throws {
        var done = TaskItem.make(title: "archived subject", now: t0)
        done.status = .done
        done.completedAt = t0
        try fileStore.save(TaskStore(tasks: [done]))
        let model = makeModel()

        // Cross the one-hour deadline: the mutation's catch-up sweep
        // archives the subject first, then the notes command applies.
        clock.advance(to: t0.addingTimeInterval(3600))
        let committed = model.setNotes(done, from: done.notes, to: "note for the archive")
        #expect(
            committed == false,
            "a commit refused for an archived task reports false"
        )

        let state = try #require(model.store.tasks.first)
        #expect(state.isArchived, "the catch-up sweep archived the subject before the command applied")
        #expect(state.notes == "", "the refused notes commit must not publish")
        #expect(model.lastErrorMessage != nil)
    }

    @Test func concurrentEditorsCannotSilentlyOverwriteEachOther() throws {
        let model = makeModel()
        model.add("task")
        let task = try #require(model.store.activeTasks.first)

        // The main surface commits first with a fresh baseline: it succeeds.
        let mainCommitted = model.setNotes(task, from: task.notes, to: "main draft")
        #expect(mainCommitted)

        // The pinned panel's editor was opened before that commit, so it
        // still carries the ORIGINAL (empty) baseline: its commit conflicts
        // and must be refused rather than silently overwriting the main
        // surface's text.
        let pinnedCommitted = model.setNotes(task, from: "", to: "pinned draft")
        #expect(
            pinnedCommitted == false,
            "a stale-baseline commit is refused so concurrent editors cannot silently overwrite each other"
        )
        #expect(
            try #require(model.store.activeTasks.first).notes == "main draft",
            "the committed text survives the refused commit"
        )
        #expect(model.lastErrorMessage != nil, "the conflict is reported like any refused save")

        // The pinned editor re-anchors its baseline to the store (what the
        // vetoed close does) and closes again: the deliberate second close
        // wins.
        let retryCommitted = model.setNotes(task, from: "main draft", to: "pinned draft")
        #expect(retryCommitted)
        #expect(try #require(model.store.activeTasks.first).notes == "pinned draft")
    }
}

/// Tiny mutable clock so each scenario controls the observed instant.
private final class NotesClock: @unchecked Sendable {
    private(set) var instant: Date
    init(start: Date) { instant = start }
    func read() -> Date { instant }
    func advance(to newInstant: Date) { instant = newInstant }
}
