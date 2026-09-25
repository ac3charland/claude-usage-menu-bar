import Foundation

/// Public API list prices for one model, in dollars per million tokens.
public struct ModelRates: Codable, Equatable {
    public let name: String
    public let input: Double
    public let cacheWrite5m: Double
    public let cacheWrite1h: Double
    public let cacheRead: Double
    public let output: Double

    public init(name: String, input: Double, cacheWrite5m: Double, cacheWrite1h: Double,
                cacheRead: Double, output: Double) {
        self.name = name
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    // Persisted with the short keys the spec lists: {name, in, cw5m, cw1h, read, out}.
    enum CodingKeys: String, CodingKey {
        case name
        case input = "in"
        case cacheWrite5m = "cw5m"
        case cacheWrite1h = "cw1h"
        case cacheRead = "read"
        case output = "out"
    }

    /// Rates are equal when every price matches; the display name is informational.
    public static func == (a: ModelRates, b: ModelRates) -> Bool {
        a.input == b.input && a.cacheWrite5m == b.cacheWrite5m && a.cacheWrite1h == b.cacheWrite1h
            && a.cacheRead == b.cacheRead && a.output == b.output
    }
}

/// Token counts for one model, the unit everything downstream is priced from.
public struct TokenCounts: Codable, Equatable {
    public var input: Int = 0
    public var cacheWrite5m: Int = 0
    public var cacheWrite1h: Int = 0
    public var cacheRead: Int = 0
    public var output: Int = 0
    public var webSearch: Int = 0

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0,
                output: Int = 0, webSearch: Int = 0) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
        self.webSearch = webSearch
    }

    public static let zero = TokenCounts()

    public var isZero: Bool {
        input == 0 && cacheWrite5m == 0 && cacheWrite1h == 0 && cacheRead == 0 && output == 0 && webSearch == 0
    }

    /// Per-field maximum — the dedup policy from CLU-3 §4 (streaming rows only ever grow).
    public func merged(max other: TokenCounts) -> TokenCounts {
        TokenCounts(input: Swift.max(input, other.input),
                    cacheWrite5m: Swift.max(cacheWrite5m, other.cacheWrite5m),
                    cacheWrite1h: Swift.max(cacheWrite1h, other.cacheWrite1h),
                    cacheRead: Swift.max(cacheRead, other.cacheRead),
                    output: Swift.max(output, other.output),
                    webSearch: Swift.max(webSearch, other.webSearch))
    }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
                    cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h, cacheRead: a.cacheRead + b.cacheRead,
                    output: a.output + b.output, webSearch: a.webSearch + b.webSearch)
    }

    /// Increment from `previous` to `self`, floored at zero per field (§4.2: max(0, Δ)).
    public func delta(from previous: TokenCounts) -> TokenCounts {
        TokenCounts(input: Swift.max(0, input - previous.input),
                    cacheWrite5m: Swift.max(0, cacheWrite5m - previous.cacheWrite5m),
                    cacheWrite1h: Swift.max(0, cacheWrite1h - previous.cacheWrite1h),
                    cacheRead: Swift.max(0, cacheRead - previous.cacheRead),
                    output: Swift.max(0, output - previous.output),
                    webSearch: Swift.max(0, webSearch - previous.webSearch))
    }

    /// The same counts with the cache-read class zeroed — for the non-cache-read cost `cnr` (§4.2).
    public var withoutCacheRead: TokenCounts {
        var t = self
        t.cacheRead = 0
        return t
    }
}

/// A dated history of list-price tables. Answers "what did model m cost at time t?" (spec §6.2).
/// Pure value type; persistence lives in `PriceHistoryStore`.
public struct PriceHistory: Equatable {
    public struct Entry: Codable, Equatable {
        public let effectiveFrom: Date
        public let fetchedAt: Date
        public let source: String
        public let rates: [String: ModelRates]

        public init(effectiveFrom: Date, fetchedAt: Date, source: String, rates: [String: ModelRates]) {
            self.effectiveFrom = effectiveFrom
            self.fetchedAt = fetchedAt
            self.source = source
            self.rates = rates
        }
    }

    /// Web search is $10 per 1,000 searches for every model; it is not in the page's table.
    public static let webSearchDollarsPerRequest = 0.01

    /// Entries in ascending `effectiveFrom` order. The built-in table is always entry 0.
    public private(set) var entries: [Entry]
    /// When the pricing page was last fetched and parsed successfully (gates G12). `nil` means
    /// never — only the built-in table has ever been used.
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?

    public init(entries: [Entry] = [PriceHistory.builtInEntry], lastSuccessAt: Date? = nil, lastAttemptAt: Date? = nil) {
        self.entries = entries.sorted { $0.effectiveFrom < $1.effectiveFrom }
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
    }

    /// The built-in fallback table, checked against the live pricing page on 2026-09-24. It is
    /// the implicit first entry with `effectiveFrom` in the distant past.
    public static let builtInRates: [String: ModelRates] = [
        "claude-opus-5-5":  ModelRates(name: "Opus 5.5",  input: 4,  cacheWrite5m: 5,     cacheWrite1h: 8,  cacheRead: 0.20, output: 20),
        "claude-opus-5":    ModelRates(name: "Opus 5",    input: 5,  cacheWrite5m: 6.25,  cacheWrite1h: 10, cacheRead: 0.50, output: 25),
        "claude-fable-5-1": ModelRates(name: "Fable 5.1", input: 10, cacheWrite5m: 12.5,  cacheWrite1h: 20, cacheRead: 0.25, output: 50),
        "claude-fable-5":   ModelRates(name: "Fable 5",   input: 10, cacheWrite5m: 12.5,  cacheWrite1h: 20, cacheRead: 1.00, output: 50),
        "claude-sonnet-5":  ModelRates(name: "Sonnet 5",  input: 2,  cacheWrite5m: 2.5,   cacheWrite1h: 4,  cacheRead: 0.20, output: 10),
        "claude-haiku-4-5": ModelRates(name: "Haiku 4.5", input: 1,  cacheWrite5m: 1.25,  cacheWrite1h: 2,  cacheRead: 0.10, output: 5),
    ]

    public static let builtInEntry = Entry(effectiveFrom: .distantPast, fetchedAt: .distantPast,
                                           source: "built-in", rates: builtInRates)

    public static let builtIn = PriceHistory()

    public var latestEntry: Entry { entries.last ?? Self.builtInEntry }

    /// Every model ID any entry has ever priced.
    public var knownModels: Set<String> {
        entries.reduce(into: Set<String>()) { $0.formUnion($1.rates.keys) }
    }

    /// Strip a trailing `-YYYYMMDD` (transcripts record Haiku as `claude-haiku-4-5-20251001`)
    /// and a `/fast` speed suffix, so lookups hit the page's IDs.
    public static func normalize(_ model: String) -> String {
        var id = model
        if let slash = id.firstIndex(of: "/") { id = String(id[..<slash]) }
        if id.count > 9, id.dropLast(8).hasSuffix("-"),
           id.suffix(8).allSatisfy(\.isNumber) {
            id = String(id.dropLast(9))
        }
        return id
    }

    /// The entry in effect at `t`: the last one whose `effectiveFrom` is not after `t`.
    public func entryIndex(at t: Date) -> Int? {
        var idx: Int?
        for (i, e) in entries.enumerated() where e.effectiveFrom <= t { idx = i }
        return idx
    }

    /// The model's rates from the entry in effect at `t`. If that entry lacks the model, the
    /// earliest later entry that has it (a new model's launch price applies back to its first
    /// use). `nil` when no entry prices it — never a guess.
    public func rates(_ model: String, at t: Date) -> ModelRates? {
        let id = Self.normalize(model)
        guard let start = entryIndex(at: t) ?? (entries.isEmpty ? nil : 0) else { return nil }
        for i in start..<entries.count {
            if let r = entries[i].rates[id] { return r }
        }
        return nil
    }

    /// The model's rates in the latest entry (falling back to the newest entry that has it).
    public func latestRates(_ model: String) -> ModelRates? {
        let id = Self.normalize(model)
        for e in entries.reversed() {
            if let r = e.rates[id] { return r }
        }
        return nil
    }

    /// Whether any of `models` is priced differently between the entry in effect at `t` and the
    /// latest entry. Drives the price note in the tooltip (§3).
    public func priceChanged(models: Set<String>, since t: Date) -> Bool {
        for m in models {
            let then = rates(m, at: t)
            let now = latestRates(m)
            if then != now { return true }
        }
        return false
    }

    /// Dollars for `tokens` at `rates` (per MTok), plus web searches at the flat rate.
    public static func cost(_ tokens: TokenCounts, _ r: ModelRates) -> Double {
        let perTok = 1.0 / 1_000_000
        return Double(tokens.input) * r.input * perTok
            + Double(tokens.cacheWrite5m) * r.cacheWrite5m * perTok
            + Double(tokens.cacheWrite1h) * r.cacheWrite1h * perTok
            + Double(tokens.cacheRead) * r.cacheRead * perTok
            + Double(tokens.output) * r.output * perTok
            + Double(tokens.webSearch) * webSearchDollarsPerRequest
    }

    /// Cost of `tokens` for `model` at the prices in effect at `t`; `nil` when unpriced.
    public func cost(_ tokens: TokenCounts, model: String, at t: Date) -> Double? {
        rates(model, at: t).map { Self.cost(tokens, $0) }
    }

    /// Append a fetched table as a new dated entry — only when its rates differ from the latest
    /// entry. Returns whether an entry was appended. A model missing from the fetch keeps its
    /// last known rates (models are never dropped from the history).
    @discardableResult
    public mutating func append(rates fetched: [String: ModelRates], fetchedAt: Date, source: String) -> Bool {
        var merged = latestEntry.rates
        for (id, r) in fetched { merged[id] = r }
        if merged == latestEntry.rates, entries.count > 0 {
            // Identical prices: nothing to record (names may still have refreshed; ignore).
            return false
        }
        entries.append(Entry(effectiveFrom: fetchedAt, fetchedAt: fetchedAt, source: source, rates: merged))
        return true
    }
}

// MARK: - Pricing page parser

public enum PricingPageParseError: Error, Equatable, CustomStringConvertible {
    case headerNotFound
    case tooFewRows(Int)
    case malformedPrice(model: String, cell: String)
    case orderingViolation(model: String)
    case tooManyKnownModelsMissing(missing: Int, known: Int)

    public var description: String {
        switch self {
        case .headerNotFound: return "model table header not found"
        case .tooFewRows(let n): return "only \(n) model rows parsed"
        case .malformedPrice(let m, let c): return "malformed price for \(m): \(c)"
        case .orderingViolation(let m): return "price ordering violated for \(m)"
        case .tooManyKnownModelsMissing(let missing, let known): return "\(missing) of \(known) known models missing"
        }
    }
}

/// Parses the model table out of Anthropic's pricing page served as markdown (spec §6.2).
public enum PricingPageParser {
    static let headerColumns = ["Model", "Base input tokens", "5m cache writes", "1h cache writes",
                                "Cache hits and refreshes", "Output tokens"]

    /// Derive the ID from the display name: lowercase, spaces and dots → hyphens.
    /// "Claude Opus 5.5" → "claude-opus-5-5".
    public static func modelID(fromName name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Strip markdown links, parentheticals such as "(retired, …)", and `<sup>…</sup>` markers.
    static func cleanModelCell(_ cell: String) -> String {
        var s = cell
        s = s.replacingOccurrences(of: #"<sup>.*?</sup>"#, with: "", options: .regularExpression)
        // Links first: "[text](url)" → "text", so a URL's parentheses never confuse the next step.
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A price cell must match `$<decimal> / MTok` once footnote markers are removed.
    static func parsePrice(_ cell: String) -> Double? {
        let s = cell.replacingOccurrences(of: #"<sup>.*?</sup>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let re = try? NSRegularExpression(pattern: #"^\$([0-9]+(?:\.[0-9]+)?)\s*/\s*MTok$"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Double(s[r])
    }

    /// Parse the page. `known` is the set of model IDs already in the history; the fetch is
    /// rejected if more than half of them are missing from the table.
    public static func parse(markdown: String, known: Set<String> = []) throws -> [String: ModelRates] {
        let lines = markdown.components(separatedBy: .newlines)
        guard let headerIdx = lines.firstIndex(where: { isHeader($0) }) else {
            throw PricingPageParseError.headerNotFound
        }
        var rates: [String: ModelRates] = [:]
        var rowCount = 0
        var i = headerIdx + 1
        // Skip the alignment row (| :--- | ...).
        if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|"),
           lines[i].contains("---") { i += 1 }
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { break }
            i += 1
            let cells = splitRow(line)
            guard cells.count >= 6 else { break }
            let name = cleanModelCell(cells[0])
            guard !name.isEmpty else { continue }
            var prices: [Double] = []
            for c in cells[1...5] {
                guard let p = parsePrice(c) else {
                    throw PricingPageParseError.malformedPrice(model: name, cell: c.trimmingCharacters(in: .whitespaces))
                }
                prices.append(p)
            }
            let r = ModelRates(name: name.replacingOccurrences(of: "Claude ", with: ""),
                               input: prices[0], cacheWrite5m: prices[1], cacheWrite1h: prices[2],
                               cacheRead: prices[3], output: prices[4])
            // Each row must have cache read < input < 5m write < 1h write and input < output.
            guard r.cacheRead < r.input, r.input < r.cacheWrite5m, r.cacheWrite5m < r.cacheWrite1h,
                  r.input < r.output else {
                throw PricingPageParseError.orderingViolation(model: name)
            }
            rates[modelID(fromName: name)] = r
            rowCount += 1
        }
        guard rowCount >= 5 else { throw PricingPageParseError.tooFewRows(rowCount) }
        if !known.isEmpty {
            let missing = known.subtracting(rates.keys).count
            if missing * 2 > known.count {
                throw PricingPageParseError.tooManyKnownModelsMissing(missing: missing, known: known.count)
            }
        }
        return rates
    }

    static func isHeader(_ line: String) -> Bool {
        let cells = splitRow(line.trimmingCharacters(in: .whitespaces))
        guard cells.count == headerColumns.count else { return false }
        return zip(cells, headerColumns).allSatisfy { $0.trimmingCharacters(in: .whitespaces) == $1 }
    }

    static func splitRow(_ line: String) -> [String] {
        var s = Substring(line)
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") { s = s.dropLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }
}

// MARK: - Persistence

/// `pricing/history.jsonl` (one line per distinct table) and `pricing/state.json`
/// (`lastAttemptAt`, `lastSuccessAt`) under Application Support, or any directory for tests.
public struct PriceHistoryStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("claude-usage-menu-bar", isDirectory: true)
            .appendingPathComponent("pricing", isDirectory: true)
    }

    var historyURL: URL { directory.appendingPathComponent("history.jsonl") }
    var stateURL: URL { directory.appendingPathComponent("state.json") }

    private struct State: Codable {
        var lastAttemptAt: Date?
        var lastSuccessAt: Date?
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// The built-in table plus every persisted entry. Undecodable lines are skipped.
    public func load() -> PriceHistory {
        var entries: [PriceHistory.Entry] = [PriceHistory.builtInEntry]
        if let data = try? Data(contentsOf: historyURL), let text = String(data: data, encoding: .utf8) {
            let dec = Self.decoder()
            for line in text.split(separator: "\n") where !line.isEmpty {
                if let e = try? dec.decode(PriceHistory.Entry.self, from: Data(line.utf8)) {
                    entries.append(e)
                }
            }
        }
        var history = PriceHistory(entries: entries)
        if let data = try? Data(contentsOf: stateURL), let s = try? Self.decoder().decode(State.self, from: data) {
            history.lastAttemptAt = s.lastAttemptAt
            history.lastSuccessAt = s.lastSuccessAt
        }
        return history
    }

    /// Persist the entries beyond the built-in one (rewritten whole — the file stays tiny) and
    /// the fetch state.
    public func save(_ history: PriceHistory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = Self.encoder()
        let lines = history.entries.dropFirst().compactMap { e -> String? in
            guard let d = try? enc.encode(e) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).data(using: .utf8)?
            .write(to: historyURL, options: .atomic)
        let state = State(lastAttemptAt: history.lastAttemptAt, lastSuccessAt: history.lastSuccessAt)
        try? enc.encode(state).write(to: stateURL, options: .atomic)
    }
}
