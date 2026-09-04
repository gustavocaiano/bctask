import Testing
import Foundation
@testable import BCTaskCore

@Suite("Archive restoration seam")
struct TaskRestoreTests {
    private let t0 = Date(timeIntervalSince1970: 4_000_000)
    private let t1 = Date(timeIntervalSince1970: 4_000_000 + 600)
    private let restore = Date(timeIntervalSince1970: 4_000_000 + 7200)

    private func archivedTask() -> (task: TaskItem, deadline: Date) {
        var task = TaskItem.make(title: "archived subject", now: t0)
        task.status = .done
        task.completedAt = t0
        task.archivedAt = t1
        return (task, t0.addingTimeInterval(3600))
    }

    @Test func restoreReturnsArchivedTaskToTodoPreservingIdentity() throws {
        let (task, _) = archivedTask()
        var store = TaskStore(tasks: [task])

        let restored = try store.restoreArchivedTask(id: task.id, now: restore)

        #expect(restored.id == task.id, "restoration preserves identity")
        #expect(restored.title == task.title)
        #expect(restored.createdAt == task.createdAt)
        #expect(restored.status == .todo)
        #expect(restored.completedAt == nil)
        #expect(restored.archivedAt == nil)
        #expect(restored.isPinned == false, "restored tasks are unpinned")
        #expect(restored.updatedAt == restore)
        #expect(store.tasks == [restored])
    }

    @Test func restoreRejectsEveryActiveTask() throws {
        let todo = TaskItem.make(title: "todo", now: t0)
        var doing = TaskItem.make(title: "doing", now: t0)
        doing.status = .doing
        var done = TaskItem.make(title: "done", now: t0)
        done.status = .done
        done.completedAt = t0
        var store = TaskStore(tasks: [todo, doing, done])

        for active in [todo, doing, done] {
            #expect(throws: TaskStoreError.restoreRequiresArchivedTask(id: active.id)) {
                try store.restoreArchivedTask(id: active.id, now: restore)
            }
        }
        #expect(store.tasks == [todo, doing, done], "failed restores change nothing")
    }

    @Test func restoredTaskIsNotRearchivedByAnEarlierDeadline() throws {
        let (task, deadline) = archivedTask()
        var store = TaskStore(tasks: [task])
        try store.restoreArchivedTask(id: task.id, now: restore)

        // The old deadline (t0 + 1h) is now long past, but the task is Todo,
        // so the sweep must not archive it.
        #expect(store.sweep(now: deadline.addingTimeInterval(7200)) == [])
        let after = try #require(store.tasks.first)
        #expect(after.status == .todo)
        #expect(after.isArchived == false)
    }

    @Test func restoreSurvivesSaveAndReload() throws {
        let (task, _) = archivedTask()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = TaskFileStore(directory: root)

        var store = TaskStore(tasks: [task])
        _ = store.sweep(now: t1) // archive for real
        try fileStore.save(store)

        var reloaded = try fileStore.load(now: t1)
        _ = try reloaded.restoreArchivedTask(id: task.id, now: restore)
        try fileStore.save(reloaded)

        var second = try fileStore.load(now: restore + 3600)
        let activeAfterRestore = try #require(second.tasks.first)
        #expect(activeAfterRestore.status == .todo)
        #expect(activeAfterRestore.isArchived == false)
        #expect(second.sweep(now: restore + 7200) == [], "restored, persisted task stays active across reloads")
    }

    @Test func restoreUnknownTaskThrowsNotFound() {
        var store = TaskStore()
        let unknown = UUID()
        #expect(throws: TaskStoreError.taskNotFound(id: unknown)) {
            try store.restoreArchivedTask(id: unknown, now: t0)
        }
    }
}
