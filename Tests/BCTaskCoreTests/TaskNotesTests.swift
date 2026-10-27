import Testing
import Foundation
@testable import BCTaskCore

@Suite("Task notes seam")
struct TaskNotesTests {
    private let t0 = Date(timeIntervalSince1970: 4_800_000)
    private let t1 = Date(timeIntervalSince1970: 4_800_000 + 600)

    @Test func newTasksStartWithEmptyNotes() throws {
        var store = TaskStore()
        let added = try store.addTask(title: "fresh", now: t0)

        #expect(added.notes == "")
        #expect(try #require(store.tasks.first).notes == "")
        #expect(TaskItem.make(title: "made", now: t0).notes == "")
    }

    @Test func updateNotesSetsVerbatimTextAndBumpsUpdatedAt() throws {
        let task = TaskItem.make(title: "with link", now: t0)
        var store = TaskStore(tasks: [task])
        let payload = "Read https://example.com/spec first\n  spacing survives untrimmed"

        try store.updateNotes(id: task.id, to: payload, now: t1)

        let updated = try #require(store.tasks.first)
        #expect(updated.notes == payload, "notes are stored verbatim, including whitespace and newlines")
        #expect(updated.updatedAt == t1, "a real notes change bumps updatedAt")
        #expect(updated.createdAt == t0, "creation time never changes")
    }

    @Test func identicalNotesAreANoOpThatTouchesNothing() throws {
        var task = TaskItem.make(title: "stable", now: t0)
        task.notes = "same text"
        var store = TaskStore(tasks: [task])
        let before = store

        try store.updateNotes(id: task.id, to: "same text", now: t1)

        #expect(store == before, "rewriting identical notes is a no-op: no reorder, no timestamp churn")
    }

    @Test func clearingNotesToEmptyIsAllowed() throws {
        var task = TaskItem.make(title: "clear me", now: t0)
        task.notes = "temporary"
        var store = TaskStore(tasks: [task])

        try store.updateNotes(id: task.id, to: "", now: t1)

        let updated = try #require(store.tasks.first)
        #expect(updated.notes == "", "empty notes are valid (clearing)")
        #expect(updated.updatedAt == t1)
    }

    @Test func archivedTasksRejectNotesEdits() throws {
        var task = TaskItem.make(title: "done long ago", now: t0)
        task.status = .done
        task.completedAt = t0
        var store = TaskStore(tasks: [task])
        _ = store.sweep(now: t0.addingTimeInterval(TaskStore.archiveInterval))
        #expect(try #require(store.tasks.first).isArchived)

        #expect(throws: TaskStoreError.archivedTasksAreImmutable) {
            try store.updateNotes(id: task.id, to: "late note", now: t1)
        }
        #expect(try #require(store.tasks.first).notes == task.notes)
    }

    @Test func updateNotesUnknownIDThrowsNotFound() {
        var store = TaskStore()
        let unknown = UUID()
        #expect(throws: TaskStoreError.taskNotFound(id: unknown)) {
            try store.updateNotes(id: unknown, to: "orphan", now: t0)
        }
    }

    @Test func notesEditsDoNotAffectStatusPinOrCompletionState() throws {
        var task = TaskItem.make(title: "doing pinned", now: t0)
        task.status = .doing
        task.isPinned = true
        var store = TaskStore(tasks: [task])

        try store.updateNotes(id: task.id, to: "note text", now: t1)

        let updated = try #require(store.tasks.first)
        #expect(updated.status == .doing)
        #expect(updated.isPinned)
        #expect(updated.completedAt == nil)
        #expect(updated.archivedAt == nil)
    }
}
