import Foundation

/// The persisted document format. Wrapped in a schema version so future
/// format changes can migrate or reject old files explicitly.
public struct TaskDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var tasks: [TaskItem]

    public init(schemaVersion: Int = TaskDocument.currentSchemaVersion, tasks: [TaskItem]) {
        self.schemaVersion = schemaVersion
        self.tasks = tasks
    }
}

/// Document-level errors raised while encoding or decoding task documents.
public enum TaskFileError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case duplicateTaskID(id: UUID)
    case invalidTaskShape(id: UUID, reason: String)
}

/// JSON codec for `TaskDocument` <-> `TaskStore`.
///
/// Strict document invariants, enforced on BOTH encode and decode
/// (reject, never silently repair):
/// - No duplicate task IDs.
/// - Schema-1 shapes:
///   - Active Todo/Doing tasks carry no completion/archive timestamps.
///   - Active Done tasks carry `completedAt` and no `archivedAt`.
///   - Archived tasks must be Done, carry `completedAt` and `archivedAt`,
///     and be unpinned.
/// Timestamp ordering between fields is deliberately not enforced.
///
/// `JSONEncoder`/`JSONDecoder` instances are newly configured per call.
/// Dates use `secondsSince1970` (exact round trip through Date's internal
/// double-precision representation) and output is key-sorted so identical
/// stores byte-match on disk, which keeps persistence tests deterministic.
public enum TaskDocumentCodec {
    public static func encode(_ store: TaskStore) throws -> Data {
        try validate(store.tasks)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(TaskDocument(tasks: store.tasks))
    }

    public static func decode(_ data: Data) throws -> TaskStore {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let document = try decoder.decode(TaskDocument.self, from: data)
        guard document.schemaVersion == TaskDocument.currentSchemaVersion else {
            throw TaskFileError.unsupportedSchema(document.schemaVersion)
        }
        try validate(document.tasks)
        return TaskStore(tasks: document.tasks)
    }

    /// Shared strict-invariant check used by both directions of the codec.
    ///
    /// Classification: a task is archived iff `archivedAt != nil`. Therefore
    /// "active Done must not carry archivedAt" holds by definition (an
    /// archivedAt makes it an archived task), and a Todo/Doing task carrying
    /// `archivedAt` is rejected as an archived task that is not Done.
    public static func validate(_ tasks: [TaskItem]) throws {
        var seenIDs = Set<UUID>()
        for task in tasks {
            guard seenIDs.insert(task.id).inserted else {
                throw TaskFileError.duplicateTaskID(id: task.id)
            }
            if task.archivedAt != nil {
                guard task.status == .done else {
                    throw TaskFileError.invalidTaskShape(id: task.id, reason: "archived task must be Done")
                }
                guard task.completedAt != nil else {
                    throw TaskFileError.invalidTaskShape(id: task.id, reason: "archived task must carry completedAt")
                }
                guard !task.isPinned else {
                    throw TaskFileError.invalidTaskShape(id: task.id, reason: "archived task must be unpinned")
                }
            } else {
                switch task.status {
                case .done:
                    guard task.completedAt != nil else {
                        throw TaskFileError.invalidTaskShape(id: task.id, reason: "active Done task requires completedAt")
                    }
                case .todo, .doing:
                    guard task.completedAt == nil else {
                        throw TaskFileError.invalidTaskShape(id: task.id, reason: "active \(task.status.rawValue) task must not carry completedAt")
                    }
                }
            }
        }
    }
}
