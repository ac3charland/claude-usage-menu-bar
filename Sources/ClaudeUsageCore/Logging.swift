import Foundation

public enum Log {
    public enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    public static func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
    public static func warn(_ message: @autoclosure () -> String) { emit(.warn, message()) }
    public static func error(_ message: @autoclosure () -> String) { emit(.error, message()) }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")   // make the trailing 'Z' truthful
        return f
    }()

    private static func emit(_ level: Level, _ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) \(level.rawValue) \(redact(message))\n"
        // Write straight to stdout and flush. `print` block-buffers when stdout is a
        // pipe/file (not a TTY), which would withhold a long-running daemon's logs.
        FileHandle.standardOutput.write(Data(line.utf8))
        // Mirror to a file: stdout is lost when launched from a `.app`/LaunchAgent.
        appendToFile(line)
    }

    // MARK: - File sink

    /// Path to the on-disk log. Lives next to the snapshot cache so all local state
    /// is in one place. Safe to delete; it is recreated on the next log line.
    public static var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("claude-usage-menu-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("claude-usage.log", isDirectory: false)
    }

    /// Rotate once the live file passes this size; we keep the current file plus one
    /// previous (`claude-usage.1.log`), bounding disk use at ~2× this.
    private static let maxFileBytes: UInt64 = 1_000_000

    /// Serializes appends so lines from different threads (engine, URLSession, CLI ping)
    /// don't interleave or race on the file handle.
    private static let fileQueue = DispatchQueue(label: "com.claude-usage.log-file")

    private static func appendToFile(_ line: String) {
        let data = Data(line.utf8)
        fileQueue.async {
            let fm = FileManager.default
            let url = fileURL

            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? UInt64,
               size > maxFileBytes {
                let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: url, to: rotated)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Removes bearer tokens and `sk-ant-…` API keys from arbitrary text.
    /// Run on every log line and any persisted blob before it leaves the process.
    public static func redact(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(
            of: #"(?i)Bearer\s+[A-Za-z0-9._\-+/=]+"#,
            with: "Bearer <REDACTED>",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"sk-ant-[A-Za-z0-9._\-]+"#,
            with: "sk-ant-<REDACTED>",
            options: .regularExpression
        )
        return out
    }
}
