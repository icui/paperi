import Foundation
import PaperiCore

/// Disk format remains compatible with existing restore.json files.
struct RestoreEntry: Codable {
    let windowID: UInt32
    let pid: Int32
    let frame: [Double]

    var rect: Rect? {
        guard windowID > 0, pid > 0, frame.count == 4 else { return nil }
        let value = Rect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
        return value.isValid ? value : nil
    }
}

enum RestoreOutcome {
    case restored, adjusted(String), gone, failed(String)
}

enum LiveRestoration {
    /// Keep only failures; vanished windows are not retry candidates.
    static func run(entries: [RestoreEntry], url: URL,
                    perform: (RestoreEntry, Rect) -> RestoreOutcome) -> [String: Any] {
        let validated = entries.compactMap { entry in entry.rect.map { (entry, $0) } }
        guard validated.count == entries.count else {
            return ["restored": 0, "restoreFailed": 0, "journal": "invalid", "error": "Invalid recovery entry"]
        }
        var pending: [RestoreEntry] = []
        var failures: [[String: Any]] = []
        var restored = 0, gone = 0
        var adjustments: [[String: Any]] = []
        for (entry, rect) in validated {
            switch perform(entry, rect) {
            case .restored: restored += 1
            case .adjusted(let reason):
                restored += 1
                adjustments.append(["windowID": entry.windowID, "reason": reason])
            case .gone: gone += 1
            case .failed(let reason):
                pending.append(entry)
                failures.append(["windowID": entry.windowID, "reason": reason])
            }
        }
        var result: [String: Any] = ["restored": restored, "restoreFailed": pending.count,
                                    "gone": gone, "failures": failures, "adjustments": adjustments]
        do {
            if pending.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                result["journal"] = "removed"
            } else {
                try JSONEncoder().encode(pending).write(to: url, options: .atomic)
                result["journal"] = "retained"
            }
        } catch {
            FileHandle.standardError.write(Data("[paperi] Could not update recovery journal; previously restored entries may be retried: \(error)\n".utf8))
            result["journal"] = "persistenceFailed"
            result["error"] = String(describing: error)
        }
        return result
    }
}
