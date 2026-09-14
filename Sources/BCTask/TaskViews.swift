import SwiftUI
import BCTaskCore

struct TaskListView: View {
    @EnvironmentObject private var model: AppModel
    let tasks: [TaskItem]
    let focusedTaskID: UUID?
    let onFocusTask: (UUID) -> Void

    var body: some View {
        if tasks.isEmpty {
            EmptyTaskStateView(
                symbol: "checkmark.circle",
                title: "Nothing on your list",
                message: "Add a task above when something comes up."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(tasks) { task in
                            TaskListRowView(
                                task: task,
                                availableTargets: model.availableTargets(for: task),
                                isFocused: focusedTaskID == task.id,
                                onFocus: { onFocusTask(task.id) },
                                onStatus: { model.setStatus(task, to: $0) },
                                onPin: { model.setPinned(task, $0) },
                                onDelete: { model.delete(task) }
                            )
                            .id(task.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .onChange(of: focusedTaskID) { taskID in
                    guard let taskID else { return }
                    proxy.scrollTo(taskID, anchor: .center)
                }
            }
        }
    }
}

struct TaskKanbanView: View {
    @EnvironmentObject private var model: AppModel
    let tasks: [TaskItem]
    let focusedTaskID: UUID?
    let onFocusTask: (UUID) -> Void

    @State private var draggedTaskID: UUID?

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            KanbanColumnView(
                                status: status,
                                tasks: tasks.filter { $0.status == status },
                                allTasks: tasks,
                                focusedTaskID: focusedTaskID,
                                draggedTaskID: draggedTaskID,
                                minimumHeight: max(geometry.size.height - 4, 250),
                                availableTargets: model.availableTargets,
                                onFocus: onFocusTask,
                                onDragBegan: { draggedTaskID = $0 },
                                onDragFinished: { draggedTaskID = nil },
                                onStatus: { task, target in
                                    guard model.availableTargets(for: task).contains(target) else {
                                        return false
                                    }
                                    model.setStatus(task, to: target)
                                    onFocusTask(task.id)
                                    return true
                                },
                                onPin: { task, pinned in
                                    model.setPinned(task, pinned)
                                },
                                onDelete: { task in
                                    model.delete(task)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .onChange(of: focusedTaskID) { taskID in
                    guard let taskID else { return }
                    proxy.scrollTo(taskID, anchor: .center)
                }
            }
        }
    }
}

struct ArchiveTaskView: View {
    let tasks: [TaskItem]
    let onRestore: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Archive")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Restore anything you still need.")
                        .font(.system(size: 12))
                        .foregroundStyle(BCTaskTheme.textSecondary)
                }
                Spacer()
                Text("\(tasks.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BCTaskTheme.textSecondary)
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(BCTaskTheme.surfaceRaised, in: Capsule())
                    .accessibilityLabel("\(tasks.count) archived tasks")
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)

            if tasks.isEmpty {
                EmptyTaskStateView(
                    symbol: "archivebox",
                    title: "The archive is empty",
                    message: "Done tasks move here after one hour."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(tasks) { task in
                            ArchiveTaskRowView(
                                task: task,
                                onRestore: {
                                    onRestore(task)
                                },
                                onDelete: {
                                    onDelete(task)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        }
    }
}

struct TaskListRowView: View {
    let task: TaskItem
    let availableTargets: [TaskStatus]
    let isFocused: Bool
    let onFocus: () -> Void
    let onStatus: (TaskStatus) -> Void
    let onPin: (Bool) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(BCTaskTheme.statusColor(task.status))
                .frame(width: 3, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BCTaskTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TaskTimingLabel(task: task)
            }
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)

            TaskStatusBadge(status: task.status)

            TaskStatusMenu(
                taskTitle: task.title,
                currentStatus: task.status,
                availableTargets: availableTargets,
                onSelect: onStatus
            )

            TaskPinButton(isPinned: task.isPinned) {
                onPin(!task.isPinned)
            }

            TaskDeleteButton {
                onDelete()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isFocused
                        ? BCTaskTheme.accent.opacity(0.075)
                        : (isHovering ? BCTaskTheme.surfaceHover : BCTaskTheme.surface)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isFocused
                        ? BCTaskTheme.accent.opacity(0.78)
                        : (task.isPinned ? BCTaskTheme.accent.opacity(0.18) : BCTaskTheme.hairline),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onFocus)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.title)
        .accessibilityValue(isFocused ? "Focused, \(task.status.displayName)" : task.status.displayName)
    }
}

private struct TaskStatusBadge: View {
    let status: TaskStatus

    var body: some View {
        Label(status.displayName, systemImage: status.selectedSymbolName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(BCTaskTheme.statusColor(status))
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(BCTaskTheme.statusColor(status).opacity(0.10), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(BCTaskTheme.statusColor(status).opacity(0.20), lineWidth: 1)
            }
            .accessibilityLabel("Status: \(status.displayName)")
    }
}

private struct TaskStatusMenu: View {
    let taskTitle: String
    let currentStatus: TaskStatus
    let availableTargets: [TaskStatus]
    let onSelect: (TaskStatus) -> Void

    var body: some View {
        Menu {
            Button {} label: {
                Label("Current: \(currentStatus.displayName)", systemImage: currentStatus.selectedSymbolName)
            }
            .disabled(true)

            Divider()

            ForEach(TaskStatus.allCases.filter { availableTargets.contains($0) }, id: \.self) { status in
                Button {
                    onSelect(status)
                } label: {
                    Label("Move to \(status.displayName)", systemImage: status.symbolName)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BCTaskTheme.textSecondary)
                .frame(width: 40, height: 40)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change status")
        .accessibilityLabel("Change status for \(taskTitle)")
        .accessibilityHint("Opens Todo, Doing, and Done actions.")
    }
}

private struct KanbanColumnView: View {
    let status: TaskStatus
    let tasks: [TaskItem]
    let allTasks: [TaskItem]
    let focusedTaskID: UUID?
    let draggedTaskID: UUID?
    let minimumHeight: CGFloat
    let availableTargets: (TaskItem) -> [TaskStatus]
    let onFocus: (UUID) -> Void
    let onDragBegan: (UUID) -> Void
    let onDragFinished: () -> Void
    let onStatus: (TaskItem, TaskStatus) -> Bool
    let onPin: (TaskItem, Bool) -> Void
    let onDelete: (TaskItem) -> Void

    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActiveDropTarget: Bool {
        guard isDropTargeted,
              let draggedTaskID,
              let source = allTasks.first(where: { $0.id == draggedTaskID })
        else { return false }
        return source.status != status
    }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: status.selectedSymbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BCTaskTheme.statusColor(status))
                    .accessibilityHidden(true)
                Text(status.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BCTaskTheme.statusColor(status))
                Spacer()
                if isActiveDropTarget {
                    Label("Move here", systemImage: "arrow.down.to.line")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BCTaskTheme.statusColor(status))
                } else {
                    Text("\(tasks.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BCTaskTheme.textSecondary)
                        .monospacedDigit()
                        .accessibilityLabel("\(tasks.count) tasks")
                }
            }
            .padding(.horizontal, 2)

            if tasks.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: status.symbolName)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(BCTaskTheme.statusColor(status).opacity(0.62))
                        .accessibilityHidden(true)
                    Text(emptyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(BCTaskTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 92)
                .accessibilityElement(children: .combine)
            } else {
                ForEach(tasks) { task in
                    KanbanTaskCardView(
                        task: task,
                        availableTargets: availableTargets(task),
                        isFocused: focusedTaskID == task.id,
                        onFocus: { onFocus(task.id) },
                        onDragBegan: { onDragBegan(task.id) },
                        onStatus: { target in
                            _ = onStatus(task, target)
                        },
                        onPin: { onPin(task, $0) },
                        onDelete: { onDelete(task) }
                    )
                    .id(task.id)
                }
            }

            if status == .done {
                Label("Archives after 1 hour", systemImage: "clock")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(BCTaskTheme.textTertiary)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BCTaskTheme.statusColor(status).opacity(isActiveDropTarget ? 0.11 : 0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isActiveDropTarget
                        ? BCTaskTheme.statusColor(status).opacity(0.78)
                        : BCTaskTheme.hairline,
                    lineWidth: isActiveDropTarget ? 2 : 1
                )
        }
        .shadow(
            color: isActiveDropTarget ? BCTaskTheme.accent.opacity(0.10) : .clear,
            radius: 14
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isActiveDropTarget)
        .onDrop(
            of: [KanbanTaskDragPayload.typeIdentifier],
            delegate: KanbanColumnDropDelegate(
                targetStatus: status,
                allTasks: allTasks,
                draggedTaskID: draggedTaskID,
                isTargeted: $isDropTargeted,
                onMove: { move in
                    guard let task = allTasks.first(where: { $0.id == move.taskID }) else {
                        return false
                    }
                    return onStatus(task, move.targetStatus)
                },
                onFinish: onDragFinished
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.displayName), \(tasks.count) tasks")
        .accessibilityHint("Drop a Kanban card here to move it to \(status.displayName).")
    }

    private var emptyMessage: String {
        switch status {
        case .todo: "Nothing waiting"
        case .doing: "Nothing in progress"
        case .done: "Nothing done yet"
        }
    }
}

private struct KanbanTaskCardView: View {
    let task: TaskItem
    let availableTargets: [TaskStatus]
    let isFocused: Bool
    let onFocus: () -> Void
    let onDragBegan: () -> Void
    let onStatus: (TaskStatus) -> Void
    let onPin: (Bool) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 5) {
                Text(task.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(BCTaskTheme.textPrimary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TaskPinButton(isPinned: task.isPinned) {
                    onPin(!task.isPinned)
                }

                TaskDeleteButton {
                    onDelete()
                }
            }

            TaskTimingLabel(task: task)

            TaskStatusControl(
                task: task,
                availableTargets: availableTargets,
                compact: true,
                onSelect: onStatus
            )
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    isFocused
                        ? BCTaskTheme.accent.opacity(0.075)
                        : (isHovering ? BCTaskTheme.surfaceHover : BCTaskTheme.surfaceRaised)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    isFocused
                        ? BCTaskTheme.accent.opacity(0.82)
                        : (task.isPinned ? BCTaskTheme.accent.opacity(0.22) : BCTaskTheme.hairline),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture(perform: onFocus)
        .onDrag {
            onDragBegan()
            return KanbanTaskDragPayload(taskID: task.id).itemProvider()
        } preview: {
            KanbanTaskDragPreview(task: task, reduceMotion: reduceMotion)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.title)
        .accessibilityValue(isFocused ? "Focused, \(task.status.displayName)" : task.status.displayName)
        .accessibilityHint("Drag to another Kanban column to change status. Status buttons remain available.")
    }
}

private struct KanbanTaskDragPreview: View {
    let task: TaskItem
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(task.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BCTaskTheme.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Label(task.status.displayName, systemImage: task.status.selectedSymbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BCTaskTheme.statusColor(task.status))
        }
        .padding(13)
        .frame(width: 210, alignment: .leading)
        .background(BCTaskTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BCTaskTheme.accent.opacity(0.72), lineWidth: 1.5)
        }
        .shadow(color: BCTaskTheme.accent.opacity(0.18), radius: 16, y: 8)
        .opacity(0.94)
        .scaleEffect(reduceMotion ? 1 : 1.02)
        .accessibilityHidden(true)
    }
}

private struct KanbanColumnDropDelegate: DropDelegate {
    let targetStatus: TaskStatus
    let allTasks: [TaskItem]
    let draggedTaskID: UUID?
    @Binding var isTargeted: Bool
    let onMove: (KanbanStatusMove) -> Bool
    let onFinish: () -> Void

    private var currentStatuses: [UUID: TaskStatus] {
        Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0.status) })
    }

    private func provider(from info: DropInfo) -> NSItemProvider? {
        info.itemProviders(for: [KanbanTaskDragPayload.typeIdentifier]).first
    }

    private func canAccept(_ info: DropInfo) -> Bool {
        guard provider(from: info) != nil,
              let draggedTaskID,
              let sourceStatus = currentStatuses[draggedTaskID]
        else { return false }
        return sourceStatus != targetStatus
    }

    func validateDrop(info: DropInfo) -> Bool {
        canAccept(info)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = canAccept(info)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: canAccept(info) ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            isTargeted = false
            onFinish()
        }

        guard canAccept(info),
              let provider = provider(from: info),
              let encodedPayload = provider.suggestedName,
              let move = KanbanDropResolver.resolve(
                encodedPayload: encodedPayload,
                currentStatuses: currentStatuses,
                targetStatus: targetStatus
              ),
              move.taskID == draggedTaskID
        else { return false }

        return onMove(move)
    }
}

private struct ArchiveTaskRowView: View {
    let task: TaskItem
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BCTaskTheme.textTertiary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let archivedAt = task.archivedAt {
                    (Text("Archived ") + Text(archivedAt, style: .relative))
                        .font(.system(size: 11))
                        .foregroundStyle(BCTaskTheme.textTertiary)
                }
            }

            Spacer(minLength: 12)

            Button(action: onRestore) {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(BCTaskButtonStyle(kind: .secondary))
            .help("Restore to Todo")
            .accessibilityLabel("Restore \(task.title)")
            .accessibilityHint("Moves this task back to Todo.")

            TaskDeleteButton {
                onDelete()
            }
            .help("Delete from archive")
            .accessibilityLabel("Delete \(task.title) from archive")
            .accessibilityHint("Removes this archived task permanently. There is no undo.")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(BCTaskTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BCTaskTheme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct TaskStatusControl: View {
    let task: TaskItem
    let availableTargets: [TaskStatus]
    let compact: Bool
    let onSelect: (TaskStatus) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                if status == task.status {
                    statusLabel(status, selected: true)
                        .accessibilityLabel(Text("Current status: " + status.displayName))
                        .accessibilityAddTraits(.isSelected)
                } else {
                    Button {
                        onSelect(status)
                    } label: {
                        statusLabel(status, selected: false)
                    }
                    .buttonStyle(TaskStatusActionButtonStyle())
                    .disabled(!availableTargets.contains(status))
                    .help("Move to \(status.displayName)")
                    .accessibilityLabel("Move \(task.title) to \(status.displayName)")
                    .accessibilityHint("Changes the task status to \(status.displayName).")
                }
            }
        }
        .padding(2)
        .background(BCTaskTheme.canvas.opacity(0.52), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BCTaskTheme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status for \(task.title)")
    }

    private func statusLabel(_ status: TaskStatus, selected: Bool) -> some View {
        Group {
            if compact {
                Image(systemName: selected ? status.selectedSymbolName : status.symbolName)
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Label(status.displayName, systemImage: selected ? status.selectedSymbolName : status.symbolName)
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundStyle(selected ? BCTaskTheme.statusColor(status) : BCTaskTheme.textSecondary)
        .frame(minWidth: compact ? 40 : 55, minHeight: 40)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? BCTaskTheme.statusColor(status).opacity(0.12) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct TaskPinButton: View {
    let isPinned: Bool
    let action: () -> Void

    private var actionLabel: String {
        isPinned ? "Stop keeping this task floating" : "Keep this task floating"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
        }
        .buttonStyle(BCTaskIconButtonStyle(isActive: isPinned))
        .help(actionLabel)
        .accessibilityLabel(actionLabel)
        .accessibilityValue(isPinned ? "On" : "Off")
        .accessibilityHint(isPinned ? "Unpins this task." : "Pins this task for the floating task window.")
    }
}

struct TaskDeleteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
        }
        .buttonStyle(BCTaskIconButtonStyle(isActive: false))
        .help("Delete task")
        .accessibilityLabel("Delete task")
        .accessibilityHint("Removes this task permanently. There is no undo.")
    }
}

private struct TaskStatusActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.70 : 1) : 0.38)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isFocused ? BCTaskTheme.accent : .clear, lineWidth: 2)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.10),
                value: configuration.isPressed
            )
    }
}

struct TaskTimingLabel: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: task.status == .done ? "clock" : task.status.symbolName)
                .accessibilityHidden(true)
            if let deadline = TaskStore.archivalDeadline(of: task) {
                Text("Archives ") + Text(deadline, style: .relative)
            } else {
                Text(task.status == .doing ? "In progress" : "Ready")
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(BCTaskTheme.statusColor(task.status))
    }
}

struct EmptyTaskStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(BCTaskTheme.accent.opacity(0.08))
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(BCTaskTheme.accent.opacity(0.78))
                    .accessibilityHidden(true)
            }
            .frame(width: 50, height: 50)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(BCTaskTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
