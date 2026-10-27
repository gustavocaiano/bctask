import AppKit
import BCTaskCore
import SwiftUI

/// Shared reading rules for `TaskItem.notes`.
///
/// Notes are persisted verbatim, so the only normalisation the surface layer
/// applies is on the way IN: an editor that visually trims must not be able
/// to store a whitespace-only value, because empty string is the domain's
/// "no notes" marker.
enum TaskNotes {
    /// Whitespace-normalised form used for comparisons and commits.
    static func trimmed(_ notes: String) -> String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the task carries visible note content.
    static func hasContent(_ notes: String) -> Bool {
        !trimmed(notes).isEmpty
    }
}

/// Read-only note text with automatically detected, clickable links.
///
/// `NSDataDetector` finds link runs, which are painted with the accent token,
/// underlined, and tagged with `.link`; every other run keeps the caller's
/// colour. SwiftUI's `Text` opens `.link` runs in the default browser on its
/// own, so no `openURL` plumbing (and no button) is needed here.
///
/// Important: callers must NOT apply `foregroundStyle` to this view. That
/// would flatten the per-run colors, including the accent-colored links.
struct LinkifiedText: View {
    let text: String
    var color: Color = BCTaskTheme.textSecondary
    var font: Font = .system(size: 11)

    var body: some View {
        Text(Self.attributed(text: text, baseColor: color))
            .font(font)
    }

    /// Builds the link-tagged attributed string. Kept static so previews and
    /// any future surface share one detection implementation.
    static func attributed(text: String, baseColor: Color) -> AttributedString {
        let mutable = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        guard fullRange.length > 0 else { return AttributedString() }

        mutable.addAttribute(.foregroundColor, value: NSColor(baseColor), range: fullRange)

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, options: [], range: fullRange) {
                guard let url = match.url else { continue }
                mutable.addAttribute(.link, value: url, range: match.range)
                mutable.addAttribute(.foregroundColor, value: NSColor(BCTaskTheme.accent), range: match.range)
                mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            }
        }
        return AttributedString(mutable)
    }
}

/// Multiline, wrapping, line-limited notes preview with clickable links.
struct TaskNotesPreview: View {
    let notes: String
    var lineLimit: Int? = 2
    var color: Color = BCTaskTheme.textSecondary
    var font: Font = .system(size: 11)

    var body: some View {
        LinkifiedText(text: notes, color: color, font: font)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Notes: \(TaskNotes.trimmed(notes))")
    }
}

/// The note affordance in a row/card action cluster.
///
/// Mirrors `TaskPinButton` exactly (same icon-button style, same 40pt hit
/// target, same accent-when-active language) so the cluster keeps one rhythm.
struct TaskNoteButton: View {
    let hasNotes: Bool
    let isEditing: Bool
    let action: () -> Void

    private var actionLabel: String {
        if isEditing { return "Close the note on this task" }
        return hasNotes ? "Edit the note on this task" : "Add a note to this task"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: hasNotes || isEditing ? "note.text" : "note")
        }
        .buttonStyle(BCTaskIconButtonStyle(isActive: hasNotes || isEditing))
        .help(actionLabel)
        .accessibilityLabel(actionLabel)
        .accessibilityValue(hasNotes ? "Note saved" : "No note")
        .accessibilityHint(
            isEditing
                ? "Saves any change and closes the notes editor."
                : "Opens the notes editor for this task."
        )
    }
}

/// The expandable notes affordance for one task: a read-only linkified preview
/// while collapsed, a themed editor while expanded, and nothing at all for a
/// task without notes (so untouched rows look exactly as before).
///
/// State lives with the hosting surface (list, Kanban board, pinned card) so
/// only one editor can be open at a time and an abandoned draft can be
/// committed by the surface that owns it.
struct TaskNotesSectionView: View {
    let task: TaskItem
    var previewLineLimit: Int? = 2
    /// When set, the collapsed preview becomes scroll-bounded instead of
    /// line-limited. Used by the pinned panel, which has no vertical room to
    /// grow forever.
    var previewMaxHeight: CGFloat? = nil
    var editorMinHeight: CGFloat = 72
    var editorMaxHeight: CGFloat = 108
    let isEditing: Bool
    @Binding var draft: String
    /// Called with the final (already trimmed) text whenever the editor closes.
    let onCommit: (String) -> Void
    /// Routes "the notes editor owns the keyboard" into the shared command
    /// router. Only live editors push `true`/`false` (appear/resign/close) —
    /// a departing editor publishes nothing, so a re-inserted instance of the
    /// same editor can never have its flag clobbered by the old copy's
    /// disappearance. Surfaces own every `false` that stems from their own
    /// removal (collapse, delete, surface switch).
    var onEditingFocusChanged: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        task: TaskItem,
        previewLineLimit: Int? = 2,
        previewMaxHeight: CGFloat? = nil,
        editorMinHeight: CGFloat = 72,
        editorMaxHeight: CGFloat = 108,
        isEditing: Bool,
        draft: Binding<String>,
        onCommit: @escaping (String) -> Void,
        onEditingFocusChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.task = task
        self.previewLineLimit = previewLineLimit
        self.previewMaxHeight = previewMaxHeight
        self.editorMinHeight = editorMinHeight
        self.editorMaxHeight = editorMaxHeight
        self.isEditing = isEditing
        _draft = draft
        self.onCommit = onCommit
        self.onEditingFocusChanged = onEditingFocusChanged
    }

    var body: some View {
        Group {
            if isEditing {
                TaskNotesEditor(
                    taskTitle: task.title,
                    draft: $draft,
                    minimumHeight: editorMinHeight,
                    maximumHeight: editorMaxHeight,
                    onCommit: onCommit,
                    onEditingFocusChanged: onEditingFocusChanged
                )
                .transition(.opacity)
            } else if TaskNotes.hasContent(task.notes) {
                previewBlock
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isEditing)
    }

    @ViewBuilder private var previewBlock: some View {
        if let previewMaxHeight {
            ScrollView(.vertical) {
                TaskNotesPreview(notes: task.notes, lineLimit: nil)
                    .padding(.trailing, 4)
            }
            .frame(maxHeight: previewMaxHeight)
        } else {
            TaskNotesPreview(notes: task.notes, lineLimit: previewLineLimit)
        }
    }
}

/// Themed multiline notes editor with placeholder, an explicit Done action,
/// and Escape interception.
///
/// Escape handling matters twice over: in the main panel the native monitor
/// leaves keys to the text system while notes editing is focused, and the
/// pinned panel must never unpin because the user pressed Escape mid-note. The
/// hidden `.cancelAction` button claims Escape first on both surfaces and
/// routes it into a commit-and-close.
struct TaskNotesEditor: View {
    let taskTitle: String
    @Binding var draft: String
    var minimumHeight: CGFloat = 72
    var maximumHeight: CGFloat = 108
    let onCommit: (String) -> Void
    var onEditingFocusChanged: (Bool) -> Void = { _ in }

    @FocusState private var isEditing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didClose = false

    init(
        taskTitle: String,
        draft: Binding<String>,
        minimumHeight: CGFloat = 72,
        maximumHeight: CGFloat = 108,
        onCommit: @escaping (String) -> Void,
        onEditingFocusChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.taskTitle = taskTitle
        _draft = draft
        self.minimumHeight = minimumHeight
        self.maximumHeight = maximumHeight
        self.onCommit = onCommit
        self.onEditingFocusChanged = onEditingFocusChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            editorField

            HStack(spacing: 7) {
                Spacer(minLength: 0)
                Button("Done") {
                    close()
                }
                .buttonStyle(BCTaskButtonStyle(kind: .secondary, compact: true))
                .help("Save the note and close the editor")
                .accessibilityLabel("Save notes for \(taskTitle)")
                .accessibilityHint("Stores the note text and closes the editor.")
            }
        }
        .background { escapeIntercept }
        .onAppear {
            // Re-arm the commit funnel: an editor can be removed and re-added
            // within one animation window (Kanban lane moves re-insert this
            // exact editor), and a stale `didClose` would swallow the commit.
            didClose = false
            // Opening the editor is an explicit intent to type: claim keyboard
            // focus and tell the router, without waiting for AppKit's own
            // first-responder timing.
            isEditing = true
        }
        .onChange(of: isEditing) { isFocused in
            onEditingFocusChanged(isFocused)
        }
    }

    private var editorField: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(BCTaskTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($isEditing)
                .accessibilityLabel("Task notes for \(taskTitle), editable")
                .accessibilityHint("Type a description or paste links. Press Escape or Done to save and close.")

            if TaskNotes.trimmed(draft).isEmpty {
                Text("Add a note or paste a link…")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(BCTaskTheme.textTertiary)
                    .padding(.leading, 9)
                    .padding(.top, 9)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: minimumHeight, maxHeight: maximumHeight, alignment: .topLeading)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BCTaskTheme.canvas.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isEditing ? BCTaskTheme.accent.opacity(0.68) : BCTaskTheme.hairlineStrong,
                    lineWidth: 1
                )
        }
        .shadow(color: BCTaskTheme.accent.opacity(isEditing ? 0.08 : 0), radius: 12)
    }

    /// Zero-impact Cancel button: registers Escape through the responder chain
    /// so it is claimed here instead of reaching the panel's close/hide path.
    private var escapeIntercept: some View {
        Button(action: { close() }) {
            Text("Close notes")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Single commit funnel for every close path (Done, Escape, cluster
    /// toggle). The surface owns persistence and collapse.
    private func close() {
        guard !didClose else { return }
        didClose = true
        let pending = draft
        isEditing = false
        onEditingFocusChanged(false)
        onCommit(pending)
    }
}
