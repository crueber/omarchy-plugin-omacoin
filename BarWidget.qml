import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaCoin bar widget: the primary coin's USD price and a direction glyph.
//
// Left click opens the panel (coins tab: tracked list, trends, add/remove;
// settings tab: bar position, check frequency, and flat-band sliders),
// middle click cycles the primary through the tracked coins, right click
// forces a refresh. Coin state lives inline on this widget's shell.json
// entry (coins / primary / intervalMin / flatThresholdPct), written
// through bar.shell.updateEntryInline. Bar section is host layout
// (left/center/right), moved via pluginRegistry.moveBarWidget.
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
  // slot does not pop in with a layout shift 15s later.
  property bool initialFetch: true

  // Settings-derived state. QML's dependency tracking does not reliably
  // follow `settings` reads made inside the base class's setting() helper
  // (observed: bindings evaluated once at defaults and never refreshed
  // after the host injects settings), so these are plain properties
  // recomputed by applySettings() instead of bindings.
  property var trackedCoins: ["bitcoin", "ethereum"]
  property string primary: "bitcoin"
  property int intervalMin: 60
  property real flatThresholdPct: Model.FLAT_DEFAULT
  // Which bar.layout section this entry currently occupies. Not an
  // inline setting — the host stores it as which array the entry is in.
  property string barSection: ""

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
    if (JSON.stringify(coins) !== JSON.stringify(trackedCoins)) trackedCoins = coins
    if (prim !== primary) primary = prim
    if (iv !== intervalMin) intervalMin = iv
    if (flat !== flatThresholdPct) flatThresholdPct = flat
    refreshBarSection()
  }

  function currentBarSection() {
    var layout = root.bar && root.bar.barConfig ? root.bar.barConfig.layout : null
    return Model.barSectionOf(layout, root.moduleName)
  }

  function refreshBarSection() {
    var next = currentBarSection()
    if (next !== barSection) barSection = next
  }

  // Take the last published markets. Needed after a layout move: the
  // host destroys this widget and builds a new one that wins leadership
  // immediately, so the follower consume path never runs, and the
  // rate-limit gate would otherwise leave the bar blank for up to 60s.
  function hydrateFromPoll() {
    var shared = Model.pollSnapshot()
    if (!shared || shared.seq <= root.consumedSeq) return false
    root.consumedSeq = shared.seq
    root.marketRows = shared.rows
    root.lastUpdated = shared.updated ? new Date(shared.updated) : new Date(0)
    root.fetchError = shared.error || ""
    root.initialFetch = false
    return true
  }

  // Relocate this widget between bar.layout left/center/right. The host
  // rewrite destroys the live widget, so the panel is closed first and
  // the move is deferred one tick.
  function setBarSection(section) {
    var next = Model.clampSection(section)
    if (next === "") return
    if (next === currentBarSection()) return
    var registry = root.bar && root.bar.shell && root.bar.shell.pluginRegistry
    if (!registry || typeof registry.moveBarWidget !== "function") return
    root.close()
    Qt.callLater(function() {
      registry.moveBarWidget(root.moduleName, { section: next })
    })
  }

  // Suppress the tracked-coins refetch during startup: the poll timer's
  // triggeredOnStart already fetches, so a changed list would only queue
  // a redundant second call.
  property bool startupDone: false
  Component.onCompleted: {
    applySettings()
    hydrateFromPoll()
    startupDone = true
  }
  Component.onDestruction: Model.pollRelease(root)
  // Shortening the interval applies now, not after the old period
  // finishes (the gate keeps an early restart from double-fetching).
  onIntervalMinChanged: if (root.pollLeader) poll.restart()

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

  onTrackedCoinsChanged: if (startupDone) Qt.callLater(refresh)

  // Stay clickable even with no data yet (initial fetch in flight, error
  // state, or every coin removed) so the panel — the only way back to a
  // working state — stays reachable by mouse.
  visible: hasData || initialFetch || fetchError !== "" || trackedCoins.length === 0
  implicitWidth: contentRow.implicitWidth + Style.space(16)
  implicitHeight: barSize

  // ---- poll coordination ---------------------------------------------
  //
  // Leadership heartbeat + result fan-out. The leader claims once and then
  // only re-beats; everyone hydrates from the last publish whenever seq
  // moved (successes AND failures — a failed check keeps the old
  // timestamp, so comparing timestamps would hide errors from secondary
  // monitors). A dead leader (widget destroyed with the monitor it lived
  // on, or rebuilt by a bar-section move) is replaced within the 20s
  // window; the new instance hydrates so the bar keeps last prices.
  property int consumedSeq: 0
  Timer {
    id: pollCoordination
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      root.pollLeader = Model.pollClaim(root, Date.now())
      // Leaders used to skip consume because they were the publisher. A
      // freshly-elected leader after a widget recreate has empty rows and
      // must still take the last publish. hydrateFromPoll is a no-op when
      // seq has not moved, so a live leader does not clobber itself.
      hydrateFromPoll()
    }
  }

  Timer {
    id: poll
    interval: root.intervalMin * 60 * 1000
    repeat: true
    running: root.pollLeader
    triggeredOnStart: true
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
    function setBarSection(section: string): void { root.setBarSection(section) }
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
