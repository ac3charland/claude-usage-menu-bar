# Fix log: widget stopped authenticating entirely after the last fix

## Symptom

After `9dd8ee1` ("probe expiry silently so the CLI ping can't sit between two Keychain
prompts") shipped, the widget stopped authenticating altogether — no password prompt, no
usage numbers, just silence. Reported the same day the fix went out, so the obvious
suspect was the new probe/refresh branching in `UsageEngine.pollOnce`.

## What the log actually showed

`~/Library/Application Support/claude-usage-menu-bar/claude-usage.log`, from the poll
right after the fix was deployed (app relaunched 2026-07-19T16:37:02Z, right after the
`9dd8ee1` build):

```
2026-07-20T00:33:16Z INFO Token expires in -8min — refreshing via CLI ping
2026-07-20T00:33:22Z WARN CLI ping exited code=1 after 5.7s — token likely not refreshed
2026-07-20T00:33:22Z WARN Poll skipped: could not show Keychain prompt now — will retry next poll
...
2026-07-20T14:51:45Z ERROR Access token still expired after refresh attempt — skipping poll. Run `claude /login` to restore credentials.
2026-07-20T14:51:46Z WARN CLI ping exited code=1 after 1.3s — token likely not refreshed
```

Two things stand out:

1. **The CLI ping has failed with exit code 1 on every attempt since 00:33** — dozens of
   them, spanning a sleep/wake cycle, never once succeeding. That's not the double-prompt
   bug; the ping itself is dying.
2. **The decoded token expiry collapsed to ~0** (`Int(expiresAt.timeIntervalSince(now) /
   60)` prints as roughly `-29742651` minutes — back-computing that against each log
   timestamp lands on 1970-01-01T00:00:0Xish, i.e. `expiresAtMs ≈ 0`). The Keychain item's
   `mdat` (modified date) is `2026-07-20T00:33:20Z`, seconds after the first failed ping —
   so the CLI *did* rewrite the credentials item on that failed attempt, just with a dead
   token.

Neither of these is explained by the probe/branch logic in `9dd8ee1` — that commit only
changes *which* Keychain read is allowed to prompt, not what the CLI ping does or writes.

## Root cause (confirmed by reproducing directly)

`Sources/ClaudeUsageCore/TokenRefresher.swift` spawns `claude -p ping <nonce> --model
haiku` but never reads its `stderr` pipe — a failed ping only ever logged a bare exit
code. Running the exact same command by hand surfaced the real reason immediately:

```sh
$ /Users/alexcharland/.local/bin/claude -p "ping testdiag" --model haiku
Failed to authenticate: OAuth session expired and could not be refreshed
$ echo $?
1
```

The `claude` CLI's own OAuth refresh token is dead — rejected server-side, not something
a local retry can fix. No env-var override is in play (`CLAUDE_CODE_OAUTH_TOKEN` /
`ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` are all unset), and `~/.claude/history.jsonl`
shows no interactive `claude` usage in the failure window (23:00–03:00Z), so this wasn't a
refresh-token-rotation race against a concurrent terminal session either. This is a
genuine session expiry on the CLI side — coincidentally timed with the `9dd8ee1` deploy,
not caused by it.

The app's own handling of this state is already correct: `UsageEngine.pollOnce` detects
the expiry didn't advance and publishes `.refreshFailed`, which the UI renders as
*"Couldn't refresh login — open Claude Code"*. There's no code bug in the polling/prompt
logic — the fix is to re-authenticate the CLI.

## What actually fixes it

Run `claude /login` (or sign in again through Claude Code) to get a fresh refresh token
written to the `Claude Code-credentials` Keychain item. The widget polls that item
directly, so it picks up the new token on its next cycle with no restart needed.

## Change made — `Sources/ClaudeUsageCore/TokenRefresher.swift`

The only real bug here was diagnostic, not behavioral: a failed ping's `stderr` was piped
and then discarded, so this diagnosis required a manual repro instead of just reading the
log. `spawnPing()` now keeps the `stderr` pipe, and on a non-zero exit reads and logs its
trimmed contents alongside the exit code — e.g. the next occurrence will log `CLI ping
exited code=1 after 1.3s — token likely not refreshed — Failed to authenticate: OAuth
session expired and could not be refreshed` directly, no manual reproduction needed.

### Build / status

- `swift build` → **Build complete** (same two pre-existing legacy Keychain-API
  deprecation warnings as always).
- Validated the message text against a live failure (`claude -p ping` run by hand above);
  have not yet observed the *app* log the new stderr line, since that needs a fresh
  failure — the immediate fix for the reported issue is running `claude /login`.

---

## Attempt 2 — 2026-08-19: same symptom, and the attempt-1 logging never fired

### Symptom

Widget stuck on *"Couldn't refresh login — open Claude Code"*. The user opened Claude Code
(the desktop app), which changed nothing.

### What the log showed

Healthy right up to 13:53Z, then:

```
13:53:28Z INFO Token expires in -1min — refreshing via CLI ping
13:53:31Z WARN CLI ping exited code=1 after 3.0s — token likely not refreshed
13:53:31Z ERROR Access token still expired after refresh attempt — skipping poll.
14:10:14Z INFO Token expires in -29785810min — refreshing via CLI ping
```

The expiry collapsing to ~1970 is the attempt-1 signature again: `expiresAtMs == 0`.
Reading the Keychain item directly confirmed a state attempt 1 didn't name precisely:

```
accessToken:  len=0  (empty string, not absent)
refreshToken: len=0
expiresAt:    0
refreshTokenExpiresAt: 1787134452918  → 2026-08-19 05:14 local
mdat: 20260819135329Z                 → the exact second of the first failed ping
```

### Root cause

`refreshTokenExpiresAt` had elapsed at 05:14. At 13:53 the CLI tried to use the dead
refresh token, the server rejected it, and **the CLI rewrote its own Keychain item with
empty token strings** rather than deleting it. So the item still exists and still decodes —
`KeychainReader` returns credentials with empty strings and `expiresAt: 0`, and the engine
reports `.refreshFailed` forever. Only `claude /login` restores it; the desktop app and
claude.ai sessions never write this item (`mdat` stayed frozen at 13:53:29Z throughout).

Same underlying condition as attempt 1 (dead CLI OAuth session), reached by a different
route: the refresh token simply aged out rather than being revoked.

### Why attempt 1's diagnostic didn't help

Attempt 1 added stderr logging to `spawnPing()` precisely so this wouldn't need a manual
repro. The installed binary contained that code, yet every failure logged a bare exit code.
Reason: **the CLI prints the auth failure on stdout, not stderr.**

```
$ claude -p "ping diag2" --model haiku
--- STDOUT ---  Failed to authenticate: OAuth session expired and could not be refreshed
--- STDERR ---  Warning: no stdin data received in 3s, proceeding without it.
exit=1
```

`spawnPing()` set `proc.standardOutput = Pipe()` and never read it, logging only stderr —
which held nothing but an incidental stdin warning. So this diagnosis still took a manual
repro, exactly what attempt 1 was meant to prevent.

### Changes made

**1. `Sources/ClaudeUsageCore/TokenRefresher.swift` — capture what the CLI actually says**

- Read *both* stdout and stderr, stdout first, joined with `|` into one `failureDetail`
  line (newlines flattened, truncated at 500 chars so a chatty failure can't flood the log).
- Both pipes drain concurrently via `async let` + a `withCheckedContinuation` bridge, so a
  full pipe buffer can't wedge the wait loop. An intermediate version used
  `DispatchGroup.wait(timeout:)`, which is a blocking call in an async context (a warning
  today, an error in Swift 6) — worth noting because `swift build` **hid** that warning on
  an incremental run; it only appeared compiling the sources standalone.
- `proc.standardInput = FileHandle.nullDevice`. The CLI waits ~3s for stdin before giving
  up and warning about it; we never feed it anything. Ping time dropped 3.7s → 0.8s and the
  spurious warning is gone from the failure line.
- Drain setup moved *after* a successful `run()` — on a spawn failure the reads would
  otherwise block forever on pipes nothing will close.

**2. Blank credentials are now their own state, not `.refreshFailed`**

- `OAuthCredentials.isSignedOut` (`KeychainReader.swift`) — true when `accessToken` is
  empty, i.e. the CLI blanked the item.
- `EngineStatus.signedOut` (`EngineState.swift`) → *"Signed out — run claude /login in a
  terminal"*.
- `UsageEngine.handleSignedOut()`, called from **both** read paths in `pollOnce`: once on
  the silent probe (before any ping, since with no refreshToken to swap the ping can only
  fail — it was costing a `claude` spawn every poll) and once after the authoritative read
  (the ping can blank the item mid-poll).
- `.refreshFailed`'s text changed from "open Claude Code" to "run claude /login". Opening
  the desktop app cannot fix a dead CLI session — that advice sent the user down a dead end
  in this very report.

### Build / status

- `swift build` → **Build complete**, only the two pre-existing legacy-Keychain deprecation
  warnings. `swift test` → 6 tests, 0 failures.
- **Both changes verified live against the blanked Keychain**, rather than shipped on
  inspection as in attempt 1:
  - `ClaudeUsageDaemon` now logs `Keychain credentials are blank — the 'claude' CLI cleared
    them after a rejected refresh … Run 'claude /login' to sign in again.` and spawns **no**
    ping.
  - A standalone harness calling `TokenRefresher.forceRefresh()` logs `CLI ping exited
    code=1 after 0.8s — token likely not refreshed — Failed to authenticate: OAuth session
    expired and could not be refreshed`.
- Release bundle rebuilt and installed to `/Applications/Claude Usage.app`.
- **The underlying sign-in still has to be restored by the user: `claude` → `/login`.**
