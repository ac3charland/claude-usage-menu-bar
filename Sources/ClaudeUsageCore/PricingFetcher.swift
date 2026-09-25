import Foundation

/// Fetches Anthropic's public pricing page as markdown and folds it into a `PriceHistory`
/// (spec §6.2). Plain GET, no Authorization header, no cookies, no query parameters — the
/// OAuth token never goes to the docs site.
public enum PricingFetcher {
    public static let pageURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing.md")!
    public static let timeoutSec: TimeInterval = 10

    /// Try at most once every 24 hours; after a failure, retry on the next poll ≥ 1 hour later.
    public static let successIntervalSec: TimeInterval = 24 * 3600
    public static let failureRetrySec: TimeInterval = 3600

    /// Whether the cadence rules allow an attempt now.
    public static func isDue(_ history: PriceHistory, now: Date = Date()) -> Bool {
        guard let attempt = history.lastAttemptAt else { return true }
        let lastWasSuccess = history.lastSuccessAt.map { $0 >= attempt } ?? false
        let wait = lastWasSuccess ? successIntervalSec : failureRetrySec
        return now.timeIntervalSince(attempt) >= wait
    }

    public enum Outcome: Equatable {
        case appended       // a new dated entry was recorded
        case unchanged      // fetched fine, same prices as the latest entry
        case rejected(String)   // download or validation failed; last good table kept
    }

    /// Download the page. Returned as text; errors are thrown for the caller to log.
    public static func download(session: URLSession = .shared) async throws -> String {
        var req = URLRequest(url: pageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = timeoutSec
        req.httpShouldHandleCookies = false
        req.setValue("text/markdown, text/plain;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return text
    }

    /// Apply a downloaded page to the history: parse, validate, append if changed, and record the
    /// attempt. Pure apart from the clock passed in, so it is unit-testable with a fixture.
    public static func apply(markdown: String, to history: inout PriceHistory, now: Date) -> Outcome {
        history.lastAttemptAt = now
        do {
            let rates = try PricingPageParser.parse(markdown: markdown, known: history.knownModels)
            history.lastSuccessAt = now
            let appended = history.append(rates: rates, fetchedAt: now, source: pageURL.absoluteString)
            return appended ? .appended : .unchanged
        } catch {
            return .rejected(String(describing: error))
        }
    }

    /// Download and apply. Never throws; a failure is reported in the outcome.
    public static func refresh(_ history: inout PriceHistory, now: Date = Date()) async -> Outcome {
        let markdown: String
        do {
            markdown = try await download()
        } catch {
            history.lastAttemptAt = now
            return .rejected("download failed: \(error.localizedDescription)")
        }
        return apply(markdown: markdown, to: &history, now: now)
    }
}
