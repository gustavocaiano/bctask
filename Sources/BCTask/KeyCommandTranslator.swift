import AppKit
import Foundation

/// Minimal, test-friendly projection of the keyboard modifiers relevant to
/// the accepted task-surface shortcuts. Value-typed so the translator is a
/// pure, deterministic seam.
struct TaskSurfaceModifiers: OptionSet, Hashable {
    let rawValue: UInt
    init(rawValue: UInt) { self.rawValue = rawValue }

    static let command = TaskSurfaceModifiers(rawValue: 1 << 0)
    static let shift = TaskSurfaceModifiers(rawValue: 1 << 1)
    static let control = TaskSurfaceModifiers(rawValue: 1 << 2)
    static let option = TaskSurfaceModifiers(rawValue: 1 << 3)

    /// Ignores bits that must never disqualify a shortcut: Caps Lock, the
    /// numeric-pad flag, and the synthetic `.function` flag that arrow-key
    /// events carry.
    init(_ flags: NSEvent.ModifierFlags) {
        var projected = TaskSurfaceModifiers()
        if flags.contains(.command) { projected.insert(.command) }
        if flags.contains(.shift) { projected.insert(.shift) }
        if flags.contains(.control) { projected.insert(.control) }
        if flags.contains(.option) { projected.insert(.option) }
        self = projected
    }
}

/// Pure seam mapping a key code + modifiers into a `TaskSurfaceCommand`.
///
/// Only the accepted native shortcuts translate:
/// - Command-N          -> focusNewTask
/// - plain Up / Down    -> focusPreviousTask / focusNextTask
/// - Command-Left/Right -> moveFocusedTaskBackward / moveFocusedTaskForward
/// - Command-P          -> pinFocusedTask
/// - Command-Delete     -> deleteFocusedTask
/// - plain Escape       -> leaveNewTaskEntry
/// - plain Tab          -> toggleProjection
///
/// Everything else returns `nil` so the monitor returns the original event
/// untouched. Extra modifiers (Shift/Control/Option) always disqualify a
/// candidate shortcut.
enum KeyCommandTranslator {
    static let keyCodeN = UInt16(45)          // kVK_ANSI_N
    static let keyCodeUpArrow = UInt16(126)   // kVK_UpArrow
    static let keyCodeDownArrow = UInt16(125) // kVK_DownArrow
    static let keyCodeLeftArrow = UInt16(123) // kVK_LeftArrow
    static let keyCodeRightArrow = UInt16(124) // kVK_RightArrow
    static let keyCodeTab = UInt16(48)         // kVK_Tab
    static let keyCodeEscape = UInt16(53)      // kVK_Escape
    static let keyCodeP = UInt16(35)           // kVK_ANSI_P
    static let keyCodeDelete = UInt16(51)      // kVK_ANSI_Delete (backspace)

    static func translate(event: NSEvent) -> TaskSurfaceCommand? {
        guard event.type == .keyDown else { return nil }
        return translate(keyCode: event.keyCode, modifiers: TaskSurfaceModifiers(event.modifierFlags))
    }

    static func translate(keyCode: UInt16, modifiers: TaskSurfaceModifiers) -> TaskSurfaceCommand? {
        switch keyCode {
        case keyCodeN:
            return modifiers == .command ? .focusNewTask : nil
        case keyCodeUpArrow:
            return modifiers.isEmpty ? .focusPreviousTask : nil
        case keyCodeDownArrow:
            return modifiers.isEmpty ? .focusNextTask : nil
        case keyCodeLeftArrow:
            return modifiers == .command ? .moveFocusedTaskBackward : nil
        case keyCodeRightArrow:
            return modifiers == .command ? .moveFocusedTaskForward : nil
        case keyCodeP:
            return modifiers == .command ? .pinFocusedTask : nil
        case keyCodeDelete:
            // Plain backspace and every modified variant except exactly
            // Command stay in the text system; forward-delete (117) is not
            // ours either.
            return modifiers == .command ? .deleteFocusedTask : nil
        case keyCodeTab:
            // Shift-Tab and every other modified Tab remain untouched for
            // standard reverse-focus/system behavior.
            return modifiers.isEmpty ? .toggleProjection : nil
        case keyCodeEscape:
            return modifiers.isEmpty ? .leaveNewTaskEntry : nil
        default:
            return nil
        }
    }
}

/// Contextual policy for commands recognized by the main panel's local event
/// monitor. Translation remains purely key-based; this bridge decides whether
/// the translated command belongs to the task surface or should continue into
/// AppKit's normal responder chain.
enum MainPanelKeyCommandBridge {
    static func commandToConsume(
        _ command: TaskSurfaceCommand,
        taskEntryIsFocused: Bool
    ) -> TaskSurfaceCommand? {
        if command == .leaveNewTaskEntry && !taskEntryIsFocused {
            return nil
        }
        // Cmd-Backspace is the standard "delete to beginning of line" text
        // edit: while the new-task field is focused, deleteFocusedTask must
        // reach the field instead of the task surface. Cmd-P has no
        // text-field meaning (and the app has no Print), so pinning is
        // consumed in both focus states.
        if command == .deleteFocusedTask && taskEntryIsFocused {
            return nil
        }
        return command
    }
}
