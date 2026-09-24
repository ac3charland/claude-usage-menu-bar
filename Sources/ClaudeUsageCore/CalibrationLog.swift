import Foundation

/// One calibration observation: the poll's utilization and surface shares, joined to the
/// cumulative local token usage since the window began (spec §6.4, record v1). Every value is
/// a number, a model ID, a surface key, or a timestamp — nothing else is possible by
/// construction.
public struct CalibrationRecord: Codable, Equatable {
    public var v: Int = 1
    public let capturedAt: Date
    /// "app" or "daemon": the estimator evaluates one writer's series per window (§4.2).
    public let writer: String
    /// `seven_day.resets_at − 7d`, rounded to the nearest minute: the window key.
    public let windowStart: Date
    public let weeklyPct: Int
    /// `seven_day_breakdown` rows keyed by surface, in percent. `nil` when absent.
    public let surfaceShares: [String: Double]?
    /// Per-model weekly caps (e.g. Fable) by display name, for later analysis.
    public let scopedPct: [String: Double]
    /// Cumulative token usage since `windowStart`, per model ID (`<model>/fast` for fast mode).
    public let usage: [String: ModelUsage]

    public init(capturedAt: Date, writer: String, windowStart: Date, weeklyPct: Int,
                surfaceShares: [String: Double]?, scopedPct: [String: Double] = [:],
                usage: [String: ModelUsage]) {
        self.capturedAt = capturedAt
        self.writer = writer
        self.windowStart = windowStart
        self.weeklyPct = weeklyPct
        self.surfaceShares = surfaceShares
        self.scopedPct = scopedPct
        self.usage = usage
    }

    /// Claude Code's share of the window's usage as a fraction (0–1), if reported.
    public var claudeCodeShare: Double? {
        surfaceShares?["claude_code"].map { $0 / 100 }
    }

    /// Round a window start to the nearest minute: `resets_at` jitters by fractions of a
    /// second between fields and polls (§4.1).
    public static func windowKey(resetsAt: Date) -> Date {
        let start = resetsAt.addingTimeInterval(-UsageSnapshot.weeklyWindowSec)
        return Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 60).rounded() * 60)
    }
}

/// One line of `calibration/readings.jsonl`: the estimator's reading whether or not the line was
/// shown, so the thresholds can be tuned from evidence (§6.4).
public struct ShadowReading: Codable, Equatable {
    public var evaluatedAt: Date
    public var windowStart: Date
    public var spanLower: Double?
    public var spanUpper: Double?
    public var kThis: Double?
    public var kLast: Double?
    public var ratio: Double?
    public var ratioEqualPrices: Double?
    public var ratioNonRead: Double?
    public var ratioAtMinus10: Double?
    public var ccPointsThis: Double?
    public var ccPointsLast: Double?
    public var localDollarsThis: Double?
    public var localDollarsLast: Double?
    public var readShareThis: Double?
    public var readShareLast: Double?
    public var shareThis: Double?
    public var shareLast: Double?
    public var mixTVD: Double?
    public var ticksThis: Int?
    public var ticksLast: Int?
    public var gapShareThis: Double?
    public var gapShareLast: Double?
    public var shown: Bool
    public var hiddenReason: String?

    /// Equal apart from when it was evaluated — "the reading changed" ignores the clock.
    public func sameReading(as other: ShadowReading) -> Bool {
        var a = self, b = other
        a.evaluatedAt = .distantPast
        b.evaluatedAt = .distantPast
        return a == b
    }
}

/// The append-only calibration history: one JSON Lines file per weekly window under
/// `calibration/`, plus `readings.jsonl` for shadow readings. Files are never rotated or pruned.
public final class CalibrationLog {
    public let directory: URL
    /// Write a heartbeat record when this long has passed since the last write.
    public var heartbeatSec: TimeInterval = 30 * 60

    private var lastWritten: CalibrationRecord?
    private var lastObserved: CalibrationRecord?
    private var pending: CalibrationRecord?
    private var loadedWindow: Date?

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("claude-usage-menu-bar", isDirectory: true)
            .appendingPathComponent("calibration", isDirectory: true)
    }

    // MARK: - File naming

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HHmm'Z'"
        return f
    }()

    /// `2026-09-25T1900Z.jsonl` — no colons, so the name is safe everywhere.
    public static func fileName(for windowStart: Date) -> String {
        nameFormatter.string(from: windowStart) + ".jsonl"
    }

    public static func windowStart(fromFileName name: String) -> Date? {
        guard name.hasSuffix(".jsonl") else { return nil }
        return nameFormatter.date(from: String(name.dropLast(6)))
    }

    public func fileURL(for windowStart: Date) -> URL {
        directory.appendingPathComponent(Self.fileName(for: windowStart))
    }

    public var readingsURL: URL { directory.appendingPathComponent("readings.jsonl") }

    // MARK: - Codec

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Reading

    /// Every window start that has a file, ascending.
    public func recordedWindows() -> [Date] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap(Self.windowStart(fromFileName:)).sorted()
    }

    /// All records of one window, in file order. Undecodable lines (e.g. a partial last line
    /// after a crash) are skipped.
    public func records(windowStart: Date) -> [CalibrationRecord] {
        Self.readLines(CalibrationRecord.self, from: fileURL(for: windowStart))
    }

    static func readLines<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let dec = decoder()
        return text.split(separator: "\n").compactMap { line in
            line.isEmpty ? nil : try? dec.decode(T.self, from: Data(line.utf8))
        }
    }

    /// The current window (the newest whose `windowStart + 7d` is later than `now`) and the
    /// window that reset into it, if recorded back to back (within `tolerance`).
    public func currentAndPrevious(now: Date, tolerance: TimeInterval = 3600) -> (current: Date?, previous: Date?) {
        let windows = recordedWindows()
        guard let current = windows.last(where: { $0.addingTimeInterval(UsageSnapshot.weeklyWindowSec) > now }) else {
            return (nil, nil)
        }
        let previous = windows.first { w in
            w < current && abs(w.addingTimeInterval(UsageSnapshot.weeklyWindowSec).timeIntervalSince(current)) <= tolerance
        }
        return (current, previous)
    }

    // MARK: - Writing

    /// Apply the write policy (§6.4) to a new observation. Returns whether anything was written.
    ///
    /// The estimator needs the poll before and the poll at each utilization step, not every
    /// poll: the newest unwritten record is held as `pending`; a step or shares change flushes it
    /// and writes the current one; a heartbeat lands every `heartbeatSec` otherwise.
    @discardableResult
    public func observe(_ record: CalibrationRecord) -> Bool {
        // At launch, read the last written record of this window back from disk so the policy
        // continues where the previous run left off.
        if loadedWindow != record.windowStart {
            loadedWindow = record.windowStart
            if lastObserved == nil, let last = records(windowStart: record.windowStart).last {
                lastWritten = last
                lastObserved = last
            }
        }
        defer { lastObserved = record }

        guard let previous = lastObserved else {
            write(record)
            return true
        }
        if record.windowStart != previous.windowStart {
            flushPending()
            write(record)
            return true
        }
        if record.weeklyPct != previous.weeklyPct || record.surfaceShares != previous.surfaceShares {
            flushPending()
            write(record)
            return true
        }
        if let last = lastWritten, record.capturedAt.timeIntervalSince(last.capturedAt) >= heartbeatSec {
            pending = nil
            write(record)
            return true
        }
        if lastWritten == nil {
            write(record)
            return true
        }
        pending = record
        return false
    }

    private func flushPending() {
        if let p = pending {
            write(p)
            pending = nil
        }
    }

    private func write(_ record: CalibrationRecord) {
        pending = nil
        lastWritten = record
        Self.append(record, to: fileURL(for: record.windowStart))
    }

    /// Append a shadow reading line.
    public func appendReading(_ reading: ShadowReading) {
        Self.append(reading, to: readingsURL)
    }

    /// The last shadow reading on disk, so "changed" survives a relaunch.
    public func lastReading() -> ShadowReading? {
        Self.readLines(ShadowReading.self, from: readingsURL).last
    }

    /// Each line is written with a single append, so interleaved writers never split a line.
    private static func append<T: Encodable>(_ value: T, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard var data = try? encoder().encode(value) else { return }
        data.append(0x0A)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
