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
