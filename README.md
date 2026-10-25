# Gauge

A quiet Codex usage meter for the macOS menu bar and desktop.

**[Download Gauge.dmg](https://github.com/dan2the2man/gauge/releases/latest/download/Gauge.dmg)** · macOS 14+ on Apple Silicon (arm64 only) · requires Codex (ChatGPT desktop app or Codex CLI), signed in.

Gauge reads only the current user's own Codex usage, through the Codex install on your Mac. Gauge has no accounts or telemetry of its own; see **Data boundaries** for exactly what it touches. If Codex isn't installed or signed in, it says so on first launch and in the menu.

- **Menu bar:** Gauge uses one compact icon-sized status item so it coexists with crowded menu-bar apps. Hover the icon or open the popover for the exact percent **remaining** in the tightest window (weekly today) plus reset countdown; the icon turns orange at 20% left, red at 5% left, and dims when the data is stale.
- **Popover:** clicking the menu bar item opens a glass panel. The header shows the window and "As of" time, with Refresh (⌘R), Open Usage Settings (⌘,) and a gear menu (Open at Login, Check for Updates…, Quit ⌘Q). Below that are a large percent left with a bar (green above 25%, orange from 10 to 25%, red under 10%) and the reset time, then Banked resets (date pills, orange within 3 days) and Credits (with average daily burn) cards. The bottom row has a Desktop Tile toggle plus Lock, Ignore Clicks and Reset Position. Esc closes it.
- **Desktop tile:** a glass panel at desktop level. It sits below all windows, appears on all Spaces, and stays out of Cmd-Tab. Drag it anywhere; its position is remembered. Hovering shows the exact reset date and time and the exact as-of time.

## Data boundaries
- **Codex child process.** Gauge launches a short-lived `codex app-server` child (stdio JSON-RPC) and sends only `initialize`, `initialized` and `account/rateLimits/read` (an allow-list enforced in code). That child is Codex itself: it uses its own login and makes its own network requests to OpenAI to answer. Gauge never handles credentials directly. Gauge finds `codex` in the usual install locations (ChatGPT/Codex app bundles, Homebrew, `~/.local/bin`, npm/bun globals; override with `GAUGE_CODEX_PATH`). After each read it terminates and reaps the child's whole process group. It never sends a reset-consume call or any other write.
- **auth.json.** Gauge only checks whether `$CODEX_HOME/auth.json` exists, to explain a sign-in problem. It never opens it or reads tokens.
- **Session logs.** It reads Codex session logs under `$CODEX_HOME/sessions` (default `~/.codex/sessions`) for the fallback reading and credit history.
- **Local storage.** It stores credit balance samples and a diagnostics log in `~/Library/Application Support/Gauge/`.
- **Network from Gauge itself.** Only Sparkle: it fetches the update feed (`SUFeedURL`, `https://apps.dohalloran.com/gauge/appcast.xml`) and downloads updates from GitHub Releases. *Open Usage Settings…* may open ChatGPT's website in your browser.
- It polls every 5 min, every 1 min at 20% left or below, on wake, and when the menu opens (if the last read is more than 60 s old).
- If the app-server read fails, Gauge falls back to the newest `rate_limits` entry in `$CODEX_HOME/sessions` (default `~/.codex/sessions`) and marks it **Stale**. A live read older than 15 min is also marked stale. With no data at all, it shows "Unavailable", never 0.
- Credit burn comes from stored balance samples (time and balance only) in `~/Library/Application Support/Gauge/credits.json`, seeded from session logs. The log, with timings and usage numbers only, is in `gauge.log` in the same folder.

## Motion
Motion is quiet and uses short springs. All of it, including the freshness-line fade, stays off with Reduce Motion, and none of it runs at idle.
- **Tile:** the percentage changes with a numeric text transition. The bar fills gently when the tile appears. There is one soft pulse when usage crosses into the 20% or 5% level. A small rotating refresh symbol shows only while a read is in flight (macOS 15+). Hovering reveals the exact times.
- **Reset chips:** they highlight on hover and give the exact expiry in a tooltip.
- **Popover:** the percent uses a numeric transition and Refresh spins while a read is in flight. Both are off with Reduce Motion. Reduce Transparency gives it an opaque background, and Increase Contrast adds an outline.
- **Reduce Transparency:** the tile switches from Liquid Glass to an opaque material.

## Updates
Gauge uses [Sparkle 2](https://sparkle-project.org). It checks the appcast at the URL in `Info.plist` (`SUFeedURL`). The feed itself is EdDSA-signed (`SURequireSignedFeed`), and every download is verified against the EdDSA public key (`SUPublicEDKey`) before extraction (`SUVerifyUpdateBeforeExtraction`).

## Build
**Requirements:** an Apple Silicon Mac on macOS 14+, and Swift 5.9+ (Xcode or just the Command Line Tools: `xcode-select --install`). Builds are arm64 only.

**Dev build and run (no signing credentials needed):**
```sh
scripts/selftest.sh                    # parser / credit-history self-test
ALLOW_UNSIGNED=1 scripts/release.sh    # ad-hoc signed dist/Gauge.app + dist/Gauge.dmg
open dist/Gauge.app
```
The script also EdDSA-signs the update; without a Sparkle key in your keychain, stop after the app is built, or generate your own key with `.tools/sparkle/bin/generate_keys` and put its public key in `Info.plist`. For quick iteration, `swift build` then run `.build/debug/Gauge` (no bundle, so Sparkle and Open at Login are inactive).

**Release:** `scripts/release.sh` fails closed. It requires a `Developer ID Application` identity in the keychain and the `gauge-notary` notarytool profile; it builds from clean, strips debug symbols, bundles the Gauge and Sparkle license notices, signs with the hardened runtime, notarizes and staples the app and DMG, and writes an EdDSA-signed `dist/appcast.xml` to hand to the site host. The version comes from `VERSION`; the build number is the git commit count.

## Debug builds
`swift build` (debug) keeps the proof hooks. `defaults write com.dohalloran.gauge debugSimulate left:15|logs|unavailable` simulates a state on the next refresh; delete the key afterward.

## License
MIT © Danny O'Halloran
