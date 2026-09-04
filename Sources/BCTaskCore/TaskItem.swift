import Foundation

/// The three workflow states a task moves through.
public enum TaskStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case todo
    case doing
    case done
}

/// A single todo task persisted by the app.
///
/// Timestamp semantics:
/// - `createdAt` never changes after creation.
/// - `updatedAt` is bumped by every successful mutation, including archival sweeps.
/// - `completedAt` is set when a task enters `.done` and is cleared whenever the
///   task reopens (leaves `.done`). It is the sole driver of the archival deadline,
///   so catch-up after relaunch/sleep is deterministic.
/// - `archivedAt` records the actual time of archival and is cleared when the task
///   is reopened. Archived tasks are immutable and never pinned.
public struct TaskItem: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var status: TaskStatus
    public let createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var archivedAt: Date?
    public var isPinned: Bool

    /// Full initializer. Public so persistence and deterministic tests can
    /// construct exact states; all user-facing mutations go through `TaskStore`.
    public init(
        id: UUID = UUID(),
        title: String,
        status: TaskStatus = .todo,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        archivedAt: Date? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.isPinned = isPinned
    }

    /// Creates a fresh (unarchived, unpinned) task with the given title.
    public static func make(title: String, now: Date) -> Self {
        Self(
            title: title,
            status: .todo,
            createdAt: now,
            updatedAt: now
        )
    }

    /// A task is archived once `archivedAt` has been recorded.
    public var isArchived: Bool { archivedAt != nil }
}
