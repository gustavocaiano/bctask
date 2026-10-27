import Foundation

/// Error cases surfaced by `TaskStore` mutations. All cases are invalid user
/// requests; none indicate transport/storage problems.
public enum TaskStoreError: Error, Equatable, Sendable {
    case emptyTitle
    case taskNotFound(id: UUID)
    case archivedTasksAreImmutable
    case notesModifiedElsewhere(id: UUID)
    case restoreRequiresArchivedTask(id: UUID)
    case invalidTransition(from: TaskStatus, to: TaskStatus)
}

/// Value-semantics store holding all tasks plus the one-hour archival policy.
///
/// Explicit transition invariants:
/// - Allowed moves are exactly the pairs in `allowedTransitions` (the full
///   Todo/Doing/Done triangle in both directions). A move to the task's current
///   status is a documented no-op that touches no timestamps.
/// - Entering `.done` records `completedAt = now` and clears `archivedAt`.
/// - Leaving `.done` (reopen) clears `completedAt` and `archivedAt`, so a
///   reopened task can never carry a stale archival deadline.
/// - Every real status move re-syncs `isPinned` to the new status: entering
///   `.doing` pins, entering `.todo`/`.done` unpins. Same-status moves are
///   no-ops that never touch the pin, so a manually set pin survives until
///   the next real status change; the archival sweep and archive restore
///   still unpin.
/// - Archived tasks are immutable: any status/pin mutation throws
///   `.archivedTasksAreImmutable`. Restoring an archived task is a separate,
///   explicit operation: `restoreArchivedTask(id:now:)`.
/// - Notes are free-form: `updateNotes(id:from:to:now:)` stores the text
///   verbatim (no trimming, so pasted links keep their exact form), allows
///   empty notes (clearing), rejects archived tasks, and bumps `updatedAt`
///   — except that writing the identical current value is a documented
///   no-op that touches no timestamps, because the UI commits on editor
///   close and unchanged text must not reorder the most-recently-updated
///   list. The `from` baseline is the optimistic-concurrency guard for the
///   one real concurrent-editor case (a pinned panel plus the main surface
///   editing the same task): a commit whose baseline no longer matches the
///   store throws `.notesModifiedElsewhere` instead of silently
///   overwriting the other editor's text.
/// - Deletion removes any task (live or archived) permanently: there is no
///   archive step, no undo, and no timestamp is recorded.
///
/// Archival policy: a `.done` task becomes archived at exactly one hour after
/// its persisted `completedAt` (inclusive boundary). `sweep(now:)` is called
/// before user commands, on launch, and on reload, so persisted deadlines
/// always catch up regardless of sleep or relaunch. The sweep returns the
/// IDs it archived (empty when nothing changed) so callers can avoid no-op
/// writes and, in Phase 3, close panels for archived pinned tasks.
public struct TaskStore: Equatable, Sendable {
    public static let archiveInterval: TimeInterval = 60 * 60

    /// Adjacency table of permitted status moves. Every cross-status pair is
    /// currently allowed; this table makes the contract explicit so forbidden
    /// states (e.g. future "archived" status) cannot be entered by accident.
    public static let allowedTransitions: [TaskStatus: Set<TaskStatus>] = [
        .todo: [.doing, .done],
        .doing: [.todo, .done],
        .done: [.todo, .doing],
    ]

    /// Read-only task collection; all mutations go through the methods below.
    public private(set) var tasks: [TaskItem]

    public init(tasks: [TaskItem] = []) {
        self.tasks = tasks
    }

    /// Adds a new task in `.todo` state. The title may not be empty after trimming.
    @discardableResult
    public mutating func addTask(title: String, now: Date) throws -> TaskItem {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskStoreError.emptyTitle }
        let task = TaskItem.make(title: trimmed, now: now)
        tasks.append(task)
        return task
    }

    /// Moves a task to `newStatus`, enforcing the transition invariants above.
    /// Every real status move re-syncs the pin to the new status (Doing pins;
    /// Todo/Done unpin). Same-status moves are guarded no-ops that never touch
    /// a manually set pin; `setPinned` remains a temporary override that
    /// survives until the next status change.
    public mutating func setStatus(id: UUID, to newStatus: TaskStatus, now: Date) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskStoreError.taskNotFound(id: id)
        }
        try setStatus(at: index, to: newStatus, now: now)
    }

    /// Pins or unpins a live (non-archived) task. Archived tasks reject pinning.
    public mutating func setPinned(_ pinned: Bool, for id: UUID, now: Date) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskStoreError.taskNotFound(id: id)
        }
        guard !tasks[index].isArchived else {
            throw TaskStoreError.archivedTasksAreImmutable
        }
        guard tasks[index].isPinned != pinned else { return }
        tasks[index].isPinned = pinned
        tasks[index].updatedAt = now
    }

    /// Replaces the free-form notes (description, links) of a live task,
    /// bumping `updatedAt`. Archived tasks are immutable and reject notes
    /// edits. Notes are stored verbatim (no trimming) so pasted links keep
    /// their exact form; empty notes are allowed (clearing). Writing the
    /// identical current value is a documented no-op that touches no
    /// timestamps — the UI commits on editor close, and unchanged text must
    /// not reorder the most-recently-updated list.
    ///
    /// `baseline` is the notes value the caller read when it seeded its
    /// draft: if the store has moved to some OTHER value in the meantime,
    /// a concurrent editor committed first, and this commit throws
    /// `.notesModifiedElsewhere` rather than silently overwriting it. Text
    /// that already equals the stored notes never conflicts (re-committing
    /// the same content is always safe); a caller re-reads the store to
    /// make overwriting deliberate.
    public mutating func updateNotes(
        id: UUID,
        from baseline: String,
        to newNotes: String,
        now: Date
    ) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskStoreError.taskNotFound(id: id)
        }
        guard !tasks[index].isArchived else {
            throw TaskStoreError.archivedTasksAreImmutable
        }
        let stored = tasks[index].notes
        guard stored == baseline || stored == newNotes else {
            throw TaskStoreError.notesModifiedElsewhere(id: id)
        }
        guard stored != newNotes else { return }
        tasks[index].notes = newNotes
        tasks[index].updatedAt = now
    }

    /// Explicit recovery path for archived tasks (archive restore).
    ///
    /// Archived tasks reject normal transitions; this is the only mutating
    /// path for them. It preserves identity (id, title, createdAt), moves the
    /// task back to `.todo`, clears `completedAt`/`archivedAt`, leaves the
    /// task unpinned, and bumps `updatedAt`.
    @discardableResult
    public mutating func restoreArchivedTask(id: UUID, now: Date) throws -> TaskItem {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskStoreError.taskNotFound(id: id)
        }
        guard tasks[index].isArchived else {
            throw TaskStoreError.restoreRequiresArchivedTask(id: id)
        }
        tasks[index].status = .todo
        tasks[index].completedAt = nil
        tasks[index].archivedAt = nil
        tasks[index].isPinned = false
        tasks[index].updatedAt = now
        return tasks[index]
    }

    /// Permanently removes a task (live or archived) from the store.
    /// Unlike completion, deletion is immediate and final: there is no
    /// archive step, no undo, and no timestamp is recorded.
    @discardableResult
    public mutating func deleteTask(id: UUID) throws -> TaskItem {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskStoreError.taskNotFound(id: id)
        }
        return tasks.remove(at: index)
    }

    /// Archives every `.done` task whose persisted `completedAt` is at least
    /// `archiveInterval` in the past (inclusive boundary), records the actual
    /// archival time, and unpins the archived task. Also unpins any already
    /// archived task that is still flagged pinned, restoring the archived
    /// tasks-are-never-pinned invariant after possible data drift.
    /// Returns the IDs archived by this call, in task order (empty = nothing
    /// changed, so callers can skip persistence entirely).
    @discardableResult
    public mutating func sweep(now: Date) -> [UUID] {
        var archivedIDs: [UUID] = []
        for index in tasks.indices {
            if tasks[index].isArchived {
                tasks[index].isPinned = false
                continue
            }
            guard tasks[index].status == .done,
                  let completedAt = tasks[index].completedAt,
                  now >= completedAt.addingTimeInterval(Self.archiveInterval)
            else { continue }
            tasks[index].archivedAt = now
            tasks[index].updatedAt = now
            tasks[index].isPinned = false
            archivedIDs.append(tasks[index].id)
        }
        return archivedIDs
    }

    /// The archival deadline for a live task: its `completedAt` plus one hour.
    /// Archived tasks carry no pending deadline, so this returns nil for them.
    public static func archivalDeadline(of task: TaskItem) -> Date? {
        guard task.status == .done,
              !task.isArchived,
              let completedAt = task.completedAt
        else { return nil }
        return completedAt.addingTimeInterval(archiveInterval)
    }

    /// Live tasks (never archived), most recently updated first.
    public var activeTasks: [TaskItem] {
        tasks.filter { !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Archived tasks, most recently archived first.
    public var archivedTasks: [TaskItem] {
        tasks.filter(\.isArchived).sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    // MARK: - Transition internals

    private mutating func setStatus(at index: Int, to newStatus: TaskStatus, now: Date) throws {
        let current = tasks[index]
        guard !current.isArchived else {
            throw TaskStoreError.archivedTasksAreImmutable
        }
        guard current.status != newStatus else {
            return // documented no-op: same-status move touches nothing
        }
        guard Self.allowedTransitions[current.status]?.contains(newStatus) == true else {
            throw TaskStoreError.invalidTransition(from: current.status, to: newStatus)
        }

        tasks[index].status = newStatus
        tasks[index].updatedAt = now
        if newStatus == .done {
            tasks[index].completedAt = now
            tasks[index].archivedAt = nil
        } else if current.status == .done {
            // Reopen: clear completion/archive so the archival deadline resets.
            tasks[index].completedAt = nil
            tasks[index].archivedAt = nil
        }
        // The pin mirrors "currently in Doing": every real status move re-syncs
        // it. Same-status moves are guarded no-ops above and never touch it.
        tasks[index].isPinned = (newStatus == .doing)
    }
}
