# Gauge: future providers (scoping only)

Status: proposal. No code exists for this yet. Gauge 0.2.x reads Codex only.

## Goal
Show the usage limits of more than one AI coding subscription in one menu bar item and tile. Claude is the first candidate (Claude Code and claude.ai Pro/Max plan limits). Gauge stays read-only, uses each tool's own login, and never handles credentials itself.

## Claude: where usage could come from (verify each before building)
Order of preference:

1. **The official local client, if it exposes limits.** This is the Codex pattern: launch the vendor's own CLI and ask it. Check whether current Claude Code has a machine-readable way to report plan usage (for example `/usage` or `/status`, or a JSON/headless output mode). If it only prints human-formatted text, scraping it is fragile; treat that as a fallback only.
2. **Local session logs.** Claude Code writes per-session JSONL transcripts under `~/.claude/projects/`. They carry token counts per message, but probably not the plan's percent-used or reset time. That's good for "tokens used today/this window", but weaker than Codex's `rate_limits` records. The community `ccusage` tool already derives estimates from these files; studying its approach is worthwhile (study it, don't depend on it).
3. **Anthropic Admin/Usage API.** This is for API-key organizations (usage and cost reports). It needs an admin key and covers API spend, not Pro/Max consumer plan limits. It's out of scope for the personal plan meter but could become a separate "API spend" provider.
4. **Not acceptable:** reading Claude's stored OAuth tokens from the keychain or config files, calling claude.ai's private web endpoints, or scraping the browser. These break the privacy promise and the terms of service.

Open: does Anthropic expose the 5-hour and weekly plan windows (percent and reset time) anywhere official on disk or through the CLI? This decides whether Claude gets a real meter or only an estimate.

## Provider abstraction
```swift
protocol UsageProvider {
    var id: String { get }                 // "codex", "claude"
    var displayName: String { get }
    func detect() -> ProviderStatus        // .missing, .signedOut, .ready (existence checks only)
    func read() async -> Result<Snapshot, ProviderError>   // live source
    func fallback() -> Snapshot?           // logs or estimate, marked stale/estimated
}
```
- `Snapshot` gains `provider` and `confidence` (`.reported` vs `.estimated`). Today's `UsageWindow`, credits and banked resets stay; not every provider fills every field.
- Move today's Codex code (`AppServer`, `SessionLogs`, `Parse.live`) behind `CodexProvider` with no behavior change. That's the first refactor, and it ships alone.
- `Store` holds `[providerID: Snapshot]` and polls each provider on its own cadence and back-off. A failure in one provider never blanks another.
- Each provider has its own allow-list of child-process methods or files, documented in the README "Data boundaries" section.
- The pure parsers stay Foundation-only so `scripts/selftest.sh` covers them with recorded fixtures.

## UI for multiple meters
- **Menu bar:** by default it shows the tightest window across enabled providers, with a small glyph or initial ("C 37%"). Settings can pin one provider or show both compactly.
- **Dropdown:** one section per provider (header row with name and status, then the bars). Estimated values are labeled "est."
- **Tile:** stacks one compact row per provider, or one tile per provider (each separately draggable and lockable). Start with stacked rows.
- **Settings:** a list of detected providers with on/off toggles. A provider that isn't detected shows how to install or sign in, never an error state.

## Privacy boundaries (unchanged principles)
- Only the current user's own usage, read through the vendor's own client or the user's own local files.
- No credential reads, no private web APIs, no telemetry, and no Gauge-operated servers. The only network traffic Gauge itself makes stays Sparkle updates.
- Each provider documents exactly which processes, methods and paths it touches before it ships.

## Open questions
1. Does Claude Code offer an official machine-readable plan-usage output? If not, would Anthropic consider it? (Biggest unknown.)
2. Is an estimated meter based on token counts and published plan allowances useful, or misleading? Is labeling it "est." enough?
3. Should the menu bar mix providers, or should each have its own status item?
4. What naming fits once Gauge isn't Codex-only (copy, site, bundle stays `com.dohalloran.gauge`)?
5. Other candidates after Claude: Cursor, GitHub Copilot, Gemini CLI. Each needs the same "official local source?" check.

## Suggested order
1. Refactor Codex behind `UsageProvider` (no user-visible change), with fixtures.
2. Research spike: Claude Code usage output (1 day), then decide between a reported and an estimated meter.
3. Multi-provider Store and dropdown sections, then the tile rows and the menu bar mode.
