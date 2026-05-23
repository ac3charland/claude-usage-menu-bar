# claude-usage-menu-bar

Personal macOS menu bar widget for Claude plan usage.

- Technical design + phase plan: `memory/claude-usage-widget-spec.md`
- Upstream pattern this piggy-backs on: `memory/claude-code-quota.md`

## Build & run

SwiftPM project. Build all targets:

```sh
swift build
```

Run any executable target:

```sh
.build/debug/Spike0aKeychain        # Phase 0 spike: cross-app Keychain read
.build/debug/Spike0bUsage           # Phase 0 spike: usage endpoint shape
.build/debug/Spike0cRefresh         # Phase 0 spike: passive CLI-ping observation
.build/debug/Spike0cForceRefresh    # Phase 0 spike: force a refresh via injected near-expiry
```

## Commit conventions

Use [Conventional Commits](https://www.conventionalcommits.org/). Common types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`. Scope is optional. Keep the subject line under ~70 chars.
