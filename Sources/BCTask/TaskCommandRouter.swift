import Combine

/// Typed task-surface commands shared by SwiftUI keyboard shortcuts and the
/// native event bridge that Phase 3 will attach to the movable main panel.
enum TaskSurfaceCommand: Hashable, Sendable {
    case focusNewTask
    case focusPreviousTask
    case focusNextTask
    case moveFocusedTaskBackward
    case moveFocusedTaskForward
    case pinFocusedTask
    case deleteFocusedTask
    case leaveNewTaskEntry
    case toggleProjection
}

/// A deliberately small main-actor command seam. The router owns no task or
/// model data. It does retain the semantic new-task focus bit shared by
/// SwiftUI and the synchronous AppKit event monitor so Escape routing never
/// depends on private responder implementation details.
@MainActor
final class TaskCommandRouter: ObservableObject {
    let commands = PassthroughSubject<TaskSurfaceCommand, Never>()
    private(set) var taskEntryIsFocused = false

    /// Synchronously mirrors `ContentView`'s task-entry focus intent/state for
    /// the AppKit local monitor. This intentionally does not publish a view
    /// update; `@FocusState` remains the SwiftUI rendering source of truth.
    func updateTaskEntryFocus(_ isFocused: Bool) {
        taskEntryIsFocused = isFocused
    }

    func send(_ command: TaskSurfaceCommand) {
        commands.send(command)
    }
}
