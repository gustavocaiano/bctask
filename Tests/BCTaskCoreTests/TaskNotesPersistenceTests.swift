import Testing
import Foundation
@testable import BCTaskCore

@Suite("Notes persistence and legacy document compatibility")
struct TaskNotesPersistenceTests {
    private let t0 = Date(timeIntervalSince1970: 3_600_000)

    @Test func legacyDocumentWithoutNotesKeyDecodesAsEmptyNotes() throws {
        let id = UUID()
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "tasks": [
            {
              "id": "\(id.uuidString)",
              "title": "legacy task",
              "status": "todo",
              "createdAt": 3600000,
              "updatedAt": 3600000,
              "isPinned": false
            }
          ]
        }
        """

        let store = try TaskDocumentCodec.decode(Data(legacyJSON.utf8))
        let task = try #require(store.tasks.first)

        #expect(task.id == id)
        #expect(task.title == "legacy task")
        #expect(task.notes == "", "documents persisted before notes existed decode with empty notes")
    }

    @Test func documentWithExplicitEmptyNotesDecodesSymmetrically() throws {
        let id = UUID()
        let json = """
        {
          "schemaVersion": 1,
          "tasks": [
            {
              "id": "\(id.uuidString)",
              "title": "explicit",
              "notes": "",
              "status": "todo",
              "createdAt": 3600000,
              "updatedAt": 3600000,
              "isPinned": false
            }
          ]
        }
        """

        let store = try TaskDocumentCodec.decode(Data(json.utf8))
        #expect(try #require(store.tasks.first).notes == "")
    }

    @Test func notesWithLinksAndNewlinesSurviveRoundTrip() throws {
        var task = TaskItem.make(title: "linked", now: t0)
        task.notes = "See https://example.com/a and mailto:hi@example.com\nsecond line"
        let store = TaskStore(tasks: [task])

        let decoded = try TaskDocumentCodec.decode(try TaskDocumentCodec.encode(store))

        #expect(decoded == store)
        #expect(try #require(decoded.tasks.first).notes == task.notes)
    }

    @Test func encodedDocumentCarriesTheNotesKeyAtSchemaTwo() throws {
        var task = TaskItem.make(title: "task", now: t0)
        task.notes = "detail"
        let data = try TaskDocumentCodec.encode(TaskStore(tasks: [task]))

        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"schemaVersion\":2"), "writes carry the notes-era schema version")
        #expect(json.contains("\"notes\":\"detail\""), "the stable key-sorted format includes notes")
        let decoded = try TaskDocumentCodec.decode(data)
        #expect(try #require(decoded.tasks.first).notes == "detail")
    }

    @Test func interimSchemaOneDocumentsWithNotesStillDecode() throws {
        let id = UUID()
        let json = """
        {
          "schemaVersion": 1,
          "tasks": [
            {
              "id": "\(id.uuidString)",
              "title": "interim",
              "notes": "written by an interim build",
              "status": "todo",
              "createdAt": 3600000,
              "updatedAt": 3600000,
              "isPinned": false
            }
          ]
        }
        """

        let store = try TaskDocumentCodec.decode(Data(json.utf8))
        #expect(
            try #require(store.tasks.first).notes == "written by an interim build",
            "schema-1 files that interim notes builds already wrote keep decoding"
        )
    }

    @Test func legacyDocumentUpgradesToSchemaTwoOnNextSave() throws {
        let id = UUID()
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "tasks": [
            {
              "id": "\(id.uuidString)",
              "title": "legacy task",
              "notes": "kept through the upgrade",
              "status": "todo",
              "createdAt": 3600000,
              "updatedAt": 3600000,
              "isPinned": false
            }
          ]
        }
        """
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskNotesSchemaUpgrade-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = TaskFileStore(directory: root)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(legacyJSON.utf8).write(to: fileStore.fileURL)
        var store = try fileStore.load(now: t0.addingTimeInterval(60))
        #expect(try #require(store.tasks.first).notes == "kept through the upgrade")

        try store.updateNotes(id: id, from: "kept through the upgrade", to: "edited after upgrade", now: t0.addingTimeInterval(120))
        try fileStore.save(store)

        let bytes = try #require(String(data: try Data(contentsOf: fileStore.fileURL), encoding: .utf8))
        #expect(bytes.contains("\"schemaVersion\":2"), "the first save after loading a legacy file rewrites it at schema 2")
        #expect(bytes.contains("edited after upgrade"), "the notes survive the version upgrade")

        let reloaded = try fileStore.load(now: t0.addingTimeInterval(180))
        #expect(try #require(reloaded.tasks.first).notes == "edited after upgrade")
    }

    @Test func notesChangesStillValidateAndRoundTrip() throws {
        var store = TaskStore(tasks: [TaskItem.make(title: "task", now: t0)])
        let id = try #require(store.tasks.first?.id)

        try store.updateNotes(id: id, from: "", to: "https://example.com", now: t0.addingTimeInterval(60))
        try store.updateNotes(id: id, from: "https://example.com", to: "", now: t0.addingTimeInterval(120))

        try TaskDocumentCodec.validate(store.tasks)
        let decoded = try TaskDocumentCodec.decode(try TaskDocumentCodec.encode(store))
        #expect(decoded == store)
        #expect(try #require(decoded.tasks.first).notes == "")
    }

    @Test func notesRoundTripThroughFileStoreSurvivesCatchUpLoad() throws {
        var task = TaskItem.make(title: "filed", now: t0)
        task.notes = "detail with https://example.com/link"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskNotesPersistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = TaskFileStore(directory: root)

        try fileStore.save(TaskStore(tasks: [task]))
        let reloaded = try fileStore.load(now: t0.addingTimeInterval(60))

        #expect(try #require(reloaded.tasks.first).notes == "detail with https://example.com/link")
    }
}
