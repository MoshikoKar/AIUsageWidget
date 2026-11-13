# AI Usage Widget

Windows tray widget that shows AI subscription usage (session / daily / weekly / monthly) for Claude, Codex, Grok Bot, and optional Cursor or manual entries.

## Stack

**Rust + Slint (A)** - tiny always-visible status monitor with tray, aligned with the Windows Widget Standard. Chosen over Tauri (no web UI needed) and raw Win32 (layout/text would be heavier for multi-column usage cards).

## Install

1. Download `AIUsageWidget-Setup.exe` or `AIUsageWidget-portable.zip` from [Releases](https://github.com/MoshikoKar/AIUsageWidget/releases/latest).
2. Verify SHA-256 against `SHA256SUMS.txt` in the same release (`certutil -hashfile <file> SHA256`).
3. SmartScreen may warn on unsigned builds - that is expected until a code-signing cert is used.

Portable: keep `portable.txt` next to the exe; config and history live in `.\data\`. Installed: `%APPDATA%\AIUsageWidget\`.

## Usage

- Drag the header to move; **X** hides to the tray (does not quit).
- Tray: Show/Hide, Always on top, Lock position, Start with Windows, Edit config, Reload config, Check for updates, Quit.
- Quit only from the tray menu (or updater / reload restart).

## Config (`config.json`)

| Key | Default | Notes |
|---|---|---|
| `services` | Claude, Codex, Grok Bot | `id`, `name`, `type` (`claude`/`codex`/`grokbot`/`cursor`/`manual`), `enabled`, `color`, optional `manual` percents |
| `refresh_minutes` | `5` | How often to re-fetch |
| `warn_pct` / `bad_pct` | `70` / `90` | Status thresholds |
| `demo` | `false` | Fake numbers, no network |
| `always_on_top` | `true` | Persisted |
| `locked` | `false` | Disables header drag |
| `check_updates` | `true` | Silent check shortly after start |
| `update_channel` | `stable` | or `beta` |
| `notifications` | `true` | Toast on PROBLEM / recovery |
| `x` / `y` | first run `40,40` | Restored if still on a monitor |

Normalize: blank ids dropped, ids de-duplicated, max 12 services, thresholds clamped.

Credentials are read from local Claude Code / Codex / Grok Bot / Cursor logins at fetch time and sent only to that provider. They are not stored by this app.

## Develop

```powershell
cargo test --release
cargo run --release
# or package:
.\build.ps1 -SkipSetup
```

`scripts/fetch.ps1` must sit next to the exe (dev uses the repo `scripts/` folder).

## Release

1. Add a `## [x.y.z]` section to `CHANGELOG.md`.
2. With a clean tree and user go-ahead: `.\release.ps1 -Version 0.1.0` (or `-Bump patch`).
3. CI builds `AIUsageWidget-Setup.exe`, `AIUsageWidget-portable.zip`, and `SHA256SUMS.txt`.
