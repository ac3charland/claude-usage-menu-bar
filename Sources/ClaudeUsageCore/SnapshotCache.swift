import Foundation

public enum SnapshotCache {
    public static var fileURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("claude-usage-menu-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("usage-backup.json", isDirectory: false)
    }

    public static func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(UsageSnapshot.self, from: data)
    }

    public static func save(_ snapshot: UsageSnapshot) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(snapshot) else { return }
        // The Codable surface explicitly excludes any token field; this is belt-and-braces.
        let raw = String(data: data, encoding: .utf8) ?? ""
        let scrubbed = Log.redact(raw)
        try? scrubbed.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }
}
