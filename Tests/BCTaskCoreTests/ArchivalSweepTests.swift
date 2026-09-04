import Testing
import Foundation
@testable import BCTaskCore

@Suite("One-hour archival sweep")
struct ArchivalSweepTests {
    /// Completion instant from which deadlines are measured.
    private let completion = Date(timeIntervalSince1970: 2_000_000)
    private let deadlineDate = Date(timeIntervalSince1970: 2_000_000 + 3600)

    /// A done task completed at `completion` and an unrelated doing task.
    private func fixtures(pinnedDone: Bool = false) -> (tasks: [TaskItem], doneID: UUID, doingID: UUID) {
        var done = TaskItem.make(title: "done task", now: self.completion - 60)
        done.status = .done
        done.completedAt = completion
        done.isPinned = pinnedDone
        var busy = TaskItem.make(title: "doing task", now: completion - 7200)
        busy.status = .doing
        return ([done, busy], done.id, busy.id)
    }

    private func task(_ id: UUID, in store: TaskStore) throws -> TaskItem {
        try #require(store.tasks.first { $0.id == id })
    }

    @Test func sweepBeforeDeadlineLeavesTaskActive() throws {
        let (tasks, doneID, _) = fixtures()
        var store = TaskStore(tasks: tasks)
        // One second before the deadline.
        #expect(store.sweep(now: deadlineDate.addingTimeInterval(-1)) == [])
        #expect(try task(doneID, in: store).archivedAt == nil)
    }

    @Test func sweepExactlyAtDeadlineArchivesInclusiveBoundary() throws {
        let (tasks, doneID, _) = fixtures()
        var store = TaskStore(tasks: tasks)
        #expect(store.sweep(now: deadlineDate) == [doneID])
        #expect(try task(doneID, in: store).archivedAt == deadlineDate)
    }

    @Test func sweepAfterAnyLongerDelayArchivesTheSameWay() throws {
        let (tasks, doneID, _) = fixtures()
        var store = TaskStore(tasks: tasks)
        let later = deadlineDate.addingTimeInterval(12345)
        #expect(store.sweep(now: later) == [doneID])
        #expect(try task(doneID, in: store).archivedAt == later)
    }

    @Test func archivedAtRecordsActualSweepTimeAndNeverRearchives() throws {
        let (tasks, doneID, _) = fixtures()
        var store = TaskStore(tasks: tasks)
        #expect(store.sweep(now: deadlineDate) == [doneID])
        let first = try task(doneID, in: store).archivedAt

        #expect(store.sweep(now: deadlineDate.addingTimeInterval(999)) == [])
        #expect(try task(doneID, in: store).archivedAt == first, "already archived tasks must not be re-archived")
    }

    @Test func sweepUnpinsPinnedTasks() throws {
        let (tasks, doneID, _) = fixtures(pinnedDone: true)
        var store = TaskStore(tasks: tasks)
        #expect(store.sweep(now: deadlineDate) == [doneID])
        let archived = try task(doneID, in: store)
        #expect(archived.archivedAt == deadlineDate)
        #expect(archived.isPinned == false, "archival must unpin")
    }

    @Test func archivingPinnedTaskActuallyArchivesIt() throws {
        // Contract: archiving a pinned task completes (panel closing comes in
        // Phase 3). Here we verify the archived state exists and is unpinned.
        let (tasks, doneID, _) = fixtures(pinnedDone: true)
        var store = TaskStore(tasks: tasks)
        _ = store.sweep(now: completion + 3600)
        #expect(try task(doneID, in: store).isArchived == true)
        #expect(try task(doneID, in: store).isPinned == false)
    }

    @Test func sweepLeavesFreshlyCompletedAndActiveTasksAlone() throws {
        let (tasks, _, doingID) = fixtures()
        var fresh = TaskItem.make(title: "fresh", now: deadlineDate)
        fresh.status = .done
        fresh.completedAt = deadlineDate
        var store = TaskStore(tasks: tasks + [fresh])

        store.sweep(now: deadlineDate)
        #expect(try task(doingID, in: store).archivedAt == nil, "a doing task never archives")
        #expect(try task(fresh.id, in: store).archivedAt == nil, "fresh completions respect their own one-hour deadline")

        let doing = try task(doingID, in: store)
        #expect(doing.updatedAt == doing.createdAt, "sweep must not bump untouched tasks")
    }

    @Test func sweepRestoresArchivedTasksAreNeverPinned() throws {
        var archived = TaskItem.make(title: "drift", now: Date(timeIntervalSince1970: 0))
        archived.status = .done
        archived.completedAt = Date(timeIntervalSince1970: 0)
        archived.archivedAt = Date(timeIntervalSince1970: 3500)
        archived.isPinned = true // simulated drift from an older format
        var store = TaskStore(tasks: [archived])

        store.sweep(now: Date(timeIntervalSince1970: 4000))
        #expect(try task(archived.id, in: store).isPinned == false)
    }

    @Test func archivalDeadlineDerivedFromPersistedCompletedAtOnly() {
        var task = TaskItem.make(title: "task", now: Date(timeIntervalSince1970: 0))
        task.status = .done
        task.completedAt = Date(timeIntervalSince1970: 42)
        #expect(TaskStore.archivalDeadline(of: task) == Date(timeIntervalSince1970: 42 + 3600))

        task.completedAt = nil
        task.archivedAt = Date(timeIntervalSince1970: 42)
        #expect(TaskStore.archivalDeadline(of: task) == nil, "archived tasks no longer count on a deadline")
    }

    @Test func archivedTasksCarryNoPendingDeadline() throws {
        let (tasks, doneID, _) = fixtures()
        var store = TaskStore(tasks: tasks)
        _ = store.sweep(now: deadlineDate)
        let archived = try task(doneID, in: store)
        #expect(TaskStore.archivalDeadline(of: archived) == nil, "archived tasks must expose no archival deadline")
    }

    @Test func activeAndArchivedProjectionsAreSortedAsDocumented() throws {
        let (tasks, _, doingID) = fixtures()
        var oldArchive = TaskItem.make(title: "older", now: completion - 10)
        oldArchive.status = .done
        oldArchive.completedAt = completion - 5000
        oldArchive.archivedAt = completion - 4000
        var store = TaskStore(tasks: tasks + [oldArchive])

        _ = store.sweep(now: deadlineDate)

        #expect(store.archivedTasks.map(\.title) == ["done task", "older"], "newest archive first")
        #expect(store.activeTasks.count == 1)
        #expect(store.activeTasks.first?.title == "doing task")
        _ = doingID
    }
}
