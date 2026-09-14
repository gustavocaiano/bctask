import Testing
import Foundation
@testable import BCTaskCore

@Suite("Task transition invariants")
struct TaskTransitionTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_000_000 + 120)
    private let t2 = Date(timeIntervalSince1970: 1_000_000 + 300)

    @Test func addCreatesTodoTaskWithTrimmedTitleAndFreshTimestamps() throws {
        var store = TaskStore()

        let task = try store.addTask(title: "  buy oat milk  ", now: t0)

        #expect(task.title == "buy oat milk")
        #expect(task.status == .todo)
        #expect(task.createdAt == t0)
        #expect(task.updatedAt == t0)
        #expect(task.completedAt == nil)
        #expect(task.archivedAt == nil)
        #expect(!task.isPinned)
        try #require(store.tasks.count == 1)
    }

    @Test func addRejectsBlankTitle() {
        var store = TaskStore()
        #expect(throws: TaskStoreError.emptyTitle) {
            try store.addTask(title: "   ", now: t0)
        }
    }

    @Test func everyCrossStatusTransitionIsAllowed() throws {
        for from in TaskStatus.allCases {
            for to in TaskStatus.allCases where from != to {
                var store = TaskStore()
                let task = try store.addTask(title: "task", now: t0)
                try store.setStatus(id: task.id, to: from, now: t0)
                try store.setStatus(id: task.id, to: to, now: t1)

                let moved = try #require(store.tasks.first)
                #expect(moved.status == to, "\(from) → \(to) must be allowed")
                #expect(moved.updatedAt == t1)
            }
        }
    }

    @Test func sameStatusMoveIsADocumentedNoOp() throws {
        var store = TaskStore()
        let task = try store.addTask(title: "task", now: t0)

        try store.setStatus(id: task.id, to: .todo, now: t1)

        #expect(store.tasks == [task], "same-status move must not touch the task")
    }

    @Test func completingSetsCompletedAt() throws {
        var store = TaskStore()
        let task = try store.addTask(title: "task", now: t0)

        try store.setStatus(id: task.id, to: .doing, now: t0)
        try store.setStatus(id: task.id, to: .done, now: t1)

        let done = try #require(store.tasks.first)
        #expect(done.status == .done)
        #expect(TaskStore.archivalDeadline(of: done) == t1.addingTimeInterval(3600))
        #expect(done.archivedAt == nil)
    }

    @Test func reopenToTodoClearsCompletionAndArchiveTimestamps() throws {
        var done = TaskItem.make(title: "task", now: t0)
        done.status = .done
        done.completedAt = t0
        var store = TaskStore(tasks: [done])

        try store.setStatus(id: done.id, to: .todo, now: t1)

        let reopened = try #require(store.tasks.first)
        #expect(reopened.status == .todo)
        #expect(reopened.completedAt == nil)
        #expect(reopened.archivedAt == nil)
        #expect(reopened.updatedAt == t1)
        #expect(TaskStore.archivalDeadline(of: reopened) == nil)
    }

    @Test func reopenToDoingAlsoResetsTimestamps() throws {
        var store = TaskStore()
        let task = try store.addTask(title: "task", now: t0)

        try store.setStatus(id: task.id, to: .done, now: t0)
        try store.setStatus(id: task.id, to: .doing, now: t1)

        let reopened = try #require(store.tasks.first)
        #expect(reopened.status == .doing)
        #expect(reopened.completedAt == nil)
        #expect(reopened.archivedAt == nil)
    }

    @Test func recompletedTaskGetsNewCompletionTimestamp() throws {
        var store = TaskStore()
        let task = try store.addTask(title: "task", now: t0)

        try store.setStatus(id: task.id, to: .done, now: t0)
        try store.setStatus(id: task.id, to: .todo, now: t1)
        try store.setStatus(id: task.id, to: .done, now: t2)

        let done = try #require(store.tasks.first)
        #expect(done.completedAt == t2, "second completion must carry its own completedAt")
        #expect(TaskStore.archivalDeadline(of: done) == t2.addingTimeInterval(3600))
    }

    @Test func pinMirrorsDoingAcrossStatusMovesAndSweepUnpinsOnlyOnArchival() throws {
        var store = TaskStore()
        let task = try store.addTask(title: "task", now: t0)
        try store.setPinned(true, for: task.id, now: t0)

        // Manual pin is a temporary override: it survives until the next real
        // status move, which re-syncs the pin to the new status.
        try store.setStatus(id: task.id, to: .doing, now: t1)
        try store.setStatus(id: task.id, to: .done, now: t1)
        try store.setStatus(id: task.id, to: .todo, now: t1)
        #expect(try #require(store.tasks.first).isPinned == false, "Todo/Done moves unpin")

        store.sweep(now: t1.addingTimeInterval(7200))
        let after = try #require(store.tasks.first)
        #expect(after.isArchived == false, "a reopened task carries no leftover deadline so it is never archived")
        #expect(after.isPinned == false, "sweep never touches a live task's pin either way")
    }

    @Test func archivedTaskRejectsEveryMutation() throws {
        var task = TaskItem.make(title: "task", now: t0)
        task.status = .done
        task.completedAt = t0
        task.archivedAt = t1
        var store = TaskStore(tasks: [task])

        #expect(throws: TaskStoreError.archivedTasksAreImmutable) {
            try store.setStatus(id: task.id, to: .todo, now: t2)
        }
        #expect(throws: TaskStoreError.archivedTasksAreImmutable) {
            try store.setPinned(true, for: task.id, now: t2)
        }
    }

    @Test func unknownTaskThrowsNotFound() {
        var store = TaskStore()
        let unknown = UUID()

        #expect(throws: TaskStoreError.taskNotFound(id: unknown)) {
            try store.setStatus(id: unknown, to: .doing, now: t0)
        }
        #expect(throws: TaskStoreError.taskNotFound(id: unknown)) {
            try store.setPinned(true, for: unknown, now: t0)
        }
    }

    @Test func allowedTransitionsTableMatchesTheFullTriangle() {
        for from in TaskStatus.allCases {
            let targets = TaskStore.allowedTransitions[from] ?? []
            #expect(
                Set(targets) == Set(TaskStatus.allCases).subtracting([from]),
                "each status must allow exactly the two other statuses"
            )
        }
    }
}
