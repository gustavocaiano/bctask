import SwiftUI
import BCTaskCore

/// Phase 3 can host this view directly in an always-on-top `NSPanel`. It looks
/// up the task by identity on every model update, so status changes and unpin
/// actions stay live without copying task state into the panel layer.
struct PinnedTaskCardView: View {
    @ObservedObject var model: AppModel
    let taskID: UUID

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
