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
    /// Stored notes at editor-open time: the optimistic-concurrency baseline
    /// every commit carries. The main surface can open an editor for the same
    /// task while this one is open; a close whose baseline no longer matches
    /// the store is refused (error banner) instead of silently overwriting
    /// the other editor's text, and the deliberate second close wins.
    @State private var notesEditingBaseline = ""

    var body: some View {
        ZStack {
            BCTaskBackground()

            if let storageError = model.storageError {
                storageLockedState(storageError)
            } else if let task = model.activeTasks.first(where: { $0.id == taskID }) {
                // Commit the open draft while its state is still readable:
                // this subtree disappears on panel teardown (unpin, a
                // status move that drops the pin, archive sweep, app stop)
                // as well as in-card state swaps (storage lock, task
                // unavailable) — every one of those would otherwise strand
                // the draft in dying view state.
                taskCard(task)
                    .onDisappear { commitOpenPinnedNotes() }
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
                    // From a live panel this only unpins (reconciliation
                    // strips panels of unpinned tasks), which tears the
                    // panel down: the open draft must not die with it.
                    commitOpenPinnedNotes()
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
                    onCommit: { text in
                        return closeNotesEditor(committing: text, for: task)
                    },
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
                    onSelect: { target in
                        // Todo/Done moves drop the pin, and store
                        // reconciliation then tears this panel down: commit
                        // the open draft first so it survives its own status
                        // change. Doing keeps the pin (and panel) alive.
                        if target != .doing { commitOpenPinnedNotes() }
                        model.setStatus(task, to: target)
                    }
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
            // A failed save keeps the editor open: the verdict is consumed
            // here so the draft survives for retry.
            _ = closeNotesEditor(committing: notesDraft, for: task)
            return
        }
        notesDraft = task.notes
        notesEditingBaseline = task.notes
        isEditingNotes = true
    }

    /// The single commit point: disk-first `setNotes`, once, on close only.
    /// Returns false when the save was refused, failed, or conflicted with a
    /// concurrent editor (the main surface's editor for the same task),
    /// leaving the editor open with its draft — the user's only copy of the
    /// text.
    @discardableResult
    private func closeNotesEditor(committing text: String, for task: TaskItem) -> Bool {
        guard isEditingNotes else { return true }
        let notes = TaskNotes.trimmed(text)
        guard notes != notesEditingBaseline else {
            collapseNotesEditor()
            return true
        }
        guard model.setNotes(task, from: notesEditingBaseline, to: notes) else {
            // Re-anchor the baseline to the store so the deliberate retry
            // (a second close) overwrites on purpose instead of conflicting
            // forever; the error banner already reports why the first
            // close was refused.
            notesEditingBaseline = currentStoredNotes
            return false
        }
        collapseNotesEditor()
        return true
    }

    private func collapseNotesEditor() {
        isEditingNotes = false
        notesDraft = ""
        notesEditingBaseline = ""
    }

    /// Stored notes for this card's task right now: the freshness anchor a
    /// vetoed commit re-reads so its deliberate retry can succeed.
    private var currentStoredNotes: String {
        model.store.tasks.first(where: { $0.id == taskID })?.notes ?? ""
    }

    /// Commits the open draft before this card's content goes away: panel
    /// teardown (unpin, a status move that drops the pin, archive sweep,
    /// app stop) and in-card state swaps (storage lock, task unavailable)
    /// all detach this subtree, and the draft lives nowhere else. Archived
    /// or deleted tasks fold silently — the commit would be refused anyway.
    private func commitOpenPinnedNotes() {
        guard isEditingNotes,
              let task = model.activeTasks.first(where: { $0.id == taskID })
        else { return }
        _ = closeNotesEditor(committing: notesDraft, for: task)
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
