import Testing
import Foundation
@testable import BCTaskCore

@Suite("Pin mirrors Doing")
struct PinResyncTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private let t1 = Date(timeIntervalSince1970: 2_000_000 + 60)

    @Test func movingToDoingPinsFromTodoAndDone() throws {
        var store = TaskStore()
        let todo = try store.addTask(title: "todo", now: t0)
        try store.setStatus(id: todo.id, to: .doing, now: t1)
        #expect(try #require(store.tasks.first).isPinned == true, "todo → doing pins")

        let done = TaskItem(title: "done", status: .done, createdAt: t0, updatedAt: t0, completedAt: t0)
        var doneStore = TaskStore(tasks: [done])
        try doneStore.setStatus(id: done.id, to: .doing, now: t1)
        #expect(try #require(doneStore.tasks.first).isPinned == true, "done → doing pins (and clears the completion)")
    }

    @Test func movingOutOfDoingUnpins() throws {
        var store = TaskStore()
        let task = try store.addTask(title: "task", now: t0)
        try store.setStatus(id: task.id, to: .doing, now: t0)
        #expect(try #require(store.tasks.first).isPinned == true)

        try store.setStatus(id: task.id, to: .done, now: t1)
        #expect(try #require(store.tasks.first).isPinned == false, "doing → done unpins")

        let second = TaskItem(title: "second", status: .doing, createdAt: t0, updatedAt: t0, isPinned: true)
        var doingStore = TaskStore(tasks: [second])
        try doingStore.setStatus(id: second.id, to: .todo, now: t1)
        #expect(try #require(doingStore.tasks.first).isPinned == false, "doing → todo unpins")
    }

    @Test func manuallyPinnedTodoStaysPinnedWhenMovedToDoing() throws {
        var store = TaskStore()
        let task = try store.addTask(title: "task", now: t0)
        try store.setPinned(true, for: task.id, now: t0)

        try store.setStatus(id: task.id, to: .doing, now: t1)

        #expect(try #require(store.tasks.first).isPinned == true, "already pinned, stays pinned")
    }

    @Test func sameStatusMoveNeverTouchesAManualPin() throws {
        var store = TaskStore()
        let task = try store.addTask(title: "task", now: t0)
        try store.setPinned(true, for: task.id, now: t0)

        try store.setStatus(id: task.id, to: .todo, now: t1)

        let after = try #require(store.tasks.first)
        #expect(after.isPinned == true, "no-op move is a documented non-mutation: the pin is untouched")
        #expect(after.updatedAt == t0, "no-op move touches no timestamps")
    }

    @Test func manualUnpinOnDoingLastsUntilTheNextStatusMove() throws {
        var store = TaskStore()
        let task = try store.addTask(title: "task", now: t0)
        try store.setStatus(id: task.id, to: .doing, now: t0)
        #expect(try #require(store.tasks.first).isPinned == true)

        try store.setPinned(false, for: task.id, now: t1)
        #expect(try #require(store.tasks.first).isPinned == false, "manual override sticks")

        try store.setStatus(id: task.id, to: .todo, now: t1)
        try store.setStatus(id: task.id, to: .doing, now: t1)
        #expect(try #require(store.tasks.first).isPinned == true, "the next real status move re-syncs the pin")
    }

    @Test func sweepAndRestoreStillUnpin() throws {
        var pinnedDone = TaskItem.make(title: "done", now: t0)
        pinnedDone.status = .done
        pinnedDone.completedAt = t0
        pinnedDone.isPinned = true
        var sweepStore = TaskStore(tasks: [pinnedDone])
        _ = sweepStore.sweep(now: t0.addingTimeInterval(TaskStore.archiveInterval))
        let archived = try #require(sweepStore.tasks.first)
        #expect(archived.isArchived && !archived.isPinned, "the sweep still unpins on archival")

        let archivedPinned = TaskItem(
            title: "archived",
            status: .done,
            createdAt: t0,
            updatedAt: t0,
            completedAt: t0,
            archivedAt: t1,
            isPinned: true // simulated data drift; restore always unpins
        )
        var restoreStore = TaskStore(tasks: [archivedPinned])
        _ = try restoreStore.restoreArchivedTask(id: archivedPinned.id, now: t1)
        #expect(try #require(restoreStore.tasks.first).isPinned == false, "restoration still unpins")
    }
}
