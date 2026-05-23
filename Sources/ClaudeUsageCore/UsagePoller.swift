import Foundation

public struct UsageWindow: Decodable {
    public let utilization: Double
    public let resetsAt: Date
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

public struct UsageResponse: Decodable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
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
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw UsageFetchError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.transport(URLError(.badServerResponse))
        }

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
        do {
            return try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw UsageFetchError.decode(error, body: bodyStr)
        }
    }
}
