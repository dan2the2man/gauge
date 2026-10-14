# Gauge

A quiet Codex usage meter for the macOS menu bar and desktop.

**[Download Gauge.dmg](https://github.com/dan2the2man/gauge/releases/latest/download/Gauge.dmg)** · macOS 14+ · requires Codex (ChatGPT desktop app or Codex CLI), signed in.

Gauge reads only the current user's own Codex usage, locally. No accounts, servers or telemetry. If Codex isn't installed or signed in, it says so on first launch and in the menu.

- **Menu bar:** `37% left · 4d 13h` shows the percent **remaining** in the tightest window (weekly today). The text turns orange at 20% left and red at 5% left, and is dimmed when the data is stale.
- **Dropdown:** a weekly bar that drains as you use it, with the reset time, the 5-hour window (only if Codex reports one), banked-reset chips with expiry dates (orange when under 7 days), credits with average daily burn over the last week, an "As of" time, then the items Open Usage Settings… (opens `codex://settings/usage` and nothing else), Refresh (⌘R), Show Desktop Tile, Tile Ignores Clicks, Open at Login, Check for Updates…, and Quit.
- **Desktop tile:** a glass panel at desktop level. It sits below all windows, appears on all Spaces, and stays out of Cmd-Tab. Drag it anywhere; its position is remembered. Hovering shows the exact reset date and time and the exact as-of time.

## Data
- The only data source is a short-lived `codex app-server` child (stdio JSON-RPC). Gauge finds `codex` in the usual install locations (ChatGPT/Codex app bundles, Homebrew, `~/.local/bin`, npm/bun globals; override with `GAUGE_CODEX_PATH`) and sends `initialize` and `account/rateLimits/read`, and nothing else is allow-listed. After each read, Gauge terminates and reaps the child's whole process group.
- Gauge never sends a reset-consume call or any other write, and never reads `auth.json` or tokens.
- It polls every 5 min, every 1 min at 20% left or below, on wake, and when the menu opens (if the last read is more than 60 s old).
- If the app-server read fails, Gauge falls back to the newest `rate_limits` entry in `$CODEX_HOME/sessions` (default `~/.codex/sessions`) and marks it **Stale**. A live read older than 15 min is also marked stale. With no data at all, it shows "Unavailable", never 0.
- Credit burn comes from stored balance samples (time and balance only) in `~/Library/Application Support/Gauge/credits.json`, seeded from session logs. The log, with timings and usage numbers only, is in `gauge.log` in the same folder.

## Motion
Motion is quiet and uses short springs. All of it stays off with Reduce Motion, and none of it runs at idle.
- **Tile:** the percentage changes with a numeric text transition. The bar fills gently when the tile appears. There is one soft pulse when usage crosses into the 20% or 5% level. A small rotating refresh symbol shows only while a read is in flight (macOS 15+). Hovering reveals the exact times.
- **Reset chips:** they highlight on hover and give the exact expiry in a tooltip.
- **Dropdown:** it is static on purpose, because SwiftUI animations don't progress inside an NSMenu while it's tracking. The native menu items provide the press and highlight states.
- **Reduce Transparency:** the tile switches from Liquid Glass to an opaque material.

## Updates
Gauge uses [Sparkle 2](https://sparkle-project.org). It checks the appcast at the URL in `Info.plist` (`SUFeedURL`), and every update is verified against the EdDSA public key (`SUPublicEDKey`).

## Build
```sh
swift build -c release        # dev build (debug proof hooks are compiled out of release)
scripts/release.sh            # full release: sign, notarize, staple, DMG, appcast entry
```
`release.sh` signs with the first `Developer ID Application` identity in the keychain and notarizes with the `gauge-notary` notarytool profile. With no Developer ID it makes an ad-hoc build and prints a warning. The version comes from `VERSION`, and the build number is the git commit count.

The download page and `appcast.xml` are in `site/` (static).

## Debug builds
`swift build` (debug) keeps the proof hooks. `defaults write com.dohalloran.gauge debugSimulate left:15|logs|unavailable` simulates a state on the next refresh; delete the key afterward.

## License
MIT © Danny O'Halloran
