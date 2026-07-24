import Foundation
import Security

public struct OAuthCredentials {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAtMs: Double
}

public enum KeychainError: Error, CustomStringConvertible {
    case notFound
    case interactionRequired
    case userCanceled
    case secStatus(OSStatus)
    case malformedPayload

    public var description: String {
        switch self {
        case .notFound: return "Keychain item 'Claude Code-credentials' not found"
        case .interactionRequired: return "Keychain access needs authorization but UI could not be shown"
        case .userCanceled: return "User dismissed the Keychain authorization prompt"
        case .secStatus(let s): return "Keychain SecItemCopyMatching failed: \(s)"
        case .malformedPayload: return "Keychain payload did not contain expected claudeAiOauth fields"
        }
    }
}

public enum KeychainReader {
    private static let service = "Claude Code-credentials"

    /// macOS returns this (un-named in the SDK) when a read would need to show the
    /// authorization UI but the machine is in dark wake — e.g. a background poll fired
    /// by a network-reconnect or system-wake event. There is no display to host the modal,
    /// so even an interactive read can't prompt here.
    private static let errSecInDarkWake: OSStatus = -25320

    /// Shape of the `Claude Code-credentials` payload: a JSON object whose `claudeAiOauth`
    /// key holds the OAuth token triple. Both read paths (CLI + Security.framework) decode this.
    private struct Envelope: Decodable {
        struct Inner: Decodable {
            let accessToken: String
            let refreshToken: String
            let expiresAt: Double
        }
        let claudeAiOauth: Inner
    }

    /// Read the `Claude Code-credentials` item.
    ///
    /// - Parameter allowInteraction: when `true`, a lapsed ACL grant pops the macOS
    ///   "enter your login password / Always Allow" modal — the user grants access on the
    ///   spot and polling resumes. This is the default behavior: the widget asks for the
    ///   password when it needs it, rather than deferring behind a menu item.
    ///   When `false`, the read is forced *silent* (no modal); a lapsed grant throws
    ///   `.interactionRequired`. We use silent reads only briefly, to avoid re-popping the
    ///   modal right after the user has dismissed it (see the prompt cooldown in `UsageEngine`).
    ///
    ///   Two non-success outcomes are distinguished so the engine can react sensibly:
    ///   `.userCanceled` (the user dismissed the prompt — back off, don't nag) vs.
    ///   `.interactionRequired` (no UI could be shown, e.g. dark wake — just retry later).
    ///
    ///   The primary read path shells out to `/usr/bin/security` (see `readViaSecurityCLI`),
    ///   which reads silently regardless of the ACL because securityd evaluates access against
    ///   the Apple-signed `security` binary — the item's creator — not this app. The
    ///   `SecItemCopyMatching` path below is kept as a fallback for when the CLI route can't
    ///   serve the read, and is where all `allowInteraction` / prompt behavior still lives.
    public static func read(allowInteraction: Bool = true) throws -> OAuthCredentials {
        // Primary path: the silent `security` CLI read. On success or a definitive
        // "item not found", we're done — the fallback would only re-derive the same answer
        // (and, worse, could re-introduce the ACL prompt). Any other CLI-path failure
        // (timeout, unexpected exit, malformed payload) drops through to the framework path.
        do {
            let creds = try readViaSecurityCLI()
            notePath(.securityCLI)
            return creds
        } catch KeychainError.notFound {
            throw KeychainError.notFound
        } catch {
            Log.info("security CLI read failed (\(error)); falling back to Security.framework")
        }

        // Belt-and-suspenders UI suppression. `Claude Code-credentials` lives in the
        // legacy file keychain (login.keychain-db), whose ACL prompt is gated by the
        // process-wide SecKeychainSetUserInteractionAllowed flag — kSecUseAuthenticationUI
        // alone (a data-protection-keychain knob) does not reliably suppress it.
        if !allowInteraction {
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer { if !allowInteraction { SecKeychainSetUserInteractionAllowed(true) } }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        // The user actively dismissed the password / Always-Allow modal. Surface it as its
        // own case so the engine can back off instead of re-popping the modal on the very
        // next poll.
        if status == errSecUserCanceled { throw KeychainError.userCanceled }
        // "Couldn't show the authorization UI at all": dark wake (-25320) or
        // errSecInteractionNotAllowed (-25308, raised by our own UI suppression on silent
        // reads). On a silent read a lapsed grant can also surface as errSecAuthFailed
        // (-25293) — the legacy keychain's way of saying "I'd need to authenticate you and
        // I'm not allowed to show UI." None of these are a real auth failure; they just mean
        // we couldn't prompt right now, so let the engine retry on a later poll. (On an
        // interactive read, -25293 is a genuine wrong-password and falls through to .secStatus.)
        let couldNotPrompt = status == errSecInteractionNotAllowed
            || status == errSecInDarkWake
            || (!allowInteraction && status == errSecAuthFailed)
        if couldNotPrompt {
            throw KeychainError.interactionRequired
        }
        guard status == errSecSuccess else { throw KeychainError.secStatus(status) }
        guard let data = result as? Data else { throw KeychainError.malformedPayload }

        do {
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            notePath(.fallback)
            return OAuthCredentials(
                accessToken: env.claudeAiOauth.accessToken,
                refreshToken: env.claudeAiOauth.refreshToken,
                expiresAtMs: env.claudeAiOauth.expiresAt
            )
        } catch {
            throw KeychainError.malformedPayload
        }
    }

    // MARK: - Primary read path: /usr/bin/security subprocess

    /// Hard timeout for the `security` read subprocess, mirroring `TokenRefresher`'s CLI ping.
    private static let cliTimeoutSeconds: TimeInterval = 10

    /// Distinguishable failures of the CLI read path. `read` treats any of these (i.e. any
    /// non-`.notFound` throw) as a signal to fall back to `SecItemCopyMatching`.
    private enum CLIReadError: Error, CustomStringConvertible {
        case spawnFailed(String)
        case timeout
        case exit(Int32, stderr: String)

        var description: String {
            switch self {
            case .spawnFailed(let e): return "could not spawn /usr/bin/security: \(e)"
            case .timeout: return "/usr/bin/security exceeded \(Int(KeychainReader.cliTimeoutSeconds))s"
            case .exit(let code, let stderr):
                let detail = stderr.isEmpty ? "" : " — \(stderr)"
                return "/usr/bin/security exited code=\(code)\(detail)"
            }
        }
    }

    /// Read the secret by spawning the Apple-signed `/usr/bin/security` binary.
    ///
    /// securityd evaluates keychain access against the process making the Security-framework
    /// call. `security` matches the item's `apple-tool:` partition list (and is its creator via
    /// the `claude` CLI, which shells out to the same binary), so the read is silent — no ACL
    /// prompt — and survives every token refresh, rebuild, and reinstall. This is why it's the
    /// primary path: no standing grant on *this* app can survive the CLI's delete+recreate cycle.
    private static func readViaSecurityCLI() throws -> OAuthCredentials {
        let proc = Process()
        // Absolute path, no PATH lookup — we require the Apple-signed system binary.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Drain both pipes on background queues so a full pipe buffer can never deadlock the
        // wait loop below. `readDataToEndOfFile` returns once the process closes its write ends.
        var stdoutData = Data()
        var stderrData = Data()
        let drain = DispatchGroup()
        let ioQueue = DispatchQueue(label: "com.claude-usage.security-cli-io", attributes: .concurrent)
        drain.enter()
        ioQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            drain.leave()
        }
        drain.enter()
        ioQueue.async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            drain.leave()
        }

        let started = Date()
        do {
            try proc.run()
        } catch {
            throw CLIReadError.spawnFailed("\(error)")
        }

        let deadline = started.addingTimeInterval(cliTimeoutSeconds)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if proc.isRunning { proc.interrupt() }
            throw CLIReadError.timeout
        }
        // Process has exited; the drain reads return promptly now that the write ends are closed.
        drain.wait()

        let code = proc.terminationStatus
        switch code {
        case 0:
            break
        case 44:
            // `security` exit 44 == errSecItemNotFound: no such generic-password item.
            throw KeychainError.notFound
        default:
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIReadError.exit(code, stderr: stderr)
        }

        // `-w` prints the raw password (our JSON) plus a trailing newline.
        guard let raw = String(data: stdoutData, encoding: .utf8) else {
            throw KeychainError.malformedPayload
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = trimmed.data(using: .utf8) else {
            throw KeychainError.malformedPayload
        }

        do {
            let env = try JSONDecoder().decode(Envelope.self, from: jsonData)
            return OAuthCredentials(
                accessToken: env.claudeAiOauth.accessToken,
                refreshToken: env.claudeAiOauth.refreshToken,
                expiresAtMs: env.claudeAiOauth.expiresAt
            )
        } catch {
            // Distinguish "valid JSON, but no claudeAiOauth key" (Claude Code moved its OAuth
            // credentials elsewhere) from "not the shape we expect" — the former is the
            // diagnostic for a future storage-format regression.
            if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               obj["claudeAiOauth"] == nil {
                Log.error("Claude Code changed its credential storage format — 'claudeAiOauth' "
                    + "key absent from the keychain payload (keys: \(obj.keys.sorted()))")
            }
            throw KeychainError.malformedPayload
        }
    }

    // MARK: - Path diagnostics

    /// Which read path served the credentials. Logged on first success and whenever the path
    /// changes (not on every poll) — the breadcrumb for diagnosing a future regression, e.g.
    /// if the silent CLI route stops working and reads quietly degrade to the prompting fallback.
    private enum ReadPath: String {
        case securityCLI = "security CLI"
        case fallback = "Security.framework fallback"
    }
    private static var lastLoggedPath: ReadPath?

    private static func notePath(_ path: ReadPath) {
        guard lastLoggedPath != path else { return }
        lastLoggedPath = path
        Log.info("Keychain read served via \(path.rawValue)")
    }
}
