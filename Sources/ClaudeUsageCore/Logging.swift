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
