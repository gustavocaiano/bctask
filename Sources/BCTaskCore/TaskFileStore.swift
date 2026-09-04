import Foundation

/// File-backed persistence for the task store.
///
/// The document lives at `<directory>/tasks.json`, written atomically. The
/// directory is injectable so tests never touch the real Application Support
/// folder; `standard()` resolves the app's real location and THROWS when it
/// cannot be resolved — there is deliberately no temporary-directory fallback,
/// per the no-silent-data-loss policy:
/// - Showing an empty/throwaway store copies nothing and preserves the user's
///   document; a temp-backed store would silently diverge from it.
/// - Resolution failure is therefore surfaced so the app can lock mutations
///   until storage is available again.
public struct TaskFileStore: Sendable {
    public static let fileName = "tasks.json"
    public static let applicationDirectoryName = "BCTask"

    /// Directory containing `tasks.json`.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The real store location: `~/Library/Application Support/BCTask/tasks.json`.
    ///
    /// Resolution failure (e.g. the Application Support domain is unavailable)
    /// propagates; no fallback location is ever substituted.
    public static func standard(fileManager: FileManager = .default) throws -> TaskFileStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return TaskFileStore(
            directory: base.appendingPathComponent(applicationDirectoryName, isDirectory: true)
        )
    }

    public var fileURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Loads the persisted document and applies the catch-up archival sweep
    /// for the given `now`. This is what makes one-hour archival survive
    /// relaunch and sleep: the deadline is derived from the persisted
    /// `completedAt`, never from a live timer. If the sweep archived anything,
    /// the updated document is persisted immediately so archival survives
    /// a crash after reload; if the sweep changes nothing, no write happens.
    ///
    /// A missing file initializes an empty store and persists it, so the very
    /// first launch establishes a valid document. Any other load failure — a
    /// corrupted or unsupported document — propagates and the file remains
    /// untouched so unreadable bytes are never silently overwritten.
    public func load(now: Date) throws -> TaskStore {
        do {
            let data = try Data(contentsOf: fileURL)
            var store = try TaskDocumentCodec.decode(data)
            let newlyArchived = store.sweep(now: now)
            if !newlyArchived.isEmpty {
                try save(store)
            }
            return store
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let fresh = TaskStore()
            try save(fresh)
            return fresh
        }
    }

    /// Atomically writes the store. Creates the directory on demand.
    /// Validation happens inside `TaskDocumentCodec.encode`, before any byte
    /// is written, so an invalid store can never replace a document on disk.
    public func save(_ store: TaskStore) throws {
        let data = try TaskDocumentCodec.encode(store)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
