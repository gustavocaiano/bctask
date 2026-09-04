import Testing
import Foundation
import BCTaskCore
@testable import BCTask

@Suite("Kanban status-only drag decisions")
struct KanbanInteractionTests {
    private let taskID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test func namespacedPayloadRoundTripsTaskIdentity() throws {
        let encoded = KanbanTaskDragPayload(taskID: taskID).encoded
        let decoded = try #require(KanbanTaskDragPayload(encoded: encoded))
        #expect(decoded.taskID == taskID)
    }

    @Test func malformedAndExternalPayloadsAreRejected() {
        #expect(KanbanTaskDragPayload(encoded: "not-a-task") == nil)
        #expect(KanbanTaskDragPayload(encoded: taskID.uuidString) == nil)
        #expect(KanbanTaskDragPayload(encoded: "bctask-task:not-a-uuid") == nil)
    }

    @Test func sameColumnDropIsANoOp() {
        let encoded = KanbanTaskDragPayload(taskID: taskID).encoded
        let move = KanbanDropResolver.resolve(
            encodedPayload: encoded,
            currentStatuses: [taskID: .doing],
            targetStatus: .doing
        )
        #expect(move == nil)
    }

    @Test func crossColumnDropResolvesOneStatusMove() throws {
        let encoded = KanbanTaskDragPayload(taskID: taskID).encoded
        let move = try #require(KanbanDropResolver.resolve(
            encodedPayload: encoded,
            currentStatuses: [taskID: .todo],
            targetStatus: .done
        ))
        #expect(move == KanbanStatusMove(taskID: taskID, targetStatus: .done))
    }

    @Test func unknownTaskPayloadIsRejected() {
        let encoded = KanbanTaskDragPayload(taskID: taskID).encoded
        let move = KanbanDropResolver.resolve(
            encodedPayload: encoded,
            currentStatuses: [:],
            targetStatus: .doing
        )
        #expect(move == nil)
    }
}
