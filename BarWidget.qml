import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaCoin bar widget: the primary coin's USD price and a direction glyph.
//
// Left click opens the panel (coins tab: tracked list, trends, add/remove;
// settings tab: check frequency and flat-band sliders), middle click cycles
// the primary through the tracked coins, right click forces a refresh. All
// user state lives inline on this widget's shell.json entry (coins /
// primary / intervalMin / flatThresholdPct), written through
// bar.shell.updateEntryInline so every bar instance stays in sync.
//
// Polling: a bar surface exists per monitor, so several instances of this
// widget can be alive at once. Exactly one — the "leader", elected through
// shared library state in Model.js — runs the CoinGecko poll loop and
// publishes results to the others. That keeps the one-call-per-check
// contract regardless of monitor count.
BarWidget {
  id: root
  moduleName: "crueber.omacoin"

  // Normalized /coins/markets rows, ordered along the tracked-coin list.
  // Kept on failure so stale prices stay visible while a retry runs.
  property var marketRows: []

  property date lastUpdated: new Date(0)

  // Fetch health. Empty string when the last check succeeded.
  property string fetchError: ""
  property int fetchRetries: 0
  property bool fetchQueued: false
  // True from first launch until the first check finishes (success or
  // failure): the bar shows its "—" placeholder during the fetch so the
  // slot does not pop in with a layout shift 15s later. A cache hit clears
  // it immediately; an empty/partial cache keeps it set until the check.
  property bool initialFetch: true

  // Latest successful market map and when it was fetched. `lastMap` lets a
  // tracked-coin change reorder existing rows without a network call;
  // `cacheFetchedAt` is the disk cache's timestamp until a live check wins.
  property var lastMap: null
  property double cacheFetchedAt: 0
  property bool cacheLoadAttempted: false
  property bool settingsReady: false

  readonly property string cacheHome: {
    var xdg = Quickshell.env("XDG_CACHE_HOME")
    if (xdg) return xdg
    var home = Quickshell.env("HOME")
    return home ? home + "/.cache" : "/tmp"
  }
  readonly property string cacheDir: root.cacheHome + "/omacoin"
  readonly property string cachePath: root.cacheDir + "/markets.json"

  // Settings-derived state. QML's dependency tracking does not reliably
  // follow `settings` reads made inside the base class's setting() helper
  // (observed: bindings evaluated once at defaults and never refreshed
  // after the host injects settings), so these are plain properties
  // recomputed by applySettings() instead of bindings.
  property var trackedCoins: ["bitcoin", "ethereum"]
  property string primary: "bitcoin"
  property int intervalMin: 60
  property real flatThresholdPct: Model.FLAT_DEFAULT

  // True while this instance owns the module's single poll loop.
  property bool pollLeader: false

  readonly property var primaryRow: Model.rowById(marketRows, primary)
  readonly property bool hasData: primaryRow !== null

  function applySettings() {
    var coins = Model.coinList(setting("coins", ["bitcoin", "ethereum"]))
    var prim = Model.primaryId(coins, setting("primary", "bitcoin"))
    var iv = Model.clampInterval(setting("intervalMin", 60))
    var flat = Model.clampFlat(setting("flatThresholdPct", Model.FLAT_DEFAULT))
    // Compare before assigning: a fresh array's identity alone would notify
    // onTrackedCoinsChanged (and trigger a refetch) on every settings write
    // even when the list did not change.
    var coinsChanged = JSON.stringify(coins) !== JSON.stringify(trackedCoins)
    // Reorder before publishing the new list so the change handler sees the
    // already-filtered rows. A removed coin disappears immediately; a new
    // one stays missing until the check that follows.
    if (coinsChanged) {
      if (root.lastMap) root.marketRows = Model.orderRows(root.lastMap, coins)
      trackedCoins = coins
    }
    var primaryChanged = prim !== primary
    if (primaryChanged) primary = prim
    if (iv !== intervalMin) intervalMin = iv
    if (flat !== flatThresholdPct) flatThresholdPct = flat
    if (coinsChanged || primaryChanged) {
      // Keep the slot visible while the primary coin has no cached row yet
      // (new coin, partial cache, delisted id) so the placeholder and its
      // click target do not disappear during the check.
      if (root.primaryRow) root.initialFetch = false
      else if (root.fetchError === "") root.initialFetch = true
    }
  }
  // Suppress the tracked-coins refetch during startup: the poll timer's
  // first scheduled check already fetches, so a changed list would only
  // queue a redundant second call.
  property bool startupDone: false
  Component.onCompleted: {
    applySettings()
    root.loadCache(cacheFile.loaded ? cacheFile.text() : "")
    root.cacheLoadAttempted = true
    startupDone = true
    // The bar host injects `settings` after the widget is constructed (via
    // the Loader's injectProps), so wait one event-loop turn before letting
    // the leader choose a check time. Otherwise the first fetch could use
    // the default coin list instead of the user's.
    Qt.callLater(function() {
      root.settingsReady = true
      if (root.pollLeader) root.startPolling()
    })
  }
  Component.onDestruction: Model.pollRelease(root)
  // Shortening the interval applies now, not after the old period
  // finishes (the gate keeps an early restart from double-fetching).
  onIntervalMinChanged: if (root.pollLeader) root.scheduleNextPoll(root.nextPollDelayMs())

  // ---- local cache and poll scheduling
  //
  // A shell reload starts a new engine with empty Model.pollState. The disk
  // cache carries the last successful response across that boundary: paint
  // it immediately, then wait out whatever remains of the configured
  // interval instead of calling CoinGecko on every reload.
  function loadCache(raw) {
    var cached = Model.parseCache(raw, Date.now())
    if (!cached) return
    if (root.cacheFetchedAt >= cached.fetchedAt) return
    root.lastMap = cached.map
    root.cacheFetchedAt = cached.fetchedAt
    root.marketRows = Model.orderRows(cached.map, root.trackedCoins)
    root.lastUpdated = new Date(cached.fetchedAt)
    root.fetchError = ""
    root.initialFetch = !root.primaryRow
    Model.seedPollCache(cached.fetchedAt)
  }

  // Whether the latest map has a row for every tracked coin. Removing coins
  // or re-injecting the same settings after a reload is fully covered; a
  // newly added coin is not, so that change still checks immediately.
  function cacheCovers(coins) {
    if (!root.lastMap) return false
    var wanted = Model.coinList(coins)
    if (wanted.length === 0) return true
    for (var i = 0; i < wanted.length; i++)
      if (!root.lastMap[wanted[i]]) return false
    return true
  }

  function nextPollDelayMs() {
    var intervalMs = root.intervalMin * 60 * 1000
    var last = Model.pollState.lastSuccessMs
    if (last > 0) return Math.max(0, last + intervalMs - Date.now())
    return 0
  }

  function scheduleNextPoll(delayMs) {
    if (!root.pollLeader) return
    poll.interval = Math.max(1, Math.round(Number(delayMs) || 0))
    poll.restart()
  }

  function startPolling() {
    // Both are set a beat after construction (settings by the host, cache by
    // FileView); retry on the next turn rather than reading defaults.
    if (!root.cacheLoadAttempted || !root.settingsReady) {
      Qt.callLater(root.startPolling)
      return
    }
    var delay = root.nextPollDelayMs()
    // A fresh cache that covers the tracked list waits out the interval; a
    // missing, stale, or partial one checks now.
    if (!root.cacheCovers(root.trackedCoins)) delay = 0
    root.scheduleNextPoll(delay)
  }

  // What the bar paints: symbol, price, and a direction glyph. Moves within
  // the flat band (|24h| < flatThresholdPct, default ±0.5%) count as no
  // direction: plain foreground and "·". The glyph carries the same signal
  // for glanceability and stays readable even where the tint reads weakly.
  readonly property string labelSymbol: primaryRow ? primaryRow.symbol : ""
  readonly property string labelPrice: primaryRow && primaryRow.price !== null ? Model.formatUsd(primaryRow.price) : ""
  readonly property bool moveIsUp: primaryRow && primaryRow.change24h !== null && primaryRow.change24h >= root.flatThresholdPct
  readonly property bool moveIsDown: primaryRow && primaryRow.change24h !== null && primaryRow.change24h <= -root.flatThresholdPct
  readonly property string labelDirection: moveIsUp ? "▲" : (moveIsDown ? "▼" : "·")
  readonly property color priceColor: {
    var fg = root.bar ? root.bar.barForeground : Color.foreground
    if (root.moveIsUp) return "#7fc983"
    if (root.moveIsDown) return "#d4776f"
    return fg
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = root
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Fetches current markets. Does NOT forward to the panel: the panel's
  // own refresh() calls back into this (for its chart fetch), so
  // forwarding would recurse.
  function refresh() {
    if (root.pollLeader) {
      root.marketsFetch()
      return
    }
    // Ask the leader to re-check; fall back to fetching ourselves when
    // there is no live leader (single instance, or mid re-election).
    var leader = Model.pollLeaderInstance()
    if (leader && leader !== root) {
      try {
        if (typeof leader.refresh === "function") { leader.refresh(); return }
      } catch (e) {
        // Leader was destroyed; the heartbeat will re-elect shortly.
      }
    }
    root.marketsFetch()
  }

  // ---- shape contract for shell.summon/hide/toggle routing
  //
  // The panel Loader is lazy (heavy per-monitor tree): latched on the
  // first open request and never unloaded afterwards, so `opened` stays
  // a plain read off the loader item with no feedback into `active`
  // (which would be a binding loop). pendingOpen carries an open that
  // arrived before the load finished.
  property bool panelRequested: false
  property bool pendingOpen: false
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) {
      // Re-inject every open: a plugin hot-reload can leave this panel
      // bound to a destroyed host widget (the popup window outlives the
      // bar widget tree), which would make every button a silent no-op.
      injectPanel()
      panelLoader.item.open()
    } else if (!panelLoader.item) {
      pendingOpen = true
      panelRequested = true
    }
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
    else if (!panelLoader.item) {
      pendingOpen = true
      panelRequested = true
    }
  }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // ---- shell.json settings writes (clock's updateEntryInline pattern)
  //
  // The written entry is built from lastKnownSettings — a snapshot of the
  // most recent HOST-injected entry — merged with the current settings
  // and the changes. Building from root.settings alone let a write that
  // landed while settings were partially injected (hot reload, startup)
  // permanently drop keys; the snapshot makes that impossible.
  property var lastKnownSettings: null

  onSettingsChanged: {
    if (settings && typeof settings === "object") lastKnownSettings = settings
    applySettings()
  }

  function updateSettings(changes) {
    var entry = { id: root.moduleName }
    var sources = [lastKnownSettings, root.settings]
    for (var s = 0; s < sources.length; s++) {
      var src = sources[s]
      if (!src) continue
      for (var k in src) if (k !== "id" && entry[k] === undefined) entry[k] = src[k]
    }
    for (var c in changes) entry[c] = changes[c]
    // Applied locally first so the change is visible immediately; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    lastKnownSettings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function updateSetting(key, value) {
    var changes = {}
    changes[key] = value
    root.updateSettings(changes)
  }

  // Track a new coin. Normalized through coinList (lowercase, deduped) so
  // junk or mixed-case ids from IPC can never persist to shell.json and
  // defeat the dedupe ("Bitcoin" vs "bitcoin" would look distinct).
  function addCoin(id) {
    var next = Model.coinList(root.trackedCoins.concat([id]))
    if (next.length === root.trackedCoins.length) return
    root.updateSetting("coins", next)
  }

  // Untrack a coin. Normalized like addCoin so mixed-case ids from IPC
  // still match ("Bitcoin" must hit the stored "bitcoin"). The primary's
  // fallback is computed against the OLD primary and written in the same
  // entry — writing it after `coins` would compare against the
  // already-updated primary and never fire.
  function removeCoin(id) {
    var gone = String(id || "").replace(/^\s+|\s+$/g, "").toLowerCase()
    if (gone === "") return
    var current = root.trackedCoins.slice()
    var next = []
    for (var i = 0; i < current.length; i++) if (current[i] !== gone) next.push(current[i])
    if (next.length === current.length) return
    root.updateSettings({ coins: next, primary: Model.primaryId(next, root.primary) })
  }

  function cyclePrimary() {
    if (root.trackedCoins.length < 2) return
    var idx = root.trackedCoins.indexOf(root.primary)
    var next = root.trackedCoins[(idx + 1) % root.trackedCoins.length]
    if (next) root.updateSetting("primary", next)
  }

  onTrackedCoinsChanged: {
    if (!startupDone) return
    // A coin-list change the cache already covers (a removal, or the same
    // settings re-injected after a reload) needs no network call; just
    // re-arm the timer around the cached check time. A new coin is not
    // covered, so it still checks immediately.
    if (root.cacheCovers(root.trackedCoins)) {
      root.scheduleNextPoll(root.nextPollDelayMs())
      return
    }
    Qt.callLater(refresh)
  }

  // Stay clickable even with no data yet (initial fetch in flight, error
  // state, or every coin removed) so the panel — the only way back to a
  // working state — stays reachable by mouse.
  visible: hasData || initialFetch || fetchError !== "" || trackedCoins.length === 0
  implicitWidth: contentRow.implicitWidth + Style.space(16)
  implicitHeight: barSize

  // ---- poll coordination ---------------------------------------------
  //
  // Leadership heartbeat + result fan-out. The leader claims once and then
  // only re-beats; everyone else consumes published state whenever the
  // publish sequence moved (successes AND failures — a failed check keeps
  // the old timestamp, so comparing timestamps would hide errors from
  // secondary monitors). A dead leader (widget destroyed with the monitor
  // it lived on) stops beating and is replaced within the 20s window.
  property int consumedSeq: 0
  Timer {
    id: pollCoordination
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      var wasLeader = root.pollLeader
      root.pollLeader = Model.pollClaim(root, Date.now())
      if (root.pollLeader && !wasLeader) root.startPolling()
      if (root.pollLeader || wasLeader) return
      var shared = Model.pollConsume(root)
      if (shared && shared.seq > root.consumedSeq) {
        root.consumedSeq = shared.seq
        root.marketRows = shared.rows
        root.lastUpdated = new Date(shared.updated)
        root.fetchError = shared.error
        root.initialFetch = false
      }
    }
  }

  // One-shot, re-armed by scheduleNextPoll() after each result and whenever
  // leadership moves. A one-shot timer lets a cache hit wait out the rest of
  // the interval instead of firing a fixed cadence from process start.
  Timer {
    id: poll
    interval: Math.max(60000, root.intervalMin * 60 * 1000)
    repeat: false
    running: root.pollLeader
    triggeredOnStart: false
    onTriggered: root.marketsFetch()
  }

  // Bounded retry after a failed check (network down, rate limited,
  // CoinGecko error) with escalating backoff. Retries give up after four
  // attempts and surface the failure in the panel until the next
  // scheduled check.
  Timer {
    id: retryTimer
    onTriggered: root.marketsFetch()
  }

  // A fetch that arrived inside the rate-limit window is deferred, not
  // dropped: the caller wanted fresh data for a reason (coin list
  // changed, leader handover, manual refresh). One armed catch-up per
  // instance, deduped by Timer.restart() semantics.
  Timer {
    id: gateCatchup
    onTriggered: root.refresh()
  }

  // Every path that wants fresh data lands here (poll tick, manual
  // refresh from the panel / right click / "r", IPC, retry) so the
  // rate-limit cooldown is enforced once, at the choke point, instead of
  // per caller. Stale-but-usable data is always preferable to a 429 —
  // but a blocked request is deferred past the gate rather than
  // discarded, so a coin-list change never waits a full interval.
  function marketsFetch() {
    if (!Model.pollGateOpen(Date.now())) {
      gateCatchup.interval = Math.max(1000, Model.pollCooldownRemaining(Date.now()) * 1000 + 500)
      gateCatchup.restart()
      return
    }
    if (marketsProc.running) {
      // A fetch is already in flight (e.g. refresh raced the poll tick).
      // Queue one re-run — but only when the coin list actually changed:
      // a broadcast refresh hitting the leader N times must not become N
      // CoinGecko calls once the gate opens.
      var want = root.trackedCoins.join(",")
      if (want !== marketsProc.requestedIds) root.fetchQueued = true
      return
    }
    var ids = root.trackedCoins.join(",")
    if (ids === "") {
      root.fetchQueued = false
      return
    }
    marketsProc.requestedIds = ids
    // Producer-side byte cap: curl pipes through `head -c`, so no more
    // than RESPONSE_MAX_BYTES ever reaches the shell's memory. `pipefail`
    // keeps curl's own exit code (DNS/429/timeout diagnostics intact); an
    // over-cap stream surfaces as a failed check. The URL is single-quoted
    // for the shell: ids are already charset-filtered by COIN_ID_RE, and
    // Model.shellSafeUrl %-encodes any remaining quote characters.
    marketsProc.command = ["bash", "-o", "pipefail", "-c",
      "curl -fsS --compressed --max-time 15 '" + Model.shellSafeUrl(
        "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=" + encodeURIComponent(ids)
        + "&order=market_cap_desc&sparkline=true&price_change_percentage=1h,24h,7d")
      + "' | head -c " + Model.RESPONSE_MAX_BYTES]
    marketsProc.running = true
  }

  // One call per check regardless of how many coins are tracked. The
  // exit code and stderr are captured so a failure says WHY it failed
  // (DNS vs rate limit vs timeout) instead of a generic "check failed".
  // stdout, stderr and the exit signal can arrive in any order, so the
  // result is processed once both the stream and the exit are in.
  Process {
    id: marketsProc
    property string requestedIds: ""
    property string stdoutText: ""
    property string stderrText: ""
    property int lastExitCode: 0
    property bool exitSeen: false
    property bool streamSeen: false

    function maybeFinish() {
      if (!exitSeen || !streamSeen) return
      exitSeen = false
      streamSeen = false
      var ok = lastExitCode === 0
      var map = ok ? Model.parseMarkets(stdoutText) : null
      // A 200 with an empty array (all tracked ids unknown — typo'd
      // hand-edited shell.json, delisted coins) is NOT a success: the
      // bar would otherwise hide with no error to show for it.
      if (map && Object.keys(map).length === 0) map = null
      if (map) {
        root.fetchRetries = 0
        root.fetchError = ""
        root.marketRows = Model.orderRows(map, root.trackedCoins)
        root.lastUpdated = new Date()
        root.lastMap = map
        root.cacheFetchedAt = root.lastUpdated.getTime()
        Model.seedPollCache(root.cacheFetchedAt)
        // Store the raw body, not the parsed rows: a reload reparses it with
        // the same bounds and sanitizing as a live response.
        cacheFile.setText(Model.serializeCache(stdoutText, root.cacheFetchedAt))
      } else if (lastExitCode === 0 && stdoutText.length >= Model.RESPONSE_MAX_BYTES) {
        // Exit 0 with a body at the cap: the document was truncated
        // mid-stream (narrow pipe/timing window — over-cap streams
        // normally die as SIGPIPE/141 instead). Not a config problem;
        // let the retry ladder run.
        root.fetchError = "response too large"
      } else if (lastExitCode === 0 && stdoutText.replace(/\s+/g, "") !== "") {
        root.fetchError = "CoinGecko returned no matching coins"
      } else {
        root.fetchError = Model.describeFetchFailure(lastExitCode, stderrText)
      }
      root.initialFetch = false
      Model.pollPublish(root, root.marketRows, root.lastUpdated.getTime(), root.fetchError, !!map)
      // No-matching-coins is a configuration problem, not a network one —
      // retrying it just burns the rate limit.
      var configProblem = root.fetchError === "CoinGecko returned no matching coins"
      if (!map && !configProblem && root.trackedCoins.length > 0 && root.fetchRetries < 4) {
        root.fetchRetries++
        retryTimer.interval = Model.retryBackoffMs(root.fetchRetries)
        retryTimer.restart()
      }
      // Re-arm the one-shot poll: success waits the configured interval from
      // its own timestamp; failure waits it from now, leaving the shorter
      // retry ladder to retryTimer.
      if (root.pollLeader) root.scheduleNextPoll(root.intervalMin * 60 * 1000)
      stdoutText = ""
      stderrText = ""
      if (root.fetchQueued) {
        root.fetchQueued = false
        Qt.callLater(root.marketsFetch)
      }
    }

    onExited: function(exitCode) {
      lastExitCode = exitCode
      exitSeen = true
      maybeFinish()
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        marketsProc.stdoutText = text
        marketsProc.streamSeen = true
        marketsProc.maybeFinish()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: marketsProc.stderrText = text
    }
  }

  // Disk cache of the last successful markets response. Read synchronously
  // at startup (blockLoading), so the bar can paint a cached price before the
  // first frame; a reload then waits out the rest of the interval instead of
  // polling CoinGecko again. Writes are atomic and only happen on success.
  FileView {
    id: cacheFile
    path: root.cachePath
    blockLoading: true
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: if (root.startupDone) root.loadCache(text())
    onLoadFailed: if (root.startupDone) root.loadCache("")
  }

  // FileView's writer needs the parent directory to exist. `mkdir -p` is
  // idempotent and finishes long before the first fetch can succeed.
  Process {
    id: cacheDirProc
    command: ["mkdir", "-p", root.cacheDir]
    running: true
  }

  // The panel tree (Canvas, search process, key catcher) is heavy and a
  // bar surface exists per monitor — instantiated only on first open and
  // kept afterwards (open() must stay synchronous for summon routing).
  Loader {
    id: panelLoader
    // panelRequested never resets once set: load-once, keep-forever.
    // open() sets it when the item is missing; onLoaded forwards the
    // pending open into the freshly built panel.
    active: root.panelRequested
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
      if (root.pendingOpen && panelLoader.item && panelLoader.item.open)
        Qt.callLater(function() { panelLoader.item.open() })
      root.pendingOpen = false
    }
  }

  IpcHandler {
    target: "crueber.omacoin"

    // Routed through broadcast so every monitor's instance opens/closes
    // together instead of only the one that happened to win the IPC
    // target registration.
    function open(): void { root.broadcast("open") }
    function close(): void { root.broadcast("close") }
    function show(): void { root.broadcast("open") }
    function hide(): void { root.broadcast("close") }
    function toggle(): void { root.broadcast("togglePanel") }
    function refresh(): void { root.broadcast("refresh") }

    // Scriptable state surface (same mutations the popup makes), with the
    // same clamps the popup applies.
    function addCoin(id: string): void { root.addCoin(id) }
    function removeCoin(id: string): void { root.removeCoin(id) }
    // Normalized against the tracked list: junk ids from IPC cannot reach
    // shell.json as `primary` (invalid values fall back to coins[0]).
    function setPrimary(id: string): void { root.updateSetting("primary", Model.primaryId(root.trackedCoins, id)) }
    function setIntervalMin(minutes: int): void { root.updateSetting("intervalMin", Model.clampInterval(minutes)) }
    function setFlatThreshold(pct: real): void { root.updateSetting("flatThresholdPct", Model.clampFlat(pct)) }
  }

  Row {
    id: contentRow
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      visible: !root.vertical && root.hasData
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelSymbol
      color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.3)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      textFormat: Text.PlainText
    }

    Text {
      visible: !root.vertical && root.hasData
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelPrice
      color: root.priceColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Text {
      visible: !root.vertical && root.hasData
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelDirection
      color: root.priceColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // Placeholder while there is nothing to show (fetch error, or every
    // coin removed) so the widget keeps an affordance to click.
    Text {
      visible: !root.hasData
      anchors.verticalCenter: parent.verticalCenter
      text: "—"
      color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.5)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    // Vertical bars get the compact form: symbol over price.
    Column {
      visible: root.vertical
      anchors.centerIn: parent
      spacing: 0

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.labelSymbol
        textFormat: Text.PlainText
        color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.3)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.hasData ? (root.labelPrice + " " + root.labelDirection) : "—"
        color: root.priceColor
        textFormat: Text.PlainText
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) root.cyclePrimary()
      else if (mouse.button === Qt.RightButton) root.refresh()
      else root.togglePanel()
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasData ? tooltipText() : "OmaCoin · click for details")
    onExited: if (root.bar) root.bar.hideTooltip(root)

    function tooltipText() {
      var bits = [root.primaryRow.name]
      if (root.primaryRow.change24h !== null) bits.push("24h " + Model.formatPct(root.primaryRow.change24h))
      if (root.fetchError !== "") bits.push(root.fetchError)
      if (root.lastUpdated.getTime() > 0) bits.push("updated " + Model.formatTime(root.lastUpdated))
      bits.push("click for details · middle: next coin")
      return bits.join(" · ")
    }
  }
}
