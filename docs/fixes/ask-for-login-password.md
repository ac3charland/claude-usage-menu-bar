# Fix log: the app keeps asking for my login password

## Symptom

macOS repeatedly shows the system modal:

> **"Claude Usage" wants to use the "login" keychain.** / *"Claude Usage" cannot be
> verified. Are you sure you want to allow access to this item?* — and asks for the
> login password.

Clicking **Always Allow** is supposed to make this stick. It doesn't: the prompt comes
back after a rebuild, a reinstall, or roughly every token-refresh cycle.

## Why this happens at all (architecture)

The app reads another app's Keychain item — `Claude Code-credentials`, a **legacy
file-keychain** generic-password in `login.keychain-db` written by the `claude` CLI — via
`SecItemCopyMatching` (`Sources/ClaudeUsageCore/KeychainReader.swift`). macOS gates that
cross-app read with an **ACL**. Whether the read is silent or pops a password prompt
depends on whether *our* process currently has a standing grant on that item's ACL.

Every fix below tried to make that standing grant **durable**. The new approach (attempt
#4) changes tactics: stop letting background reads trigger the prompt at all.

---

## Attempt #1 — strip auth-override env vars from the CLI ping

- **Commit:** `4274cc2` — *"strip auth-override env vars from CLI ping to prevent Keychain
  bypass"* (Sat Jun 6)
- **File:** `Sources/ClaudeUsageCore/TokenRefresher.swift`
- **Theory:** the app refreshes the token by spawning `claude -p ping`. If the app was
  launched from a shell exporting `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` /
  `ANTHROPIC_AUTH_TOKEN`, the CLI authenticates with *those* and exits 0 **without**
  rewriting the Keychain entry — so the token stays expired.
- **Change:** removed those three vars from the ping subprocess `environment` so the ping
  always exercises the real OAuth refresh path.
- **Result:** valid and worth keeping, but **unrelated to the password prompt.** It fixes
  *"token never refreshes"*, not *"reading the item prompts for a password."*

## Attempt #2 — sign every build with one stable self-signed cert

- **Commit:** `7f22aea` — *"sign app with stable self-signed cert so Keychain 'Always
  Allow' sticks"* (Mon Jun 8)
- **Files:** `scripts/make-app.sh`, new `scripts/make-signing-cert.sh`
- **Theory:** the ACL grant is keyed on the **reader's code-signing identity**. The app was
  unsigned (bundle) or ad-hoc-signed (bare binary), producing a *different* identity on
  every build, so "Always Allow" never matched the next rebuild → re-prompt.
- **Change:** `make-signing-cert.sh` creates one self-signed code-signing identity
  (`"Claude Usage Self-Signed"`); `make-app.sh` signs every bundle with it. The
  designated requirement is now byte-identical across rebuilds.
- **Result:** necessary but **not sufficient.** A stable identity is a precondition for a
  durable grant, but the prompt kept returning — which led to attempt #3.

## Attempt #3 — mark the self-signed cert as *trusted*

- **Commit:** `6ecdd3b` — *"trust the self-signed signing cert so Keychain auth verifies
  the app"* (Thu Jun 11)
- **File:** `scripts/make-signing-cert.sh`
- **Theory:** codesign happily signs with an *untrusted* cert, but the Keychain
  authorization layer additionally validates the requesting app's **authenticity** against
  trusted code-signing certs. An untrusted cert fails that check → the stronger
  *"authenticity cannot be verified"* prompt → "Always Allow" never durably sticks.
- **Change:** added `ensure_trust()` — `security add-trusted-cert -r trustRoot -p codeSign`
  in the login keychain (one-time GUI auth), made idempotent, and the script no longer a
  no-op when the cert already exists.
- **Result:** **still re-prompts** in practice. This is the state the user is reporting
  against. The cert is present and trusted today (verified below) yet the prompt persists,
  which means trust/identity stability is not the whole story.

### State on disk at the time of writing (all three fixes are live)

```
cert present:   SHA-1 20A38A9EBE…  "Claude Usage Self-Signed"
trust settings: Cert 2: Claude Usage Self-Signed        ← trusted for codeSign
installed app:  /Applications/Claude Usage.app
                Authority=Claude Usage Self-Signed       ← signed with the stable cert
                TeamIdentifier=not set                   ← no team id (see analysis)
```

So attempts #2 and #3 are fully in effect — and the prompt still happens. The reader-side
identity is as stable and trusted as a self-signed setup can be.

---

## What the logs actually show

Log: `~/Library/Application Support/claude-usage-menu-bar/claude-usage.log`

The failing reads are **not** plain auth failures. Decoding the OSStatus codes:

| Code | Meaning (`security error`) | Count |
|------|----------------------------|-------|
| `-25320` | **"In dark wake, no UI possible"** | 25 |
| `-60008` | "Unable to obtain authorization for this operation" | 3 |

Both mean the same thing: **the read wanted to display the authorization UI** (i.e. we did
*not* have silent access) **and couldn't.** Key observations:

1. **They cluster, and they correlate with background wake/reconnect polls.** Every
   `-25320` is on a poll fired by a `Network reconnected` or `Wake event` trigger — i.e.
   the Mac is in *dark wake*, where no modal can be shown or answered:

   ```
   06:23:46 INFO  Network reconnected — resetting back-off and polling immediately
   06:23:46 INFO  Token expires in -65min — refreshing via CLI ping
   06:23:54 INFO  CLI ping exited code=0 after 7.6s
   06:23:54 ERROR Poll failed: Keychain SecItemCopyMatching failed: -25320   ← read wanted UI
   07:09:24 ERROR Poll failed: Keychain SecItemCopyMatching failed: -25320
   …continues all day, no successful read in between…
   ```

2. **The grant is fragile across builds/reinstalls.** On Jun 12 reads succeeded *silently*
   even immediately after CLI pings; from Jun 13 onward the same pattern failed with
   `-25320` all day. The likely trigger is a rebuild/trust change/reinstall to
   `/Applications` (`6d9b047`) producing a moment where the standing grant was gone — and
   once gone, every background read in dark wake fails because it can't prompt.

### Conclusions

- The three prior fixes all attack the **durability of the OS grant**. The logs show that
  even with a stable, trusted identity the grant still lapses (rebuild / reinstall /
  refresh boundary), and when it lapses the app fires the prompt **at the worst possible
  time** — a background poll in dark wake, where the user isn't even present and the modal
  can't be answered. Those dark-wake prompts can also surface later as the queued
  password modal the user keeps seeing.
- Contributing factor: the app is signed with a **self-signed cert that has no Team
  Identifier**. macOS's per-item *partition list* (the mechanism that makes "Always Allow"
  silent for codesigned apps) keys on entries like `teamid:…`; a no-team self-signed app
  is exactly the case the partition list can't cleanly whitelist, so it is prone to
  re-prompting even after "Always Allow."

The realization: **chasing a perfectly-durable OS grant for a self-signed, no-team app
reading another app's legacy keychain item is fighting the platform.** A more robust tactic
is to stop background polls from ever triggering the prompt, and let the user grant access
deliberately, once, on their own terms.

---

## Attempt #4 (new) — never prompt from a background poll; authorize on demand

**Idea:** decouple *reading* from *prompting*. Background polls do a **silent-only** read;
if we lack standing access they degrade gracefully instead of popping a modal. The prompt
is moved behind an explicit, user-initiated menu action, so it only ever appears when the
user asked for it — never mid-work, never in dark wake.

### Changes

1. **`KeychainReader.read(allowInteraction:)`** — `Sources/ClaudeUsageCore/KeychainReader.swift`
   - New default `allowInteraction: false`. In that mode the read suppresses UI two ways
     (belt-and-suspenders for the legacy file keychain):
     - `SecKeychainSetUserInteractionAllowed(false)` around the call (the flag that
       actually gates the legacy-keychain ACL prompt), and
     - `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail` in the query.
   - `-25308` (`errSecInteractionNotAllowed`) and `-25320` (dark-wake, no SDK constant) now
     map to a new typed error `KeychainError.interactionRequired` instead of a raw
     `secStatus`. (The two deprecation warnings on the legacy `SecKeychain*` /
     `kSecUseAuthenticationUI` APIs are expected — this *is* a legacy file-keychain item;
     the modern `LAContext` replacement only applies to data-protection-keychain items.)

2. **New engine state `needsAuthorization`** — `Sources/ClaudeUsageCore/EngineState.swift`
   - Reason string: *"Right-click → Authorize Keychain Access"*. Degraded (dimmed icon).

3. **`UsageEngine`** — `Sources/ClaudeUsageCore/UsageEngine.swift`
   - All background reads (initial, post-refresh, post-401-retry) now pass
     `allowInteraction: false`.
   - `catch KeychainError.interactionRequired` → publish `.needsAuthorization`, keep showing
     the last-good snapshot, and **don't** grow the failure back-off (it's a standing
     condition, not a transient error to hammer).
   - New `authorizeNow()` — the **only** path allowed to prompt. It does one
     `read(allowInteraction: true)` on the main actor; on success it resets failures and
     polls immediately, so the freshly-granted access refreshes the UI.

4. **Menu wiring** — `StatusItemController.swift` + `AppDelegate.swift`
   - When state is `.needsAuthorization`, the right-click menu shows
     **"Authorize Keychain Access…"**, wired to `engine.authorizeNow()`.

### Why this should help

- The OS password modal can no longer be triggered by a timer/wake/reconnect poll, so the
  *ambush* prompts (including the unanswerable dark-wake ones, `-25320`) stop entirely.
- When the grant does lapse, the app shows a quiet dimmed icon + a menu item instead of a
  modal. The user clicks once, gets one expected prompt, clicks **Always Allow**, and
  polling resumes — on their schedule, not the poller's.
- It is independent of (and complementary to) the signing/trust work in #2–#3: those make
  the single deliberate grant last as long as possible; this makes the *failure mode* civil
  instead of a recurring password demand.

### Build / status

- `swift build` → **Build complete** (only the two expected legacy-API deprecation
  warnings). Verified all `read()` call sites updated; no other callers exist.
- **Validation caveat:** the bug only manifests across refresh cycles, dark wakes, and
  rebuild boundaries, which can't be fully reproduced in one session. Rebuild with
  `./scripts/make-app.sh release`, run, and confirm over a day that the icon dims to
  *needs-authorization* rather than spawning the password modal, and that
  **Authorize Keychain Access…** restores polling with a single prompt.

---

## If #4 isn't enough — attempt #5 (proposed, not yet implemented)

The genuinely durable fix is to **stop re-reading `claude`'s item on the hot path**:

1. Read `Claude Code-credentials` **once** (one deliberate prompt at bootstrap).
2. Mirror `{accessToken, refreshToken, expiresAt}` into the app's **own** generic-password
   item (e.g. service `com.alexcharland.ClaudeUsageMenuBar.credentials`). Because the app
   *creates* and *owns* that item, reading/writing it is silent forever — no ACL prompt.
3. Refresh the token **ourselves** via the OAuth refresh-token grant and write the rotated
   tokens back to our own item. Drop the `claude` CLI ping from the hot path. Fall back to
   a single interactive re-read of `claude`'s item only if our refresh token is revoked.

**Tradeoff to decide first:** OAuth refresh tokens *rotate* — if our app refreshes, the
`claude` CLI's stored refresh token can go stale, potentially forcing the user to
re-`claude /login`. The current design deliberately delegates refresh to `claude` to avoid
exactly this. #5 trades the password prompt for that risk, so it needs the user's explicit
sign-off (and a plan to keep our refresh from racing the CLI's) before implementing.
