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

## Attempt 2 — 2026-09-25: it wasn't a "genuine" expiry; the widget killed its own refresh across sleep

### Symptom

Widget (run from `/Applications`) showed *"Couldn't refresh login — open Claude Code"*
the day after the CLU-4 merge. The merge was a red herring: it doesn't touch auth, and
the app had polled fine for ~14h after it was installed.

### What the evidence showed

The `Claude Code-credentials` Keychain item had been blanked — `accessToken` and
`refreshToken` both empty, `expiresAt: 0` (the "expiry ≈ 1970" signature from attempt 1),
item `mdat` `2026-09-25T16:24:15Z`. Cross-referencing the app log with `pmset -g log`
(lid closed, laptop cycling through short DarkWake maintenance windows):

| UTC | Event |
|---|---|
| 14:33:46 | 6s DarkWake. Regular poll: token expires in 24min → CLI ping spawned. Machine re-slept ~6s later **with the ping mid-flight**. |
| 16:02:12 | Next DarkWake. The ping watchdog's deadline was wall-clock (`Date()`), so the 88min of sleep counted and it **SIGTERMed the ping immediately** (exit 143, "5306.2s"). |
| 16:12:04 | 17s DarkWake. Token now −73min → second ping. Machine slept again mid-ping. |
| 16:24:14 | DarkWake → watchdog killed ping #2 on the spot. |
| 16:24:15 | Keychain item rewritten with empty tokens. |

`~/.claude/history.jsonl` shows no interactive Claude Code use 13:00–18:00Z, so the
widget's pings were the only actor. Most likely mechanism (consistent with all of the
above, not provable from outside): ping #1 sent the refresh request, the server rotated
the refresh token (invalidating the old one), and the process was frozen/killed before
the CLI persisted the new one. Ping #2 then presented the dead refresh token, was
rejected, and the CLI cleared the credentials. Attempt 1's incident has the same shape
(`mdat` seconds after a failed ping), so it was probably this bug too rather than a
coincidental server-side expiry.

### Root cause

Two widget behaviours combined:

1. **Polling (and pinging) during DarkWake.** The poll timer fires whenever the process
   is resumed, including multi-second maintenance wakes where the machine re-sleeps
   almost immediately — the worst possible time to start a token rotation.
2. **Wall-clock ping timeout.** Sleep time counted toward the 30s deadline, so a ping
   that straddled sleep was killed the instant the machine woke — exactly when its
   network request could finally complete and the new token be saved.

### Change

- `UsageEngine`: track system sleep with `NSWorkspace.willSleepNotification` →
  `systemAsleep = true`, cleared by `didWakeNotification` (plus `screensDidWake` as a
  backstop). DarkWake never posts `didWake`, so `pollOnce` returns early (no failure, no
  back-off) for the whole lid-closed period. The existing full-wake observer polls
  immediately when the user comes back. Also covers the network-reconnect trigger, which
  fired during DarkWake at 16:12:09.
- `TokenRefresher.spawnPing`: deadline measured on `ProcessInfo.systemUptime` (stops
  during sleep), so a ping gets 30 *awake* seconds and resumes/finishes after a sleep
  instead of being killed on wake. The log line now shows both clocks when they diverge
  (`… after 3.1s awake (5306s wall — system slept)`).
- `TokenRefresher.spawnPing`: wraps the ping in a `ProcessInfo` activity with
  `.idleSystemSleepDisabled`, so idle sleep can't interrupt a rotation in progress. (A lid
  close still forces sleep; the awake-time deadline covers that case.)

### Why it should help

A ping can no longer start in a window where the machine is about to re-sleep, and a
ping interrupted by a forced sleep is allowed to finish instead of being SIGTERMed right
as it resumes. Both paths that could strand a rotated refresh token are closed.

### Build / status

- `swift build` → Build complete; `swift test` → 92 tests, 0 failures.
- Rebuilt and installed `/Applications/Claude Usage.app`; after the user's `claude /login`
  the widget polls normally (HTTP 200 at 18:22:52Z).
- Not yet observed: a lid-closed night with the new build. Things to check in the log:
  `System going to sleep — pausing polls`, `skipping poll until full wake` during
  DarkWakes, and no `CLI ping` lines between them.
