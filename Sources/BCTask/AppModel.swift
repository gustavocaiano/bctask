import Foundation
import Combine
import BCTaskCore

/// Main-actor application model bridging the pure `TaskStore` domain to the
/// SwiftUI shell. Tightly bounded to persistence/lifecycle seams; Phase 3
/// owns any further wiring here (periodic sweeps, panel lifecycle).
///
/// Persistence safety model (Gate 1 remediation):
/// - Mutations are disk-first: a candidate is derived from the last accepted
///   state, saved, and only published to the UI on save success. A failed
///   save leaves the displayed store and the on-disk document at the last
///   accepted state, and records an error message.
/// - A load failure (unreadable, unsupported, or corrupt document) enters a
///   read-only "storage locked" state: the displayed data stays at the last
///   accepted snapshot, mutations are refused, and only a successful reload
///   re-enables them. Unreadable bytes are never overwritten.
/// - Stale errors are cleared only by successful loads or saves.
/// - Every operation captures one `now`; the overdue catch-up sweep uses it,
///   is persisted and published first, and only then does the command apply.
///   A command selecting a task that the catch-up just archived is rejected —
///   restoration is the only mutating path for archived tasks.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var store: TaskStore
    /// Non-nil while storage is locked: either standard resolution/initial
    /// load failed, or a later reload failed. Mutations are refused while set.
    @Published private(set) var storageError: String?
    /// Last single-operation failure message. Cleared only by a successful
    /// load or save.
    @Published private(set) var lastErrorMessage: String?
    /// Phase 3 seam: tasks archived by in-process sweeps whose panels must be
    /// closed. Consume and clear via `consumeArchivedPanelClosures()`.
    @Published private(set) var archivedPanelClosures: [UUID] = []

    private var fileStore: TaskFileStore?
    /// Resolver for the storage location. Retained so `reload()` can retry
    /// resolution when startup could not resolve any store (e.g. Application
    /// Support was temporarily unavailable).
    private let resolveStorage: () throws -> TaskFileStore
    /// Last state known to exist on disk; the base of every candidate.
    private var acceptedStore: TaskStore?
    private let now: () -> Date

    init(
        now: @escaping () -> Date = Date.init,
        storage resolveStorage: @escaping () throws -> TaskFileStore = { try TaskFileStore.standard(fileManager: .default) }
    ) {
        self.now = now
        self.resolveStorage = resolveStorage
        self.store = TaskStore()
        do {
            let fileStore = try resolveStorage()
            // Resolution succeeded: remember the store even if the document
            // turns out to be corrupt/unreadable, so Reload can retry the
            // load (e.g. after the file is externally repaired) without
            // re-resolving and without ever overwriting the bad bytes.
            self.fileStore = fileStore
            let loaded = try fileStore.load(now: now())
            self.acceptedStore = loaded
            self.store = loaded
        } catch {
            self.acceptedStore = nil
            self.storageError = "Task storage is unavailable; actions are locked: \(error)"
        }
    }

    var canMutate: Bool { storageError == nil }

    var activeTasks: [TaskItem] { store.activeTasks }
    var archivedTasks: [TaskItem] { store.archivedTasks }

    /// Statuses a task may move to next, from the store's transition table.
    func availableTargets(for task: TaskItem) -> [TaskStatus] {
        TaskStore.allowedTransitions[task.status]?.sorted { $0.rawValue < $1.rawValue } ?? []
    }

    func add(_ rawTitle: String) {
        mutate { store, at in try store.addTask(title: rawTitle, now: at) }
    }

    func setStatus(_ task: TaskItem, to newStatus: TaskStatus) {
        mutate { store, at in try store.setStatus(id: task.id, to: newStatus, now: at) }
    }

    func setPinned(_ task: TaskItem, _ pinned: Bool) {
        mutate { store, at in try store.setPinned(pinned, for: task.id, now: at) }
    }

    /// Replaces a live task's free-form notes (description, links). The editor
    /// commits once on close and never per keystroke; unchanged notes are a
    /// domain no-op, so they never write to disk (see `mutate`).
    ///
    /// `baseline` is the notes the calling editor read when it seeded its
    /// draft; a store that has since moved to different notes (a concurrent
    /// editor — the pinned card and the main surface can both edit one
    /// task) rejects the commit instead of silently overwriting it.
    ///
    /// Returns false when the commit was refused (storage locked, task
    /// missing or archived, notes conflict) or the disk-first save failed,
    /// so callers can keep the user's draft mounted for retry instead of
    /// dropping it. Unchanged notes count as committed: the accepted store
    /// already carries them (the `mutate` no-op path leaves `store`
    /// matching).
    @discardableResult
    func setNotes(_ task: TaskItem, from baseline: String, to notes: String) -> Bool {
        mutate { store, at in
            try store.updateNotes(id: task.id, from: baseline, to: notes, now: at)
        }
        guard let updated = store.tasks.first(where: { $0.id == task.id }) else {
            return false
        }
        return updated.notes == notes
    }

    /// Permanently deletes a task (live or archived). Immediate; no archive step.
    func delete(_ task: TaskItem) {
        mutate { store, _ in try store.deleteTask(id: task.id) }
    }

    /// Restores an archived task to Todo. Archived tasks reject normal
    /// transitions; restoration is the only mutating path for them.
    func restore(_ task: TaskItem) {
        mutate { store, at in try store.restoreArchivedTask(id: task.id, now: at) }
    }

    /// Re-loads from disk and runs the catch-up sweep (activation/relaunch flow).
    ///
    /// This is also the recovery path for a locked state: it retries storage
    /// resolution when no store was resolved yet, then loads. A successful
    /// reload populates the accepted/displayed state, unlocks mutation, and
    /// clears stale errors. Any failure keeps the last accepted snapshot on
    /// screen and the lock in place; unreadable bytes are never overwritten.
    func reload() {
        do {
            let fileStore = try resolveStorageIfNeeded()
            self.fileStore = fileStore // a resolver that just worked is remembered
            let loaded = try fileStore.load(now: now())
            acceptedStore = loaded
            store = loaded
            storageError = nil // successful load is the only recovery path
            lastErrorMessage = nil // clear stale errors on success
        } catch {
            // Keep the last accepted snapshot on screen, block mutation, and
            // never risk overwriting unreadable bytes with new saves.
            storageError = "Tasks failed to load; actions are locked: \(error)"
        }
    }

    /// Returns the already-resolved store, or retries resolution when none
    /// was resolved (startup storage-unavailable case).
    private func resolveStorageIfNeeded() throws -> TaskFileStore {
        if let fileStore { return fileStore }
        return try resolveStorage()
    }

    /// Phase 3 seam: sweeps overdue tasks, persists the result if anything
    /// archived, and returns the IDs archived by this call (empty means no
    /// write happened, so periodic calls stay no-op and quiet). Intended to
    /// be paired with `consumeArchivedPanelClosures()` when panels exist.
    @discardableResult
    func sweepAndPersist() -> [UUID] {
        guard let fileStore, canMutate, let accepted = acceptedStore else { return [] }
        var candidate = accepted
        let archivedIDs = candidate.sweep(now: now())
        guard !archivedIDs.isEmpty else { return [] }
        do {
            try fileStore.save(candidate)
            acceptedStore = candidate
            store = candidate
            archivedPanelClosures.append(contentsOf: archivedIDs)
            storageError = nil
            lastErrorMessage = nil
            return archivedIDs
        } catch {
            lastErrorMessage = "Could not save tasks: \(error)"
            return []
        }
    }

    /// Returns and clears the queued panel-closure requests (Phase 3 seam).
    func consumeArchivedPanelClosures() -> [UUID] {
        let pending = archivedPanelClosures
        archivedPanelClosures = []
        return pending
    }

    private func mutate(_ command: (inout TaskStore, Date) throws -> Void) {
        guard let fileStore, canMutate, let accepted = acceptedStore else {
            lastErrorMessage = storageError ?? "Task storage is unavailable."
            return
        }
        // One captured timestamp drives the whole operation: the catch-up
        // sweep and the command observe the same instant.
        let stamp = now()
        do {
            var base = accepted
            let caught = base.sweep(now: stamp)
            if !caught.isEmpty {
                // Persist and publish the catch-up first so the command sees
                // archival reality at the inclusive deadline.
                try fileStore.save(base)
                acceptedStore = base
                store = base
                archivedPanelClosures.append(contentsOf: caught)
            }
            var candidate = base
            try command(&candidate, stamp)
            guard candidate != base else { return } // no-op command: no write
            try fileStore.save(candidate)
            acceptedStore = candidate
            store = candidate
            storageError = nil
            lastErrorMessage = nil
        } catch {
            // Domain rejections and save failures both leave the displayed
            // store and the disk at the last accepted state.
            if error is TaskStoreError {
                lastErrorMessage = "Task action rejected: \(error)"
            } else {
                lastErrorMessage = "Could not save tasks: \(error)"
            }
        }
    }
}
