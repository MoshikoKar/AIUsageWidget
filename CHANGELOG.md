# Changelog

## [0.2.0] - 2026-11-14

- Hover SESSION / DAILY / WEEKLY headers or percent cells to see when each window resets.
- Good usage meters use Teknic brand cyan instead of green; warn/bad colors unchanged.
- Normalize Claude logo sizing to match other service icons.
- Accept numeric or string reset timestamps from providers in fetch and deserialization.

## [0.1.0] - 2026-11-14

- First release as a Windows tray widget (Rust + Slint), following the Windows Widget Standard.
- Compact session / daily / weekly table with service logos, percent bars, and Teknic branding.
- Frameless always-on-top panel, tray quit, single instance, portable mode, verified GitHub updates.
- Usage for Claude, Codex, and Grok Bot (plus manual entries) via `scripts/fetch.ps1`.
- Derived daily usage from weekly/monthly baselines; warn/bad thresholds in config.
