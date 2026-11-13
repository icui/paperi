import Foundation
import Testing
import PaperiCore
@testable import PaperiPlatform

struct LiveRestorationTests {
    func entry(_ id: UInt32) -> RestoreEntry {
        RestoreEntry(windowID: id, pid: 42, frame: [10, 20, 400, 300])
    }

    @Test func retainsOnlyRetryableFailuresAndRemovesAfterSuccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("restore.json")
        let entries = [entry(1), entry(2), entry(3)]
        try JSONEncoder().encode(entries).write(to: url)
        let result = LiveRestoration.run(entries: entries, url: url) { entry, _ in
            switch entry.windowID {
            case 1: return .restored
            case 2: return .gone
            default: return .failed("AX timeout")
            }
        }
        #expect(result["restored"] as? Int == 1)
        #expect(result["gone"] as? Int == 1)
        #expect(result["restoreFailed"] as? Int == 1)
        let remaining = try JSONDecoder().decode([RestoreEntry].self, from: Data(contentsOf: url))
        #expect(remaining.map(\.windowID) == [3])
        let retry = LiveRestoration.run(entries: remaining, url: url) { _, _ in .restored }
        #expect(retry["journal"] as? String == "removed")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func invalidEntryPreventsAllEffects() {
        let entries = [entry(1), RestoreEntry(windowID: 2, pid: 42, frame: [])]
        var calls = 0
        let result = LiveRestoration.run(entries: entries, url: URL(fileURLWithPath: "/unused")) { _, _ in
            calls += 1
            return .restored
        }
        #expect(calls == 0)
        #expect(result["journal"] as? String == "invalid")
    }

    @MainActor @Test func corruptJournalIsPreserved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("invalid json".utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = LiveManager.restore(journalURL: url)
        #expect(result["journal"] as? String == "unreadable")
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test func adjustedGeometryCompletesRecovery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode([entry(1)]).write(to: url)
        let result = LiveRestoration.run(entries: [entry(1)], url: url) { _, _ in
            .adjusted("App rounded size to text grid")
        }
        #expect(result["restored"] as? Int == 1)
        #expect(result["restoreFailed"] as? Int == 0)
        #expect((result["adjustments"] as? [[String: Any]])?.count == 1)
        #expect(result["journal"] as? String == "removed")
    }

    @Test func failedJournalWriteIsReported() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing/restore.json")
        let result = LiveRestoration.run(entries: [entry(1)], url: url) { _, _ in .failed("AX timeout") }
        #expect(result["journal"] as? String == "persistenceFailed")
        #expect(result["restoreFailed"] as? Int == 1)
        #expect(result["error"] as? String != nil)
    }

    @MainActor @Test func productionJournalRoundTripsAndReadsLegacyFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("restore.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = LiveManager(options: .init(journalURL: url))
        manager.remember(1, pid: 42, frame: Rect(x: 10, y: 20, width: 400, height: 300))
        let entries = try JSONDecoder().decode([RestoreEntry].self, from: Data(contentsOf: url))
        #expect(entries.count == 1)
        #expect(entries[0].rect == entry(1).rect)
        let legacy = try JSONSerialization.data(withJSONObject: [
            ["windowID": 1, "pid": 42, "frame": [10, 20, 400, 300]]
        ])
        let decoded = try JSONDecoder().decode([RestoreEntry].self, from: legacy)
        #expect(decoded[0].rect == entries[0].rect)
    }

}
