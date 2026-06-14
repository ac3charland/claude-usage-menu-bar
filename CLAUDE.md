# claude-usage-menu-bar

Personal macOS menu bar widget for Claude plan usage.

See `README.md` for what it does, install steps, and prerequisites. Detailed design
notes live in a local `memory/` folder that is intentionally not tracked in git.

## Build & run

SwiftPM project. Build all targets:

```sh
swift build
```

### The app (menu bar widget)

`ClaudeUsageApp` is the SwiftPM product for the menu bar agent (status item +
popover); it builds into a user-facing `Claude Usage.app` bundle. For a real run with
no Dock icon and launch-at-login support, build the bundle:

```sh
./scripts/make-app.sh release     # → "build/Claude Usage.app"
open "build/Claude Usage.app"
```

Running the bare binary works for quick checks but can't do launch-at-login (needs the
bundle). Left-click the icon for the popover; right-click for the menu (Refresh Now,
Update Frequency, Open at Login, Quit). Hidden QA modes render design states to PNGs:

```sh
.build/debug/ClaudeUsageApp --render-samples <dir>   # dual-ring icon contact sheet
.build/debug/ClaudeUsageApp --render-popover <dir>   # popover panel states
```

### Other targets

```sh
.build/debug/ClaudeUsageDaemon      # Phase 1 headless engine (logs snapshots to stdout)
.build/debug/Spike0aKeychain        # Phase 0 spike: cross-app Keychain read
.build/debug/Spike0bUsage           # Phase 0 spike: usage endpoint shape
.build/debug/Spike0cRefresh         # Phase 0 spike: passive CLI-ping observation
.build/debug/Spike0cForceRefresh    # Phase 0 spike: force a refresh via injected near-expiry
```

## Fixing issues

When asked to fix an issue, log the work in `docs/fixes/`:

- **Check for an existing doc first.** If one already covers this issue, **read it through
  before making any change** — it records what was already tried and why those attempts
  didn't stick. Don't repeat a failed approach.
- **Append your fix to that doc** as a new numbered attempt (symptom → root cause →
  change → why it should help → build/status). If no doc exists yet, create one
  (`docs/fixes/<kebab-case-slug>.md`).

## Commit conventions

Use [Conventional Commits](https://www.conventionalcommits.org/). Common types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`. Scope is optional. Keep the subject line under ~70 chars.

When work is complete, commit and push the changes by default, unless explicitly told otherwise.
