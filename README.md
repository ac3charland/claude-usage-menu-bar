# Claude Usage — macOS Menu Bar Widget

A small macOS menu bar app that shows your Claude plan usage at a glance: the current
**session (5-hour)** window and your **weekly (7-day)** window, drawn as a single
dual-ring icon with a translucent dropdown panel.

It reads the usage numbers from the same local OAuth token that
[Claude Code](https://claude.com/claude-code) already stores on your Mac — so there's
nothing to log in to and no API key to paste.

> [!WARNING]
> **Personal tool, unofficial.** It calls an undocumented Anthropic endpoint. See
> [Caveats](#caveats) before relying on it.

> [!NOTE]
> Inspired by Jeremy Ron King's article on [Composer](https://jeremyronking.com/blog/2026/17-remote-agent-experiment-composer). Huge thanks for Jeremy for his help in getting the Claude usage connection working!

## What the icon means

A single monochrome glyph encodes both windows; it adapts to light, dark, and tinted
menu bars automatically.

| Element | Meaning |
|---|---|
| **Outer ring** sweep | Session usage (0–100% of the 5-hour window), clockwise from 12 o'clock |
| **Inner disc** size | Weekly usage (0–100% of the 7-day window) |
| **Inner disc: solid** | Weekly usage is *on pace* (or behind) for the week |
| **Inner disc: hollow ring** | Weekly usage is *ahead of pace* — burning faster than the week is elapsing |
| **Whole icon dimmed** | Data is stale, offline, or unavailable (see the panel for why) |

Click the icon for a panel with exact percentages, the live "resets in…" countdown, and
an on-pace / ahead-of-pace readout for the week.

## Requirements

- **macOS 13 (Ventura) or later.**
- **[Claude Code](https://claude.com/claude-code) installed and logged in.** The widget
  reads Claude Code's `Claude Code-credentials` Keychain item to get a usage token — so
  you must have signed in with `claude` at least once. (A paid Claude plan is what
  populates the usage numbers.)
- The **`claude` CLI on a standard path** (`/usr/local/bin`, `/opt/homebrew/bin`,
  `~/.local/bin`, or `~/.claude/local`). The widget uses it to refresh the token when it
  nears expiry. If yours lives elsewhere, set `CLAUDE_BIN=/abs/path/to/claude`.
- **A Swift toolchain** to build (Xcode or the Swift command-line tools).

## Install

```sh
git clone <this-repo> claude-usage-menu-bar
cd claude-usage-menu-bar

# Build a real .app bundle (Dock-less menu bar agent)
./scripts/make-app.sh release

# Launch it
open "build/Claude Usage.app"
```

You will need to enter your Mac password in the dialog that appears. To prevent it from appearing every time, select "Always Allow".

The dual-ring icon appears in your menu bar within a couple of seconds (it paints from a
cached value immediately, then refreshes from a live poll).

To keep it around, drag/copy it into Applications:

```sh
cp -R "build/Claude Usage.app" /Applications/
```

**Open at Login is on by default** — on first launch the app installs a per-user
LaunchAgent (`~/Library/LaunchAgents/com.alexcharland.ClaudeUsageMenuBar.plist`) that
relaunches it at every login. No code signing required. Toggle it from the icon's
right-click menu; turning it off is remembered and never re-enabled. If you move the
`.app`, re-toggle it (or just relaunch) to repoint the LaunchAgent at the new path.

> **Gatekeeper:** this is an unsigned local build, so the *first* launch of a
> *downloaded* copy may need a right-click → **Open**. A build you compiled locally
> isn't quarantined and launches directly. Codesigning + notarizing with a Developer ID
> is only needed to clear that first-launch prompt and to share the build with others —
> launch-at-login works without it.

## Using it

- **Left-click** the icon → the usage panel (session + weekly, countdowns, pace).
- **Right-click** (or Control-click) the icon → menu:
  - **Refresh Now** — poll immediately.
  - **Update Frequency** — Fast (1 min) / Normal (2 min) / Relaxed (5 min).
  - **Open at Login** — start automatically after you log in.
  - **Quit**.

## How it works

```
KeychainReader → OAuth token  (Claude Code-credentials)
   → TokenRefresher (refreshes near expiry via `claude -p` ping)
   → UsagePoller   (GET https://api.anthropic.com/api/oauth/usage)
   → UsageSnapshot (session/weekly utilization, reset times, pace)
   → menu bar icon + SwiftUI popover
```

Polling backs off exponentially on errors (and harder on rate limits), forces an
immediate poll when the Mac wakes from sleep, and caches the last good reading to disk so
the icon paints instantly on the next launch.

### Privacy & security

- Your token **never leaves your machine**. It is used only to call Anthropic's usage
  endpoint directly.
- The token is **never written to disk or logs** — log lines and the on-disk cache are
  scrubbed of bearer tokens and `sk-ant-…` keys, and only non-secret usage numbers are
  cached.
- No telemetry, no analytics, no third-party servers.
- The app is **not sandboxed** — it needs to read Claude Code's Keychain item and spawn
  the `claude` CLI, both of which the App Sandbox forbids. (That's also why this isn't an
  App Store app.)

The first time it reads the Keychain item, macOS may prompt for access — choose
**Always Allow** so it doesn't ask on every launch.

## Caveats

- **Undocumented endpoint.** The usage API path, its request headers, and the token
  refresh flow are not public and **can change or break without notice**. If usage stops
  showing up after a Claude Code update, that's the likely cause.
- **macOS only**, and tightly coupled to how Claude Code stores its credentials in the
  macOS Keychain.
- **Not affiliated with or endorsed by Anthropic.** Provided as-is for personal use.

## Building & developing

```sh
swift build                       # all targets
.build/debug/ClaudeUsageDaemon    # headless engine, logs snapshots to stdout

# Visual QA: render design states to PNGs
.build/debug/ClaudeUsageApp --render-samples <dir>   # dual-ring icon contact sheet
.build/debug/ClaudeUsageApp --render-popover <dir>   # popover panel states
```

Phase 0 feasibility spikes live under `spikes/` for reference.
