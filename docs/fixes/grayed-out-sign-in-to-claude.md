# Fix log: widget grayed out, "Sign in to Claude Code to see usage"

## Symptom

After installing the attempt-#4 build (commit `3e87f9f`, *"stop background polls from
triggering the Keychain password prompt"*), the menu bar icon goes **dimmed/grayed-out**
and the popover reads:

> **Sign in to Claude Code to see usage**

…even though the user is signed in (`claude` CLI works, credentials are in the Keychain)
and has clicked **Refresh Now** several times. The state never recovers.

## Related

This is a **regression introduced by attempt #4** in
[`ask-for-login-password.md`](./ask-for-login-password.md). Read that doc first — it
explains the cross-app Keychain ACL architecture and the four prior attempts. Attempt #4
made background polls do a *silent-only* Keychain read so they can't pop the login-password
modal; this bug is a hole in how that silent-denial is classified.

## What the logs show

Log: `~/Library/Application Support/claude-usage-menu-bar/claude-usage.log`

Polls succeeded cleanly (HTTP 200, snapshots every 120s) right up until the app was
relaunched onto the new build:

```
17:47:14Z INFO  Usage fetch HTTP 200 in 0.50s (564 bytes)
17:47:14Z INFO  Snapshot: session=18.0% … weekly=10.0%
17:49:01Z INFO  Wrote login-item LaunchAgent …
17:49:01Z INFO  Claude Usage launched (menu bar) …          ← new build starts
17:49:01Z INFO  Loaded cached snapshot (… session=18.0% …)
17:49:01Z ERROR Poll failed: Keychain SecItemCopyMatching failed: -25293   ← every read now fails
17:49:19Z INFO  Manual refresh requested — interrupting sleep to poll now
17:49:19Z ERROR Poll failed: Keychain SecItemCopyMatching failed: -25293
17:56:20Z ERROR Poll failed: Keychain SecItemCopyMatching failed: -25293
17:57:06Z ERROR Poll failed: Keychain SecItemCopyMatching failed: -25293
17:57:17Z ERROR Poll failed: Keychain SecItemCopyMatching failed: -25293
```

Decoding the OSStatus (`security error -25293`):

| Code | Meaning |
|------|---------|
| `-25293` | `errSecAuthFailed` — "The user name or passphrase you entered is not correct." |

Despite the wording, this is **not** a wrong-password event — it's what the legacy file
keychain returns for a **UI-suppressed read whose standing ACL grant has lapsed**: it would
need to authenticate the caller, but attempt #4 forbade it from showing UI
(`SecKeychainSetUserInteractionAllowed(false)` + `kSecUseAuthenticationUIFail`). Same root
cause as the `-25320` (dark wake) and `-25308` (`errSecInteractionNotAllowed`) codes from
the prior doc: **we lack silent access to `claude`'s item**, here because the relaunch onto
a fresh build dropped the grant (exactly the fragility-across-builds note in attempts #2/#3).

## Root cause

Two layers, both in attempt #4's code:

1. **Mis-classification (`KeychainReader.swift`).** The silent read only mapped
   `errSecInteractionNotAllowed` (-25308) and the dark-wake code (-25320) to
   `.interactionRequired`. `errSecAuthFailed` (-25293) — the form the silent denial takes on
   this machine after a rebuild — was not in that set, so it fell through to the generic
   `.secStatus(-25293)`.

2. **Wrong terminal state (`UsageEngine.swift:158-162`).** A generic `KeychainError` is
   caught and published as **`.noToken`** → *"Sign in to Claude Code to see usage."* That is
   a **dead end**:
   - Misleading: the user *is* signed in; the credentials exist and are valid.
   - Unrecoverable: `.noToken` does **not** expose the **"Authorize Keychain Access…"** menu
     item — that only appears in `.needsAuthorization` (see `StatusItemController.swift`). So
     **Refresh Now** just re-runs the silent poll → -25293 → `.noToken` again, forever. The
     log's five identical manual-refresh failures are exactly this loop.

So attempt #4 successfully stopped the ambush password modal, but when the silent denial
arrives as -25293 it lands the app in the one degraded state that has no recovery affordance.

## Attempt #5 — treat silent errSecAuthFailed as "needs authorization"

- **Commit:** _(this change)_
- **File:** `Sources/ClaudeUsageCore/KeychainReader.swift`
- **Change:** in `read(allowInteraction:)`, when the read is silent (`allowInteraction ==
  false`), also map `errSecAuthFailed` (-25293) to `KeychainError.interactionRequired`,
  alongside the existing `errSecInteractionNotAllowed` / dark-wake codes:

  ```swift
  let silentlyDenied = status == errSecInteractionNotAllowed
      || status == errSecInDarkWake
      || (!allowInteraction && status == errSecAuthFailed)
  if silentlyDenied { throw KeychainError.interactionRequired }
  ```

  The `!allowInteraction` guard is deliberate: an **interactive** read returning -25293 is a
  genuine wrong-password failure, and `authorizeNow()` already catches any error and
  republishes `.needsAuthorization`, so the interactive path is unaffected.

### Why this fixes it

- The lapsed-grant case now publishes **`.needsAuthorization`** instead of `.noToken`. The
  icon still dims, but the reason line becomes *"Right-click → Authorize Keychain Access"*
  and the right-click menu shows **"Authorize Keychain Access…"**.
- The user clicks it once → one expected prompt → **Always Allow** → `authorizeNow()` regains
  silent access and polls immediately. The dead-end loop is gone.
- It composes with attempt #4: background polls still never pop the modal; this just makes
  the *failure surface* the recoverable one in every silent-denial form, not only the two
  codes #4 happened to enumerate.

### Build / status

- `swift build` → **Build complete** (only the two expected legacy-API deprecation warnings
  from attempt #4's `SecKeychain*` / `kSecUseAuthenticationUI` calls).
- **Validation caveat (same as #4):** reproducing the lapsed grant requires a rebuild /
  reinstall / refresh boundary, which can't be forced reliably in one session. After
  `./scripts/make-app.sh release` and relaunch, confirm that when the grant lapses the icon
  shows *needs-authorization* (with the menu item) rather than *"Sign in to Claude Code"*,
  and that **Authorize Keychain Access…** restores polling with a single prompt.

## If #5 isn't enough

The durable fix remains **attempt #5 (proposed) in `ask-for-login-password.md`**: stop
re-reading `claude`'s item on the hot path — read it once, mirror the tokens into the app's
*own* keychain item (silent forever because we own it), and refresh ourselves. That removes
the ACL prompt class entirely, at the cost of refresh-token rotation racing the CLI (needs
the user's sign-off first).
