import Testing
import Foundation
@testable import BCTaskCore

@Suite("Task deletion seam")
struct TaskDeletionTests {
    private let t0 = Date(timeIntervalSince1970: 4_000_000)
    private let t1 = Date(timeIntervalSince1970: 4_000_000 + 600)

    @Test func deleteTaskRemovesLiveTaskAndLeavesOthersUntouched() throws {
        let first = TaskItem.make(title: "first", now: t0)
        let second = TaskItem.make(title: "second", now: t0)
        var store = TaskStore(tasks: [first, second])

        let removed = try store.deleteTask(id: first.id)

        #expect(removed.id == first.id)
        #expect(store.tasks == [second])
        #expect(store.activeTasks.map(\.id) == [second.id])
        #expect(store.archivedTasks.isEmpty)
    }

    @Test func deleteTaskRemovesArchivedTask() throws {
        var task = TaskItem.make(title: "archived", now: t0)
        task.status = .done
        task.completedAt = t0
        task.archivedAt = t1
        let survivor = TaskItem.make(title: "survivor", now: t0)
        var store = TaskStore(tasks: [task, survivor])

        let removed = try store.deleteTask(id: task.id)

        #expect(removed.id == task.id)
        #expect(store.tasks == [survivor])
        #expect(store.archivedTasks.isEmpty)
        #expect(store.activeTasks.map(\.id) == [survivor.id])
    }

    @Test func deleteTaskUnknownIDThrowsNotFound() {
        var store = TaskStore()
        let unknown = UUID()
        #expect(throws: TaskStoreError.taskNotFound(id: unknown)) {
            try store.deleteTask(id: unknown)
        }
    }

    @Test func deleteTaskRemovesPinnedTask() throws {
        let task = TaskItem(title: "pinned", createdAt: t0, updatedAt: t0, isPinned: true)
        var store = TaskStore(tasks: [task])

        let removed = try store.deleteTask(id: task.id)

        #expect(removed.id == task.id)
        #expect(store.tasks.isEmpty)
    }

    @Test func deletedTaskIsGoneFromDiskAfterRoundTrip() throws {
        let first = TaskItem.make(title: "first", now: t0)
        let second = TaskItem.make(title: "second", now: t0)
        var store = TaskStore(tasks: [first, second])
        try store.deleteTask(id: first.id)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = TaskFileStore(directory: root)

        try fileStore.save(store)
        let reloaded = try fileStore.load(now: t1)

        #expect(reloaded.tasks.map(\.id) == [second.id])
        #expect(reloaded.tasks.first(where: { $0.id == first.id }) == nil)
    }

    @Test func sweepSkipsDeletedOverdueDoneTask() throws {
        var done = TaskItem.make(title: "overdue", now: t0)
        done.status = .done
        done.completedAt = t0
        var store = TaskStore(tasks: [done])
        try store.deleteTask(id: done.id)

        let afterDeadline = t0.addingTimeInterval(TaskStore.archiveInterval + 1)
        #expect(store.sweep(now: afterDeadline) == [], "a deleted task can never be archived by the sweep")
        #expect(store.tasks.isEmpty)
        #expect(store.archivedTasks.isEmpty)
    }
}
