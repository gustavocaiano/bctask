import SwiftUI
import BCTaskCore

/// Phase 3 can host this view directly in an always-on-top `NSPanel`. It looks
/// up the task by identity on every model update, so status changes and unpin
/// actions stay live without copying task state into the panel layer.
struct PinnedTaskCardView: View {
    @ObservedObject var model: AppModel
    let taskID: UUID

    /// Local notes editing state for this single card: one card, one editor,
    /// so the draft can live right here instead of in a shared surface.
    @State private var isEditingNotes = false
    @State private var notesDraft = ""

    var body: some View {
        ZStack {
            BCTaskBackground()

            if let storageError = model.storageError {
                storageLockedState(storageError)
            } else if let task = model.activeTasks.first(where: { $0.id == taskID }) {
                taskCard(task)
            } else {
                unavailableState
            }
        }
        .foregroundStyle(BCTaskTheme.textPrimary)
        .frame(minWidth: 300, idealWidth: 320, maxWidth: 360, minHeight: 210)
        .preferredColorScheme(.dark)
    }

    private func storageLockedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(BCTaskTheme.danger)
                .accessibilityHidden(true)
            Text("Tasks are locked")
                .font(.system(size: 14, weight: .semibold))
            Text("Editing stays off until the task file loads again.")
                .font(.system(size: 12))
                .foregroundStyle(BCTaskTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Reload") {
                model.reload()
            }
            .buttonStyle(BCTaskButtonStyle(kind: .primary))
            .help("Try loading the task file again")
            .accessibilityHint("Attempts to reload storage. Editing remains off if loading fails.")
        }
        .padding(24)
        .help(message)
        .accessibilityElement(children: .contain)
    }

    private func taskCard(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 9) {
                Label("Floating task", systemImage: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BCTaskTheme.accent)
                Spacer()
                TaskNoteButton(
                    hasNotes: TaskNotes.hasContent(task.notes),
                    isEditing: isEditingNotes
                ) {
                    toggleNotesEditing(for: task)
                }
                TaskPinButton(isPinned: task.isPinned) {
                    model.setPinned(task, !task.isPinned)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(task.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BCTaskTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                TaskTimingLabel(task: task)
            }

            // Notes sit between the title block and Status: the card's whole
            // point is keeping one task's detail in front of you, and links
            // here open in the default browser without leaving the panel.
            // Guarded so a note-less card keeps exactly its old layout.
            if isEditingNotes || TaskNotes.hasContent(task.notes) {
                TaskNotesSectionView(
                    task: task,
                    previewMaxHeight: 76,
                    editorMinHeight: 56,
                    editorMaxHeight: 76,
                    isEditing: isEditingNotes,
                    draft: $notesDraft,
                    onCommit: { text in closeNotesEditor(committing: text, for: task) },
                    // Pinned panels are separate nonactivating windows: the main
                    // panel's key monitor only translates while the main panel
                    // is key, so there is no shared routing flag to keep in sync.
                    onEditingFocusChanged: { _ in }
                )
            }

            Rectangle()
                .fill(BCTaskTheme.hairline)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 7) {
                Text("Status")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BCTaskTheme.textTertiary)
                    .textCase(.uppercase)

                TaskStatusControl(
                    task: task,
                    availableTargets: model.availableTargets(for: task),
                    compact: false,
                    onSelect: { model.setStatus(task, to: $0) }
                )
            }

            if let message = model.lastErrorMessage {
                Label("That change couldn’t be completed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BCTaskTheme.danger)
                    .help(message)
                    .accessibilityHint(message)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BCTaskTheme.surface.opacity(0.72))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BCTaskTheme.accent)
                .frame(height: 2)
        }
    }

    /// Note button in the header: commits and closes, or opens with a fresh
    /// draft seeded from the persisted notes.
    private func toggleNotesEditing(for task: TaskItem) {
        if isEditingNotes {
            closeNotesEditor(committing: notesDraft, for: task)
            return
        }
        notesDraft = task.notes
        isEditingNotes = true
    }

    /// The single commit point: disk-first `setNotes`, once, on close only.
    private func closeNotesEditor(committing text: String, for task: TaskItem) {
        guard isEditingNotes else { return }
        isEditingNotes = false
        notesDraft = ""
        let notes = TaskNotes.trimmed(text)
        guard notes != task.notes else { return }
        model.setNotes(task, notes)
    }

    private var unavailableState: some View {
        VStack(spacing: 9) {
            Image(systemName: "archivebox")
                .font(.system(size: 22))
                .foregroundStyle(BCTaskTheme.textTertiary)
                .accessibilityHidden(true)
            Text("Task no longer active")
                .font(.system(size: 14, weight: .semibold))
            Text("It may have moved to the archive.")
                .font(.system(size: 12))
                .foregroundStyle(BCTaskTheme.textSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}
