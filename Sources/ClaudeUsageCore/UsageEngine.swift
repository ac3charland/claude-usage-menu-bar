import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Network)
import Network
#endif

@MainActor
public final class UsageEngine {
    public static nonisolated let defaultBaseIntervalSec: TimeInterval = 120
    public static nonisolated let maxIntervalSec: TimeInterval = 30 * 60

    /// Base poll interval between successful polls. User-adjustable via preferences;
    /// takes effect on the next sleep.
    public var baseIntervalSec: TimeInterval = UsageEngine.defaultBaseIntervalSec

    private var failures = 0
    private var last429 = false
    private var rateLimitedUntil: Date?
    private var sleepTask: Task<Void, Never>?
    private var wakeObserverToken: NSObjectProtocol?
    #if canImport(Network)
    private var pathMonitor: NWPathMonitor?
    /// Last observed reachability, so we only react to a real offline→online edge
    /// (not every interface change while already online).
    private var lastPathSatisfied: Bool?
    #endif

    /// Last good snapshot + its capture time, retained across failures so the UI keeps
    /// showing the last known usage (dimmed) rather than going blank.
    private var lastSnapshot: UsageSnapshot?
    private var lastSuccess: Date?

    /// After the user dismisses the Keychain password prompt, hold off on prompting again
    /// until this time — polls in the meantime read silently so we don't re-pop the modal
    /// every interval. `nil` means "free to prompt on the next poll". A manual Refresh Now
    /// clears it so the user can deliberately re-trigger the prompt.
    private var suppressPromptUntil: Date?
    /// How long to stay quiet after a dismissed prompt.
    private static let promptCooldownSec: TimeInterval = 15 * 60

    /// Current published state. The UI observes `onState`.
    public private(set) var state: EngineState = .empty
    /// Called on the main actor whenever `state` changes.
    public var onState: ((EngineState) -> Void)?

    public init() {}

    deinit {
        if let token = wakeObserverToken {
            #if canImport(AppKit)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            #endif
        }
        #if canImport(Network)
        pathMonitor?.cancel()
        #endif
    }

    public func run() async {
        if let cached = SnapshotCache.load() {
            Log.info("Loaded cached snapshot (capturedAt=\(cached.capturedAt)): \(cached.shortDescription)")
            lastSnapshot = cached
            lastSuccess = cached.capturedAt
            // Stale until the first live poll confirms it, so the UI paints immediately
            // but signals the data is not yet verified this session.
            publish(.stale)
        } else {
            Log.info("No cached snapshot on disk — first paint will wait for first poll")
            publish(.stale)
        }

        startWakeObserver()
        startPathObserver()

        while !Task.isCancelled {
            await pollOnce()

            let interval = nextIntervalSec()
            Log.info("Sleeping \(Int(interval))s before next poll (failures=\(failures), last429=\(last429))")
            await interruptibleSleep(seconds: interval)

            // If a wake event interrupted us during a 429 back-off window, hold position.
            if let until = rateLimitedUntil, until > Date() {
                let remaining = until.timeIntervalSinceNow
                Log.info("Rate-limited window not over — waiting \(Int(remaining))s more before retry")
                await interruptibleSleep(seconds: remaining)
            }
        }
    }

    private func pollOnce() async {
        // When access has lapsed (the `claude` CLI recreates its Keychain item on each token
        // refresh, which wipes our ACL grant), the widget asks for the login password right
        // then — no deferred "right-click to authorize" step. We only fall back to a silent
        // read during the cooldown window after the user has dismissed a prompt, so we don't
        // re-pop the modal on every 2-minute poll.
        let mayPrompt = suppressPromptUntil.map { Date() >= $0 } ?? true
        do {
            let creds = try KeychainReader.read(allowInteraction: mayPrompt)
            let didRefresh = await TokenRefresher.refreshIfNeeded(currentExpiresAtMs: creds.expiresAtMs)
            let active = didRefresh ? (try KeychainReader.read(allowInteraction: mayPrompt)) : creds

            // The endpoint returns 429 (not 401) for an expired bearer once we've hit it
            // enough times, so a dead token silently turns into an exponential back-off
            // loop the user reads as "rate limited". Bail out before the fetch when the
            // refresh didn't actually advance expiry — most often because the keychain
            // entry has an empty refreshToken (user signed in via an IDE extension that
            // doesn't persist one) so the CLI ping has nothing to swap.
            if Date(timeIntervalSince1970: active.expiresAtMs / 1000) <= Date() {
                failures += 1
                last429 = false
                Log.error("Access token still expired after refresh attempt — skipping poll. Run `claude /login` to restore credentials.")
                publish(.refreshFailed)
                return
            }

            let response: UsageResponse
            do {
                response = try await UsagePoller.fetch(accessToken: active.accessToken)
            } catch UsageFetchError.unauthorized {
                Log.warn("Got 401 from usage endpoint — forcing refresh and retrying once")
                await TokenRefresher.forceRefresh()
                let retried = try KeychainReader.read(allowInteraction: mayPrompt)
                if Date(timeIntervalSince1970: retried.expiresAtMs / 1000) <= Date() {
                    Log.error("Forced refresh did not advance token expiry — treating as refreshFailed")
                    throw UsageFetchError.unauthorized
                }
                response = try await UsagePoller.fetch(accessToken: retried.accessToken)
            }

            let snapshot = UsageSnapshot.from(response)
            Log.info("Snapshot: \(snapshot.shortDescription)")
            SnapshotCache.save(snapshot)

            lastSnapshot = snapshot
            lastSuccess = snapshot.capturedAt
            failures = 0
            last429 = false
            rateLimitedUntil = nil
            suppressPromptUntil = nil
            publish(.ok)
        } catch UsageFetchError.rateLimited {
            failures += 1
            last429 = true
            rateLimitedUntil = Date().addingTimeInterval(nextIntervalSec())
            Log.warn("Rate limited (429). failures=\(failures), holding until \(rateLimitedUntil!)")
            publish(.rateLimited)
        } catch UsageFetchError.unauthorized {
            // Still 401 after a forced refresh — the stored token can't be revived here.
            failures += 1
            last429 = false
            Log.error("Poll failed: token rejected after refresh")
            publish(.refreshFailed)
        } catch KeychainError.notFound {
            failures += 1
            last429 = false
            Log.error("Poll failed: \(KeychainError.notFound.description)")
            publish(.noToken)
        } catch KeychainError.userCanceled {
            // The user dismissed the password prompt. Respect that: stay quiet for a cooldown
            // (silent reads only) so we don't re-pop the modal every poll, and keep showing
            // the last-good snapshot. A manual Refresh Now clears the cooldown to re-prompt.
            last429 = false
            suppressPromptUntil = Date().addingTimeInterval(Self.promptCooldownSec)
            Log.warn("Keychain prompt dismissed — suppressing prompts for \(Int(Self.promptCooldownSec / 60))min")
            publish(.stale)
        } catch KeychainError.interactionRequired {
            // We wanted to prompt but macOS couldn't show the modal (dark wake, or we're in
            // the post-dismissal cooldown doing a silent read). Not a real failure: keep the
            // last-good snapshot and let the next poll prompt when the machine is awake.
            last429 = false
            Log.warn("Poll skipped: could not show Keychain prompt now — will retry next poll")
            publish(.stale)
        } catch let err as KeychainError {
            failures += 1
            last429 = false
            Log.error("Poll failed: \(err.description)")
            publish(.noToken)
        } catch let UsageFetchError.transport(inner) {
            failures += 1
            last429 = false
            Log.error("Poll failed: transport error: \(inner)")
            publish(.offline)
        } catch let err as UsageFetchError {
            failures += 1
            last429 = false
            Log.error("Poll failed: \(err.description)")
            publish(.error)
        } catch {
            failures += 1
            last429 = false
            Log.error("Poll failed: \(error)")
            publish(.error)
        }
    }

    /// Builds an `EngineState` from the retained last-good snapshot and publishes it.
    private func publish(_ status: EngineStatus) {
        let newState = EngineState(snapshot: lastSnapshot, status: status, lastSuccess: lastSuccess)
        state = newState
        onState?(newState)
    }

    private func nextIntervalSec() -> TimeInterval {
        if failures == 0 { return baseIntervalSec }
        let mult: Double = last429 ? 3 : 2
        let interval = baseIntervalSec * pow(mult, Double(failures))
        return min(interval, Self.maxIntervalSec)
    }

    /// Force an immediate poll by interrupting the current sleep — same mechanism as
    /// wake. Safe to call at any time (no-op if already polling). Clears any post-dismissal
    /// prompt cooldown so a manual Refresh Now is also the user's "ask me for the password
    /// now" affordance.
    public func refreshNow() {
        Log.info("Manual refresh requested — interrupting sleep to poll now")
        rateLimitedUntil = nil
        suppressPromptUntil = nil
        sleepTask?.cancel()
    }

    private func interruptibleSleep(seconds: TimeInterval) async {
        let task = Task<Void, Never> {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            } catch {
                // cancellation is expected
            }
        }
        sleepTask = task
        _ = await task.value
        sleepTask = nil
    }

    private func startWakeObserver() {
        #if canImport(AppKit)
        wakeObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification fires on the main queue; we're already main-isolated.
            MainActor.assumeIsolated {
                Log.info("Wake event — interrupting sleep to poll immediately")
                self?.sleepTask?.cancel()
            }
        }
        #endif
    }

    /// Watch network reachability and poll the instant connectivity returns. Without this,
    /// a Wi-Fi switch leaves us asleep in an exponential back-off window (up to 30 min) with
    /// nothing to wake it — the wake observer only fires on system sleep/wake, not network
    /// changes. Reacts only to a real offline→online edge.
    private func startPathObserver() {
        #if canImport(Network)
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            // Delivered on the queue passed to start(queue:) below — main — so we're isolated.
            MainActor.assumeIsolated {
                guard let self else { return }
                let previous = self.lastPathSatisfied
                self.lastPathSatisfied = satisfied
                if previous == false && satisfied {
                    self.handleNetworkReconnect()
                }
            }
        }
        monitor.start(queue: .main)
        #endif
    }

    /// Network just came back: drop the transport back-off and poll now, instead of waiting
    /// out a sleep that could be tens of minutes long.
    private func handleNetworkReconnect() {
        // A reconnect doesn't lift a server-side 429, so respect an active rate-limit window.
        if let until = rateLimitedUntil, until > Date() {
            Log.info("Network reconnected, but rate-limit window still active — not forcing a poll")
            return
        }
        Log.info("Network reconnected — resetting back-off and polling immediately")
        failures = 0
        last429 = false
        sleepTask?.cancel()
    }
}
