# AI Usage Widget

Windows tray widget that shows AI subscription usage (session / daily / weekly) for Claude, Codex, and Grok Bot in a compact always-on-top panel.

## Description

A small Rust + Slint status monitor for the Windows tray. It reads local provider logins at fetch time, refreshes on a timer, and shows percent bars plus plan badges without a browser UI.

## Installation

1. Download `AIUsageWidget-Setup.exe` or `AIUsageWidget-portable.zip` from [Releases](https://github.com/MoshikoKar/AIUsageWidget/releases/latest).
2. Verify SHA-256 against `SHA256SUMS.txt` in the same release (`certutil -hashfile <file> SHA256`).
3. SmartScreen may warn on unsigned builds - that is expected until a code-signing cert is used.

Portable: keep `portable.txt` next to the exe; config and history live in `.\data\`. Installed: `%APPDATA%\AIUsageWidget\`.

## Usage

- Drag the header to move; **X** hides to the tray (does not quit).
- Tray: Show/Hide, Always on top, Lock position, Start with Windows, Edit config, Reload config, Check for updates, Quit.
- Quit only from the tray menu (or updater / reload restart).

Columns are session, daily, and weekly (weekly falls back to a monthly window when weekly is missing).

## Features

- Compact table UI with service logos, plan badges, and thin percent bars
- Tray icon with Show/Hide, always-on-top, lock position, and autostart
- Local credential read at fetch time (not stored by the app)
- Silent update check and toast on PROBLEM / recovery
- Portable and installed layouts

## Config (`config.json`)

| Key | Default | Notes |
|---|---|---|
| `services` | Claude, Codex, Grok Bot | `id`, `name`, `type` (`claude`/`codex`/`grokbot`/`manual`), `enabled`, `color`, optional `manual` percents |
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

Credentials are read from local Claude Code / Codex / Grok Bot logins at fetch time and sent only to that provider. They are not stored by this app.

## Tech Stack

- Rust + Slint
- PowerShell fetch script (`scripts/fetch.ps1`)
- Inno Setup installer

## Develop

```powershell
cargo test --release
cargo run --release
# or package:
.\build.ps1 -SkipSetup
```

`scripts/fetch.ps1` must sit next to the exe (dev uses the repo `scripts/` folder).

Regenerate icons and Teknic logo derivatives:

```powershell
python assets/make_icon.py
```

## Release

1. Add a `## [x.y.z]` section to `CHANGELOG.md`.
2. With a clean tree and user go-ahead: `.\release.ps1 -Version 0.1.0` (or `-Bump patch`).
3. CI builds `AIUsageWidget-Setup.exe`, `AIUsageWidget-portable.zip`, and `SHA256SUMS.txt`.

## License

MIT - see the `LICENSE` file for details.
