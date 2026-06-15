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

---

## Web research (Jun 15) — confirms the root cause, and that "durable mirror" is risky

After the user reported that #4/#5 just replaced the password prompt with a *daily manual
"Right-click → Authorize" step*, we did a proper web search. Two findings reframed everything:

1. **Root cause is the writer, not our signing.** The `claude` CLI refreshes its token by
   **deleting and recreating** the `Claude Code-credentials` item rather than updating it in
   place. Recreating the item **wipes its ACL** — which is exactly where the "Always Allow"
   grant lives. So every CLI token refresh (~daily) silently revokes our access, regardless
   of how stable/trusted *our* signing identity is. This is why attempts #2/#3 could never
   have stuck. An almost-identical project hit the same wall:
   [CodexBar #340](https://github.com/steipete/CodexBar/issues/340) ("oauth.claude entry is
   deleted and recreated … wipes the ACL on every token refresh"). **No macOS setting can
   survive this** — the grant is attached to an item another program keeps destroying.

2. **The "durable mirror" fix (#5) is actively dangerous here.** Anthropic's OAuth uses
   **refresh-token rotation with invalidation**: each refresh returns a new refresh token and
   invalidates the old one. Confirmed by Claude Code's own concurrency bugs
   ([#25609](https://github.com/anthropics/claude-code/issues/25609),
   [#54443](https://github.com/anthropics/claude-code/issues/54443)) where two processes
   sharing the credentials race and one is **forced to `/login`**. A widget that refreshed on
   its own would become a third racer and could log the user out of their real `claude` —
   plausibly *worse* than a daily prompt. The only race-free variant is to refresh `claude`'s
   single item **in place** (`SecItemUpdate`, never delete+recreate) and write the rotated
   token back, which hinges on whether macOS grants silent *modify* after one "Always Allow"
   (an untested unknown — a spike was drafted, then abandoned when the user picked #6).

## Attempt #6 — stop deferring; just ask for the password when access lapses

**User decision (Jun 15):** *"when the widget needs my password, it asks for it — no more of
this 'Right click → keychain access' business."* So we deliberately **revert the #4/#5 posture**
(silent-only background reads + a deferred authorize menu item) and let polls prompt directly.

### Changes

1. **`KeychainReader.read(allowInteraction:)`** — default flips to `true`. Interactive is now
   the normal path. Added a distinct `KeychainError.userCanceled` (maps `errSecUserCanceled`)
   so the engine can tell *"user dismissed the modal"* from *"couldn't show a modal"*
   (`.interactionRequired`: dark wake / suppressed silent read). The silent path (`false`) is
   retained only for the post-dismissal cooldown.
2. **`UsageEngine.pollOnce`** — all three reads (initial, post-refresh, post-401) read with
   `allowInteraction: mayPrompt`, where `mayPrompt` is true unless we're inside a cooldown.
   - `.userCanceled` → set `suppressPromptUntil = now + 15min` (silent reads only during the
     window, so we don't re-pop the modal every 2-min poll), publish `.stale`, keep last-good.
   - `.interactionRequired` → couldn't prompt now (dark wake / cooldown silent read); publish
     `.stale` and let the next poll prompt when the machine is awake.
   - A successful poll **and** a manual Refresh Now both clear `suppressPromptUntil`.
3. **Removed the deferred-auth surface entirely** — `EngineStatus.needsAuthorization`,
   `UsageEngine.authorizeNow()`, the `onAuthorize` hook, and the *"Authorize Keychain Access…"*
   right-click menu item. **Refresh Now** is now the user's "ask me for the password now"
   affordance (it clears the cooldown and forces an interactive poll).

### Why this is what the user wants (and its accepted cost)

- When the CLI's daily refresh wipes our grant, the next poll **pops the password / Always-Allow
  modal directly** — one click, polling resumes, no extra menu step. That is the explicit ask.
- **Accepted cost:** the prompt can appear more than once a day if the CLI refreshes its token
  more than once a day, and it can interrupt mid-work. The cooldown keeps a *dismissed* prompt
  from re-popping every 2 minutes (it backs off 15 min, or until Refresh Now). Dark-wake polls
  simply can't show the modal and quietly retry later, so they don't queue unanswerable prompts.
- The genuinely-durable options remain #5 (mirror + self-refresh — rejected: rotation race) and
  its in-place-`SecItemUpdate` variant (untested silent-modify unknown). #6 is the deliberate
  "prompt me, don't defer" choice, not a claim to have eliminated the prompt.

### Build / status

- Removed the throwaway `Spike0dInPlaceUpdate` (the in-place-modify feasibility probe) since
  that design was not chosen. `swift build` → **Build complete** (only the two pre-existing
  legacy-API deprecation warnings on the `SecKeychain*` / `kSecUseAuthenticationUI` calls).
- **Validation caveat:** the lapse only happens across a CLI refresh boundary, which can't be
  forced in one session. After `./scripts/make-app.sh release` + relaunch, confirm that when
  access lapses the widget shows the **password/Always-Allow modal directly** (no "Authorize"
  menu item), that clicking **Always Allow** resumes polling, and that dismissing it backs off
  rather than re-popping every poll.
