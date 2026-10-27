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
    /// Mirrors whether a task-notes text editor currently holds keyboard
    /// focus. `TaskViews` syncs it from its editor's focus state exactly like
    /// `ContentView` syncs `taskEntryIsFocused`; while it is true, the native
    /// key monitor leaves every key to the text system.
    ///
    /// Published (unlike `taskEntryIsFocused`) because the shortcut menu's
    /// enabled state is derived from it: the menu must grey out in the same
    /// update that the editor takes focus.
    @Published private(set) var notesEditingIsFocused = false

    /// Synchronously mirrors `ContentView`'s task-entry focus intent/state for
    /// the AppKit local monitor. This intentionally does not publish a view
    /// update; `@FocusState` remains the SwiftUI rendering source of truth.
    func updateTaskEntryFocus(_ isFocused: Bool) {
        taskEntryIsFocused = isFocused
    }

    /// Same synchronization contract as `updateTaskEntryFocus`, but for the
    /// multiline task-notes editor focus. Publishing here is intended: see
    /// `notesEditingIsFocused`.
    func updateNotesEditingFocus(_ isFocused: Bool) {
        notesEditingIsFocused = isFocused
    }

    func send(_ command: TaskSurfaceCommand) {
        commands.send(command)
    }
}
