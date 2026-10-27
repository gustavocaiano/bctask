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
///
/// Notes semantics:
/// - `notes` is free-form detail text (a description, links, anything the user
///   wants to keep with the task). It is stored verbatim and only ever edited
///   through `TaskStore.updateNotes`; empty string means "no notes".
/// - On-disk compatibility: writes use document schema 2 (see
///   `TaskDocument`). Reading spans schemas 1 and 2: legacy documents have
///   no `"notes"` key and decode with `notes == ""` (custom `init(from:)`
///   uses `decodeIfPresent`), including schema-1 files that interim builds
///   already wrote with notes. Older BCTask builds reject schema 2 outright
///   instead of decoding the file and later re-encoding it without the
///   notes key — that downgrade path is exactly what the version bump
///   exists to prevent.
public struct TaskItem: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var notes: String
    public var status: TaskStatus
    public let createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var archivedAt: Date?
    public var isPinned: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case notes
        case status
        case createdAt
        case updatedAt
        case completedAt
        case archivedAt
        case isPinned
    }

    /// Full initializer. Public so persistence and deterministic tests can
    /// construct exact states; all user-facing mutations go through `TaskStore`.
    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        status: TaskStatus = .todo,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        archivedAt: Date? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.isPinned = isPinned
    }

    /// Decodes with backward compatibility: documents persisted before `notes`
    /// existed carry no `"notes"` key and must decode as empty notes rather
    /// than fail. Encoding stays compiler-synthesized and always writes the
    /// field, at document schema 2 (see `TaskDocument`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        status = try container.decode(TaskStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
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
