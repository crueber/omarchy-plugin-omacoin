# AGENT.md — OmaCoin handoff

Crypto price tracker plugin (id `crueber.omacoin`) for the Omarchy shell.
Fetches from CoinGecko's public API via `curl` (Quickshell `Process`), no API key.
Current version **1.7.0** — Settings tab can move the widget between bar sections (left / center / right) via `pluginRegistry.moveBarWidget`. After a move the new instance hydrates from `pollSnapshot()` so last prices stay on the bar while the CoinGecko gate defers a refetch.

## Layout

- **Dev tree (source of truth):** `~/dev/git.packden.us/crueber/omarchy-plugin-omacoin/`
  - Remotes: `origin` = GitHub `crueber/omarchy-plugin-omacoin`, `forgejo` = `git.packden.us` mirror. **Push to both.**
- **Deployed copy:** `~/.config/omarchy/plugins/crueber.omacoin/` — keep in sync with `cp` of the four code files (`Model.js`, `BarWidget.qml`, `Panel.qml`, `manifest.json`) + `README.md`. Bump `manifest.json` version before each user-visible change.
- Files: `manifest.json` (schema + settings schema), `Model.js` (pure helpers + poll coordination), `BarWidget.qml` (bar slot: symbol, price, direction glyph), `Panel.qml` (two-tab popup: COINS / SETTINGS), `preview.png`, `README.md`, `LICENSE` (MIT).

## Marketplace submission — the active thread

- **Issue:** https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/2540 (submit-plugin template).
- State: `submission` + `validated` + `security-review-required`, OPEN, awaiting a maintainer's manual review → `approved-and-verified`.
- The validation bot pins the commit it checked (`b0bc450`, stale). It only re-runs on **issue-body edits**, not comments. Status updates so far went in as comments naming the current head (`4cbe0e7`).
- Security baseline flagged `remote-build` (the `git clone` install instructions) — expected noise, every Omarchy plugin triggers it, "no change necessarily required."
- Checklist in the issue body has **5** items (the live template has two more than the version you can fetch via the GitHub API — if validation fails, read the bot's comment for the exact missing item, tick it in the body, and it re-runs one item per pass).
- Watch for maintainer feedback; respond to any `needs-fixes` requests by fixing on `main`, then comment the new head commit.

## Architecture invariants (why the code looks the way it does)

1. **Single fetch choke point.** Every path that wants data (poll tick, right-click, panel open, `r` key, IPC, retry) funnels into `marketsFetch()`, which enforces the 60s CoinGecko rate-limit gate (`Model.pollGateOpen`). Gate-blocked requests are **deferred** via the `gateCatchup` timer (cooldown remaining + 500ms), never dropped.
2. **Leader election, single engine.** `Model.js` is `.pragma library` — one copy per QML engine. Verified: the host (`shell.qml` + `plugins/bar/Bar.qml` `Variants`) runs a single engine, so `pollState` is process-wide; exactly one widget instance polls, others consume. Fan-out is **seq-based** (`pollState.seq` increments on every publish including failures) so error states reach followers too.
3. **No bindings through `var` properties.** `hostWidget` (panel) and `settings` (widget) are vars; QML dependency tracking doesn't reliably follow reads through them. The panel pulls state via `syncFromHost()` on open + a 1s timer; the widget recomputes derived state in `applySettings()` with compare-before-assign.
4. **QVariantList trap.** Inline shell.json arrays cross into QML as QVariantList — `Array.isArray()` is FALSE. `Model.coinList()` duck-types (numeric `length`). Any new code receiving settings arrays must do the same. (This bug made every fresh shell start run on default coins.)
5. **Settings writes are loss-proof.** `updateSettings()` merges a `lastKnownSettings` snapshot (last host-injected entry) + current settings + changes, so a write during partial injection can't drop keys. Writes go through `bar.shell.updateEntryInline(moduleName, entry)` (clock widget pattern); state lives inline on the widget's shell.json entry — no separate files.
6. **Widget shape contract.** The host's `findPanelWidget()` requires `open`, `close`, AND `opened` on the widget or summon/hide/toggle (including the bar's own click) silently dead-ends while IPC still works. If clicks stop opening the panel, check for a lost/misnamed root-level function. `open()` re-injects the host into the panel every time (hot-reload can leave the panel holding a destroyed `hostWidget` — `typeof` guards pass on destroyed QObjects, so buttons silently no-op).
7. **Lazy panel Loader.** `panelLoader` latches `panelRequested` on first open and never unloads. `pendingOpen` carries an open that arrived before the load finished. `opened` is a plain read off the loader item — do NOT feed it back into `active` (binding loop; QML also rejects property-change handlers like `onIntervalMinChanged` inside a `Timer` — they belong on the object owning the property).
8. **Chart staleness.** Chart fetches carry a generation counter (`chartGen`); completions whose gen or `activeId` don't match the current primary are discarded. `refreshCharts()` waits out a pending completion (exitSeen/streamSeen) before respawning. The markets/chart Processes use a two-flag protocol (stdout stream + `exited` signal arrive in any order; `maybeFinish()` runs when both are in).
9. **Escalating retry backoff** (30/60/120/300s), curl stderr + exit code captured and mapped by `Model.describeFetchFailure()` (DNS vs HTTP 429 vs timeout). A 200 with an empty array is surfaced as "CoinGecko returned no matching coins" (config problem — excluded from the retry ladder) rather than silently hiding the bar.

## Operational notes (hard-won)

- **Restart required:** `omarchy restart shell` after deploying widget QML — hot reload ("Local plugin changed, reloading") replaces bar-widget components unreliably and caused several phantom bugs during debugging (stale panels, dead widgets). Always verify on a fresh restart; hot-reload artifacts vanish.
- **Never git-clone into the live plugin dir while the shell runs** — triggers a quickshell SIGSEGV reload race. Deploy with `cp`, or stop the shell first.
- Live state to check when things look wrong: `~/.config/omarchy/shell.json` (the widget's entry: coins/primary/intervalMin/flatThresholdPct), `journalctl --user --since "-X min" | grep -iE "crueber|omacoin"`, quickshell's own log in `/run/user/1000/quickshell/by-id/<id>/log.qslog` (binary-framed; use `strings`).
- IPC: `quickshell ipc -p /usr/share/omarchy/shell call crueber.omacoin <method> <arg>` — methods: open/close/show/hide/toggle/refresh/addCoin/removeCoin/setPrimary/setIntervalMin/setFlatThreshold/setBarSection. Note `omarchy-shell shell call` only routes to panel-kind plugins; bar widgets need the quickshell path or `omarchy-shell shell summon crueber.omacoin '{}'`.
- Verification without input synthesis (no ydotool/wtype on this box): IPC calls + `grim` screenshots + `tesseract` OCR + pixel sampling via `magick ... txt:-`. Tesseract mis-reads terminal text near the panel — always crop to the panel region (roughly x 890–1660, y 30–930 on this 1920×1080 single-monitor setup) before OCR.
- CoinGecko timing: rate limit is ~1 call/min. When testing fetch behavior, watch for real `curl` processes with `pgrep -x curl` (NOT `pgrep -f` — it matches your own watcher's command line).

## History in one line per commit

`ea875ed` initial · `c0a4814` drop %, tint price · `0730c51` direction glyph · `57c8423` flat band + sliders + tabs + review-1 fixes · `4de3c10` refresh button + cooldown · `1cf62d7` review-2 fixes (gate choke point, seq fan-out) · `c92040c` review-3 (defer gate-blocked, chartGen) · `2d16563` review-3 polish (drain-guard, dedupe queue) · `5f75ea7` marketplace prep · `77554cf`/`b0bc450` preview image · `26da763` search delegate fix · `366399b` QVariantList + snapshot writes + re-inject host · `2bd16b6` restore lost `close()` · `ac61621` AGENT.md handoff · `4cbe0e7` review-4 (normalize removeCoin input, intervalIndex fallback rung).
 · `1.6.0` marketplace review fixes (coin-id charset/length rules + COINS_MAX cap, producer-side 1MiB response cap via bash pipefail+head -c on all three fetches, parser-side bounds, safeString sanitization, Text.PlainText remote strings, normalized IPC setPrimary).
 · `1.7.0` Settings bar-position chips (left/center/right) calling `pluginRegistry.moveBarWidget`; IPC `setBarSection`; hydrate last prices after the host rebuilds the widget.

Four Ox Alpha reviews (via `opencode run -m opencode-go/ox-alpha-free` from the repo dir; OpenRouter's `stealth/ox-alpha` is blocked by the account's data policy — use the opencode-go endpoint). Round 3 verdict: **shippable**.

## Known non-issues / accepted quirks

- Blue-monochrome Aether theme: `Color.urgent` renders as the theme's soft blue-red `#3286b1`, not classic red. The up/down price colors are hardcoded `#7fc983`/`#d4776f` because Omarchy themes only ship neutral + urgent.
- Nerd Font PUA glyphs (e.g. `󰐐` refresh icon) don't fall back from Liberation Mono in some contexts — they render fine in the panel (bar uses the bar font family), but if a glyph ever shows as tofu, the bar font is the suspect.
- Sub-$0.0001 price formatting and a few other cosmetic nits from review round 3 were consciously left (noted in review thread).
