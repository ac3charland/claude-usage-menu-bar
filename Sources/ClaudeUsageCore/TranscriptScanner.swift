import Foundation

/// Per-model totals for one weekly window, extracted from Claude Code's local transcripts.
/// Every field is a number or a model ID: no transcript content is ever modelled (spec §7).
public struct ModelUsage: Codable, Equatable {
    public var input: Int = 0
    public var cacheWrite5m: Int = 0
    public var cacheWrite1h: Int = 0
    public var cacheRead: Int = 0
    public var output: Int = 0
    public var webSearch: Int = 0
    public var requests: Int = 0
    /// Informational only (logs and debugging): the estimator reprices from the token counts.
    public var cost: Double = 0
    /// Requests that had no known price when this record was built.
    public var unpriced: Int = 0

    public init(tokens: TokenCounts = .zero, requests: Int = 0, cost: Double = 0, unpriced: Int = 0) {
        input = tokens.input
        cacheWrite5m = tokens.cacheWrite5m
        cacheWrite1h = tokens.cacheWrite1h
        cacheRead = tokens.cacheRead
        output = tokens.output
        webSearch = tokens.webSearch
        self.requests = requests
        self.cost = cost
        self.unpriced = unpriced
    }

    public var tokens: TokenCounts {
        TokenCounts(input: input, cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h,
                    cacheRead: cacheRead, output: output, webSearch: webSearch)
    }
}

public struct WindowUsage: Equatable {
    /// Keyed by model ID as written in the transcript; fast-mode rows go under `<model>/fast`.
    public var models: [String: ModelUsage]

    public init(models: [String: ModelUsage] = [:]) { self.models = models }

    public var cost: Double { models.values.reduce(0) { $0 + $1.cost } }
    public var requests: Int { models.values.reduce(0) { $0 + $1.requests } }
    public var unpriced: Int { models.values.reduce(0) { $0 + $1.unpriced } }
}

/// Walks `~/.claude/projects/**/*.jsonl` incrementally and totals the token usage of every API
/// request inside the current weekly window (spec §6.3). Runs off the main actor. Never throws
/// into the poll path: a missing or unreadable root returns `nil` and logs one warning.
public actor TranscriptScanner {
    public static let fastMultiplier = 2.0

    /// `$CLAUDE_CONFIG_DIR/projects` if set, otherwise `~/.claude/projects`.
    public static var defaultRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    private let root: URL

    private struct FileState {
        var inode: UInt64
        var offset: Int
        var mtime: Date
    }

    private struct RequestUsage {
        var timestamp: Date
        var model: String
        var tokens: TokenCounts
    }

    private var windowKey: Date?
    private var files: [String: FileState] = [:]
    private var requests: [String: RequestUsage] = [:]
    private var warnedMissingRoot = false

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
    }

    // MARK: - Minimal row model (no content fields, by construction)

    private struct Row: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let sessionId: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let outputTokens: Int?
            let cacheCreation: CacheCreation?
            let serverToolUse: ServerToolUse?
            let speed: String?

            struct CacheCreation: Decodable {
                let ephemeral5m: Int?
                let ephemeral1h: Int?
                enum CodingKeys: String, CodingKey {
                    case ephemeral5m = "ephemeral_5m_input_tokens"
                    case ephemeral1h = "ephemeral_1h_input_tokens"
                }
            }

            struct ServerToolUse: Decodable {
                let webSearchRequests: Int?
                enum CodingKeys: String, CodingKey { case webSearchRequests = "web_search_requests" }
            }

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreation = "cache_creation"
                case serverToolUse = "server_tool_use"
                case speed
            }
        }
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseTimestamp(_ s: String) -> Date? {
        fractionalFormatter.date(from: s) ?? plainFormatter.date(from: s)
    }

    /// Cheap substring prefilter run before JSON decoding. Deliberately loose: it must never
    /// reject a valid assistant row, so it only requires the two words every such row carries.
    static func mightBeAssistantUsageRow(_ line: String) -> Bool {
        line.contains("assistant") && line.contains("usage")
    }

    // MARK: - Scan

    /// Totals for all requests with `windowStart ≤ timestamp ≤ upTo`, priced at the rates in
    /// effect at each request's time. `nil` when the transcript root is missing or unreadable.
    public func usage(since windowStart: Date, upTo: Date, prices: PriceHistory) -> WindowUsage? {
        let started = Date()
        if windowKey != windowStart {
            windowKey = windowStart
            files = [:]
            requests = [:]
        }
        let cold = files.isEmpty

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else {
            if !warnedMissingRoot {
                Log.warn("Transcript root missing or unreadable: \(root.path) — budget line will stay hidden")
                warnedMissingRoot = true
            }
            return nil
        }

        var scannedFiles = 0
        var scannedLines = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.intValue,
                  let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { continue }
            // Skip files last modified before the window began: nothing inside can be in it.
            if mtime < windowStart { continue }

            // Resume from the saved offset only for the same inode that has grown or is untouched;
            // a shrunk or replaced file, or one rewritten to the same size, is re-read from 0 (the
            // dedup map makes that idempotent).
            var offset = 0
            if let st = files[url.path], st.inode == inode, size > st.offset || (size == st.offset && mtime == st.mtime) {
                offset = st.offset
            }
            guard size > offset else {
                files[url.path] = FileState(inode: inode, offset: offset, mtime: mtime)
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.readToEnd() else { continue }

            // Read up to the last complete newline; a partial trailing line waits for next scan.
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                files[url.path] = FileState(inode: inode, offset: offset, mtime: mtime)
                continue
            }
            let complete = data[data.startIndex...lastNewline]
            let consumed = complete.count
            scannedFiles += 1
            var lineStart = complete.startIndex
            while lineStart < complete.endIndex {
                let lineEnd = complete[lineStart...].firstIndex(of: 0x0A) ?? complete.endIndex
                let lineData = complete[lineStart..<lineEnd]
                lineStart = complete.index(after: lineEnd)
                guard !lineData.isEmpty else { continue }
                scannedLines += 1
                ingest(lineData, windowStart: windowStart)
            }
            files[url.path] = FileState(inode: inode, offset: offset + consumed, mtime: mtime)
        }

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        if cold || elapsedMs > 250 {
            Log.info("Transcript scan (\(cold ? "cold" : "incremental")): \(scannedFiles) files, \(scannedLines) lines, \(requests.count) requests in window, \(elapsedMs) ms")
        }
        return totals(upTo: upTo, prices: prices)
    }

    private static let decoder = JSONDecoder()

    private func ingest(_ lineData: Data.SubSequence, windowStart: Date) {
        guard let line = String(data: lineData, encoding: .utf8),
              Self.mightBeAssistantUsageRow(line),
              let row = try? Self.decoder.decode(Row.self, from: lineData),
              row.type == "assistant",
              let message = row.message, let usage = message.usage,
              let messageID = message.id,
              let model = message.model, model != "<synthetic>",
              let tsString = row.timestamp, let ts = Self.parseTimestamp(tsString),
              ts >= windowStart else { return }

        // Cache-write split: prefer the 5m/1h breakdown; otherwise treat the flat count as 5m.
        let cw5m: Int
        let cw1h: Int
        if let cc = usage.cacheCreation, cc.ephemeral5m != nil || cc.ephemeral1h != nil {
            cw5m = cc.ephemeral5m ?? 0
            cw1h = cc.ephemeral1h ?? 0
        } else {
            cw5m = usage.cacheCreationInputTokens ?? 0
            cw1h = 0
        }
        let tokens = TokenCounts(input: usage.inputTokens ?? 0, cacheWrite5m: cw5m, cacheWrite1h: cw1h,
                                 cacheRead: usage.cacheReadInputTokens ?? 0, output: usage.outputTokens ?? 0,
                                 webSearch: usage.serverToolUse?.webSearchRequests ?? 0)
        let modelKey = usage.speed == "fast" ? "\(model)/fast" : model

        // Dedup (CLU-3 §4): message.id + requestId, else sessionId + message.id. Per-field max.
        let key: String
        if let req = row.requestId, !req.isEmpty {
            key = "\(messageID)|\(req)"
        } else {
            key = "s:\(row.sessionId ?? "")|\(messageID)"
        }
        if var existing = requests[key] {
            existing.tokens = existing.tokens.merged(max: tokens)
            existing.timestamp = min(existing.timestamp, ts)
            requests[key] = existing
        } else {
            requests[key] = RequestUsage(timestamp: ts, model: modelKey, tokens: tokens)
        }
    }

    private func totals(upTo: Date, prices: PriceHistory) -> WindowUsage {
        var models: [String: ModelUsage] = [:]
        for r in requests.values where r.timestamp <= upTo {
            var m = models[r.model] ?? ModelUsage()
            let sum = m.tokens + r.tokens
            m.input = sum.input
            m.cacheWrite5m = sum.cacheWrite5m
            m.cacheWrite1h = sum.cacheWrite1h
            m.cacheRead = sum.cacheRead
            m.output = sum.output
            m.webSearch = sum.webSearch
            m.requests += 1
            if let rates = prices.rates(r.model, at: r.timestamp) {
                let c = PriceHistory.cost(r.tokens, rates)
                m.cost += r.model.hasSuffix("/fast") ? c * Self.fastMultiplier : c
            } else {
                m.unpriced += 1
            }
            models[r.model] = m
        }
        return WindowUsage(models: models)
    }
}
