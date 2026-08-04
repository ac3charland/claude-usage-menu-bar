import Foundation

public struct UsageWindow: Decodable {
    public let utilization: Double
    /// `null` when the window is empty/fully reset (e.g. 0% utilization). The API
    /// genuinely sends `"resets_at": null` in that state, so this must be optional —
    /// decoding it as a non-optional Date threw and was mistaken for a poll failure.
    public let resetsAt: Date?
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// One entry of the response's `limits` array. Per-model weekly caps (e.g. Fable) live
/// here as `weekly_scoped` entries tagged with the model in `scope.model.display_name`;
/// they are not surfaced as top-level windows like `five_hour` / `seven_day`.
public struct UsageLimit: Decodable {
    public let kind: String?
    public let group: String?
    public let percent: Double?
    public let resetsAt: Date?
    public let scope: Scope?

    public struct Scope: Decodable {
        public let model: Model?
        public struct Model: Decodable {
            public let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, scope
        case resetsAt = "resets_at"
    }
}

public struct UsageResponse: Decodable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let limits: [UsageLimit]?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }

    /// The per-model weekly caps the endpoint reports as `weekly_scoped` entries in `limits`,
    /// each reconstructed as a `UsageWindow` so it flows through the same window math as
    /// `seven_day`. Order is preserved from the API. Empty when no per-model caps are reported.
    public var weeklyModelLimits: [(name: String, window: UsageWindow)] {
        (limits ?? []).compactMap { entry in
            guard entry.group == "weekly", entry.kind == "weekly_scoped",
                  let name = entry.scope?.model?.displayName, !name.isEmpty,
                  let pct = entry.percent else { return nil }
            return (name, UsageWindow(utilization: pct, resetsAt: entry.resetsAt))
        }
    }
}

public enum UsageFetchError: Error, CustomStringConvertible {
    case transport(Error)
    case http(status: Int, body: String)
    case unauthorized
    case rateLimited
    case errorEnvelope(type: String, message: String)
    case decode(Error, body: String)

    public var description: String {
        switch self {
        case .transport(let e): return "transport error: \(e)"
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(160))"
        case .unauthorized: return "HTTP 401 (token rejected)"
        case .rateLimited: return "HTTP 429 (rate limited)"
        case .errorEnvelope(let t, let m): return "200 error envelope: \(t) — \(m)"
        case .decode(let e, let b): return "decode error \(e); body=\(b.prefix(160))"
        }
    }
}

public enum UsagePoller {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func fetch(accessToken: String) async throws -> UsageResponse {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        let started = Date()
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            if let urlErr = error as? URLError {
                // Surface the URLError code by name+number — e.g. -1009 notConnectedToInternet,
                // -1005 networkConnectionLost (typical mid-WiFi-switch), -1001 timedOut.
                Log.warn("Usage fetch transport error after \(fmt(elapsed))s: \(urlErr.code.rawValue) \(name(urlErr.code)) — \(urlErr.localizedDescription)")
            } else {
                Log.warn("Usage fetch transport error after \(fmt(elapsed))s: \(error)")
            }
            throw UsageFetchError.transport(error)
        }
        let elapsed = Date().timeIntervalSince(started)
        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.transport(URLError(.badServerResponse))
        }
        Log.info("Usage fetch HTTP \(http.statusCode) in \(fmt(elapsed))s (\(data.count) bytes)")

        let bodyStr = String(data: data, encoding: .utf8) ?? ""

        if http.statusCode == 429 { throw UsageFetchError.rateLimited }
        if http.statusCode == 401 { throw UsageFetchError.unauthorized }
        if http.statusCode >= 400 {
            throw UsageFetchError.http(status: http.statusCode, body: bodyStr)
        }

        // Some Anthropic endpoints surface errors in a 200 body.
        struct ErrorEnvelope: Decodable {
            struct Inner: Decodable { let type: String?; let message: String? }
            let type: String?
            let error: Inner?
        }
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           env.type == "error", let err = env.error {
            throw UsageFetchError.errorEnvelope(type: err.type ?? "?", message: err.message ?? "?")
        }

        do {
            return try decodeResponse(from: data)
        } catch {
            throw UsageFetchError.decode(error, body: bodyStr)
        }
    }

    /// Decodes the usage payload with the endpoint's ISO-8601 date handling. Split out from
    /// `fetch` so the response shape (incl. per-model limits) can be unit-tested offline.
    public static func decodeResponse(from data: Data) throws -> UsageResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let str = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: str) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: str) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad ISO8601: \(str)"))
        }
        return try decoder.decode(UsageResponse.self, from: data)
    }

    private static func fmt(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds)
    }

    /// Human-readable name for the URLError codes we expect around connectivity changes;
    /// falls back to the raw code for anything else.
    private static func name(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet: return "notConnectedToInternet"
        case .networkConnectionLost: return "networkConnectionLost"
        case .timedOut: return "timedOut"
        case .cannotFindHost: return "cannotFindHost"
        case .cannotConnectToHost: return "cannotConnectToHost"
        case .dnsLookupFailed: return "dnsLookupFailed"
        default: return "code\(code.rawValue)"
        }
    }
}
