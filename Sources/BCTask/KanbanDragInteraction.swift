import Foundation
import BCTaskCore

/// In-process task payload used by Kanban drags. The namespaced text envelope
/// keeps plain UUIDs and unrelated external payloads from being accepted.
struct KanbanTaskDragPayload: Equatable, Sendable {
    static let typeIdentifier = "com.bctask.task-id"
    private static let prefix = "bctask-task:"

    let taskID: UUID

    var encoded: String {
        Self.prefix + taskID.uuidString.lowercased()
    }

    init(taskID: UUID) {
        self.taskID = taskID
    }

    init?(encoded: String) {
        guard encoded.hasPrefix(Self.prefix) else { return nil }
        let rawID = String(encoded.dropFirst(Self.prefix.count))
        guard !rawID.isEmpty, let taskID = UUID(uuidString: rawID) else { return nil }
        self.taskID = taskID
    }

    func itemProvider() -> NSItemProvider {
        let encoded = encoded
        let provider = NSItemProvider()
        provider.suggestedName = encoded
        provider.registerDataRepresentation(
            forTypeIdentifier: Self.typeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(encoded.data(using: .utf8), nil)
            return nil
        }
        return provider
    }
}

/// A resolved status-only Kanban move. There is intentionally no insertion
/// index: updated-time ordering remains authoritative inside every column.
struct KanbanStatusMove: Equatable, Sendable {
    let taskID: UUID
    let targetStatus: TaskStatus
}

enum KanbanDropResolver {
    static func resolve(
        encodedPayload: String,
        currentStatuses: [UUID: TaskStatus],
        targetStatus: TaskStatus
    ) -> KanbanStatusMove? {
        guard let payload = KanbanTaskDragPayload(encoded: encodedPayload),
              let sourceStatus = currentStatuses[payload.taskID],
              sourceStatus != targetStatus
        else { return nil }

        return KanbanStatusMove(taskID: payload.taskID, targetStatus: targetStatus)
    }
}
