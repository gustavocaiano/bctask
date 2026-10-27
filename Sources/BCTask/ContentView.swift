import SwiftUI
import BCTaskCore

/// The complete menu-bar experience. Active tasks have exactly two projections
/// (List and Kanban); archive browsing is a separate destination over the same
/// persisted store.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var commandRouter: TaskCommandRouter
    @State private var draft = ""
    @State private var section: SurfaceSection = .tasks
    @State private var projection: ActiveTaskProjection = .list
    @State private var focusedTaskID: UUID?
    @FocusState private var entryIsFocused: Bool

    var body: some View {
        ZStack {
            BCTaskBackground()

            if let storageError = model.storageError {
                // Storage locked: this branch intentionally exposes no task
                // mutation controls. Reload is the sole recovery action.
                StorageRecoveryView(message: storageError) {
                    model.reload()
                    if model.storageError == nil {
                        section = .tasks
                        ensureTaskFocus()
                        setEntryFocus(true)
                    }
                }
            } else {
                surface
            }
        }
        .foregroundStyle(BCTaskTheme.textPrimary)
        .task {
            ensureTaskFocus()
            setEntryFocus(model.storageError == nil)
        }
        .onReceive(commandRouter.commands, perform: handleCommand)
        .onChange(of: entryIsFocused) { isFocused in
            // Mirrors user/AppKit-driven focus changes that do not pass
            // through a programmatic focus helper.
            commandRouter.updateTaskEntryFocus(isFocused)
        }
        .onChange(of: activeTaskIDs) { _ in
            ensureTaskFocus()
        }
        .onChange(of: model.storageError) { storageError in
            if storageError != nil {
                setEntryFocus(false)
            }
        }
    }

    private var surface: some View {
        VStack(spacing: 0) {
            AppHeaderView(
                section: $section,
                activeCount: model.activeTasks.count,
                archiveCount: model.archivedTasks.count
            )

            Rectangle()
                .fill(BCTaskTheme.hairline)
                .frame(height: 1)

            Group {
                switch section {
                case .tasks:
                    activeTaskSurface
                case .archive:
                    ArchiveTaskView(tasks: model.archivedTasks) { task in
                        model.restore(task)
                    } onDelete: { task in
                        model.delete(task)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let message = model.lastErrorMessage {
                OperationErrorBanner(message: message)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .onChange(of: section) { newSection in
            if newSection == .tasks {
                ensureTaskFocus()
                setEntryFocus(true)
            } else {
                setEntryFocus(false)
            }
        }
        .onChange(of: projection) { _ in
            ensureTaskFocus()
        }
    }

    private var activeTaskSurface: some View {
        VStack(spacing: 12) {
            TaskEntryView(
                draft: $draft,
                isFocused: $entryIsFocused,
                onAdd: addDraft
            )
            .padding(.horizontal, 16)
            .padding(.top, 14)

            HStack(spacing: 12) {
                Text(activeSummary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(BCTaskTheme.textSecondary)
                    .monospacedDigit()

                Spacer(minLength: 12)

                Picker("Active task view", selection: $projection) {
                    Label("List", systemImage: "list.bullet")
                        .tag(ActiveTaskProjection.list)
                    Label("Kanban", systemImage: "rectangle.split.3x1")
                        .tag(ActiveTaskProjection.kanban)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 218)
                .tint(BCTaskTheme.accent)
                .accessibilityLabel("Active task view")
                .accessibilityHint("Choose List or Kanban.")
            }
            .padding(.horizontal, 16)

            Group {
                switch projection {
                case .list:
                    TaskListView(
                        tasks: model.activeTasks,
                        focusedTaskID: focusedTaskID,
                        onFocusTask: focusTask
                    )
                case .kanban:
                    TaskKanbanView(
                        tasks: model.activeTasks,
                        focusedTaskID: focusedTaskID,
                        onFocusTask: focusTask
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                TaskShortcutMenu(commandRouter: commandRouter)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .environmentObject(model)
    }

    private var activeSummary: String {
        let count = model.activeTasks.count
        return count == 1 ? "1 active task" : "\(count) active tasks"
    }

    private func addDraft() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        let previousIDs = Set(model.activeTasks.map(\.id))
        model.add(title)

        // Keep a refused or failed entry available for retry. A successful add
        // publishes synchronously and introduces one new active-task identity.
        if let addedTask = model.activeTasks.first(where: { !previousIDs.contains($0.id) }) {
            draft = ""
            focusedTaskID = addedTask.id
        }
        setEntryFocus(true)
    }

    private var activeTaskIDs: [UUID] {
        model.activeTasks.map(\.id)
    }

    private var focusOrderedTasks: [TaskItem] {
        switch projection {
        case .list:
            return model.activeTasks
        case .kanban:
            return TaskStatus.allCases.flatMap { status in
                model.activeTasks.filter { $0.status == status }
            }
        }
    }

    private func ensureTaskFocus() {
        let availableIDs = Set(model.activeTasks.map(\.id))
        if let focusedTaskID, availableIDs.contains(focusedTaskID) {
            return
        }
        focusedTaskID = focusOrderedTasks.first?.id
    }

    private func focusTask(_ id: UUID) {
        guard model.activeTasks.contains(where: { $0.id == id }) else { return }
        focusedTaskID = id
        setEntryFocus(false)
    }

    private func handleCommand(_ command: TaskSurfaceCommand) {
        guard model.storageError == nil else { return }

        switch command {
        case .focusNewTask:
            section = .tasks
            setEntryFocus(true)
        case .focusPreviousTask:
            guard section == .tasks else { return }
            moveTaskFocus(by: -1)
        case .focusNextTask:
            guard section == .tasks else { return }
            moveTaskFocus(by: 1)
        case .moveFocusedTaskBackward:
            guard section == .tasks else { return }
            moveFocusedTask(by: -1)
        case .moveFocusedTaskForward:
            guard section == .tasks else { return }
            moveFocusedTask(by: 1)
        case .pinFocusedTask:
            guard section == .tasks else { return }
            guard let focusedTaskID,
                  let task = model.activeTasks.first(where: { $0.id == focusedTaskID })
            else { return }
            model.setPinned(task, !task.isPinned)
            // Do not touch entry focus: pinning must not steal typing focus.
        case .deleteFocusedTask:
            guard section == .tasks else { return }
            guard let focusedTaskID,
                  let task = model.activeTasks.first(where: { $0.id == focusedTaskID })
            else { return }
            // Neighbor-focus: after deleting, focus the next task in the current
            // projection order, else the previous one (macOS list convention).
            let ordered = focusOrderedTasks
            var neighbor: UUID?
            if let index = ordered.firstIndex(where: { $0.id == task.id }) {
                if ordered.indices.contains(index + 1) { neighbor = ordered[index + 1].id }
                else if index > 0 { neighbor = ordered[index - 1].id }
            }
            setEntryFocus(false)
            model.delete(task)
            self.focusedTaskID = neighbor
        case .leaveNewTaskEntry:
            // Escape leaves typing without discarding the in-progress draft.
            setEntryFocus(false)
        case .toggleProjection:
            // The native monitor intentionally consumes Tab while typing. The
            // user leaves entry with Escape before projection switching.
            guard section == .tasks, !entryIsFocused else { return }
            projection = projection == .list ? .kanban : .list
            ensureTaskFocus()
        }
    }

    private func moveTaskFocus(by offset: Int) {
        let tasks = focusOrderedTasks
        guard !tasks.isEmpty else {
            focusedTaskID = nil
            return
        }

        guard let focusedTaskID,
              let currentIndex = tasks.firstIndex(where: { $0.id == focusedTaskID })
        else {
            self.focusedTaskID = offset < 0 ? tasks.last?.id : tasks.first?.id
            setEntryFocus(false)
            return
        }

        let targetIndex = currentIndex + offset
        guard tasks.indices.contains(targetIndex) else { return }
        self.focusedTaskID = tasks[targetIndex].id
        setEntryFocus(false)
    }

    private func moveFocusedTask(by offset: Int) {
        guard let focusedTaskID,
              let task = model.activeTasks.first(where: { $0.id == focusedTaskID }),
              let currentIndex = TaskStatus.allCases.firstIndex(of: task.status)
        else { return }

        let targetIndex = currentIndex + offset
        guard TaskStatus.allCases.indices.contains(targetIndex) else { return }
        let target = TaskStatus.allCases[targetIndex]
        guard model.availableTargets(for: task).contains(target) else { return }

        setEntryFocus(false)
        model.setStatus(task, to: target)
        self.focusedTaskID = task.id
    }

    /// Programmatic focus changes update the native routing intent first, then
    /// apply the matching SwiftUI focus state. That ordering lets the local
    /// event monitor observe Escape's focus release before the next key event.
    private func setEntryFocus(_ isFocused: Bool) {
        commandRouter.updateTaskEntryFocus(isFocused)
        entryIsFocused = isFocused
    }
}

private enum SurfaceSection: String, CaseIterable, Hashable {
    case tasks
    case archive
}

private enum ActiveTaskProjection: String, CaseIterable, Hashable {
    case list
    case kanban
}

private struct TaskShortcutMenu: View {
    @ObservedObject var commandRouter: TaskCommandRouter

    var body: some View {
        Menu {
            Button {
                commandRouter.send(.focusNewTask)
            } label: {
                Label("Focus new task", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button {
                commandRouter.send(.leaveNewTaskEntry)
            } label: {
                Label("Leave new-task entry", systemImage: "escape")
            }

            Button {
                commandRouter.send(.toggleProjection)
            } label: {
                Label("Toggle List and Kanban", systemImage: "rectangle.2.swap")
            }
            .keyboardShortcut(.tab, modifiers: [])

            Divider()

            Button {
                commandRouter.send(.focusPreviousTask)
            } label: {
                Label("Focus previous task", systemImage: "arrow.up")
            }
            .keyboardShortcut(.upArrow, modifiers: [])

            Button {
                commandRouter.send(.focusNextTask)
            } label: {
                Label("Focus next task", systemImage: "arrow.down")
            }
            .keyboardShortcut(.downArrow, modifiers: [])

            Divider()

            Button {
                commandRouter.send(.moveFocusedTaskBackward)
            } label: {
                Label("Move focused task backward", systemImage: "arrow.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Button {
                commandRouter.send(.moveFocusedTaskForward)
            } label: {
                Label("Move focused task forward", systemImage: "arrow.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)

            Divider()

            Button {
                commandRouter.send(.pinFocusedTask)
            } label: {
                Label("Pin or unpin focused task", systemImage: "pin")
            }
            .keyboardShortcut("p", modifiers: .command)

            Button {
                commandRouter.send(.deleteFocusedTask)
            } label: {
                Label("Delete focused task", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
        } label: {
            Label("Esc Leave / Hide  ·  Tab View  ·  ↑↓ Focus  ·  ⌘←/⌘→ Move  ·  ⌘P Pin  ·  ⌘⌫ Delete", systemImage: "keyboard")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(BCTaskTheme.textTertiary)
                .frame(minHeight: 30)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Task keyboard shortcuts")
        .accessibilityLabel("Task keyboard shortcuts")
        // While a notes editor holds keyboard focus every surface shortcut is
        // suspended (the key monitor yields all keys to the text system); the
        // menu's key equivalents are gated to match, so e.g. ⌘⌫ can never
        // delete the focused task mid-note.
        .disabled(commandRouter.notesEditingIsFocused)
    }
}

private struct AppHeaderView: View {
    @Binding var section: SurfaceSection
    let activeCount: Int
    let archiveCount: Int

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(BCTaskTheme.accent.opacity(0.14))
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(BCTaskTheme.accent)
                        .accessibilityHidden(true)
                }
                .frame(width: 38, height: 38)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(BCTaskTheme.accent.opacity(0.2), lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("BCTask")
                        .font(.system(size: 16, weight: .semibold))
                    Text(section == .tasks ? "Todo, Doing, and Done." : "Tasks completed earlier.")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(BCTaskTheme.textSecondary)
                }
            }

            Spacer(minLength: 12)

            Picker("Task collection", selection: $section) {
                Text("Tasks  \(activeCount)")
                    .tag(SurfaceSection.tasks)
                Text("Archive  \(archiveCount)")
                    .tag(SurfaceSection.archive)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .tint(BCTaskTheme.accent)
            .accessibilityLabel("Task collection")
            .accessibilityHint("Switch between active tasks and the archive.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct TaskEntryView: View {
    @Binding var draft: String
    var isFocused: FocusState<Bool>.Binding
    let onAdd: () -> Void

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isFocused.wrappedValue ? BCTaskTheme.accent : BCTaskTheme.textTertiary)
                .accessibilityHidden(true)

            TextField("What needs doing?", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .regular))
                .focused(isFocused)
                .onSubmit(onAdd)
                .accessibilityLabel("New task")
                .accessibilityHint("Type a task and press Return to add it. Press Escape before using Tab to switch views.")

            Button(action: onAdd) {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(BCTaskButtonStyle(kind: .primary, compact: true))
            .disabled(trimmedDraft.isEmpty)
            .help("Add task (Return)")
            .accessibilityLabel("Add task")
            .accessibilityHint("Adds the task to Todo.")
        }
        .padding(.leading, 13)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(BCTaskTheme.surfaceRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    isFocused.wrappedValue ? BCTaskTheme.accent.opacity(0.68) : BCTaskTheme.hairlineStrong,
                    lineWidth: 1
                )
        }
        .shadow(color: BCTaskTheme.accent.opacity(isFocused.wrappedValue ? 0.08 : 0), radius: 12)
    }
}

private struct StorageRecoveryView: View {
    let message: String
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(BCTaskTheme.danger.opacity(0.12))
                Image(systemName: "lock.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(BCTaskTheme.danger)
                    .accessibilityHidden(true)
            }
            .frame(width: 52, height: 52)

            VStack(spacing: 7) {
                Text("Tasks are locked")
                    .font(.system(size: 20, weight: .semibold))
                Text("BCTask couldn’t read your task file. To protect it, editing stays off until the file loads again.")
                    .font(.system(size: 13))
                    .foregroundStyle(BCTaskTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
            }

            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(BCTaskTheme.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: 440)

            Button("Reload", action: onReload)
                .buttonStyle(BCTaskButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .help("Try loading the task file again")
                .accessibilityHint("Attempts to reload storage. Editing remains off if loading fails.")
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct OperationErrorBanner: View {
    let message: String

    private var conciseMessage: String {
        if message.contains("emptyTitle") {
            return "Give the task a name."
        }
        if message.hasPrefix("Could not save tasks") {
            return "Couldn’t save that change. Your previous tasks are safe."
        }
        if message.hasPrefix("Task action rejected") {
            return "That task changed before the action finished. Try again."
        }
        return "That change couldn’t be completed. Try again."
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BCTaskTheme.danger)
                .accessibilityHidden(true)
            Text(conciseMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BCTaskTheme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BCTaskTheme.danger.opacity(0.09))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BCTaskTheme.danger.opacity(0.22), lineWidth: 1)
        }
        .help(message)
        .accessibilityLabel("Error: \(conciseMessage)")
        .accessibilityHint(message)
    }
}
