import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaCoin detail popup, split across two tabs:
//
//   COINS    primary-coin hero with a 1h/1d/1w trend line, the tracked-coin
//            list (price, volume, 1h/24h/7d change, make-primary and remove
//            actions), and CoinGecko search for adding coins
//   SETTINGS bar position (left / center / right), check-frequency slider
//            (1 minute → 1 day over CoinGecko's ladder), and the
//            flat-band slider (0–5%, 0.1% steps)
//
// All mutations go through the host BarWidget so they land in the widget's
// shell.json entry and every bar instance syncs.
Panel {
  id: root
  moduleName: "crueber.omacoin"
  ipcTarget: "crueber.omacoin"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- popup state
  property string activeTab: "coins" // "coins" | "settings"
  property string trendRange: "1d"   // "1h" | "1d" | "1w"
  property var chartPrices: []       // market_chart (5-minutely, last day) for the primary
  property string chartError: ""     // why the trend chart is unavailable, when it is
  property var searchResults: []
  // Tracked coins that have no market row yet — added moments ago, or
  // added while the rate-limit gate deferred their first fetch. Shown as
  // placeholder rows so adding a coin always has immediate feedback.
  readonly property var pendingCoins: {
    var have = {}
    for (var i = 0; i < rows.length; i++) have[rows[i].id] = true
    var out = []
    for (var j = 0; j < trackedCoins.length; j++)
      if (!have[trackedCoins[j]]) out.push(trackedCoins[j])
    return out
  }

  // Slider drag previews: -1 means "not dragging, show the committed
  // value". Committed only on release so shell.json is written once per
  // adjustment rather than per drag tick.
  property int freqPreview: -1
  property real flatPreview: -1

  // ---- host state, pulled from the BarWidget
  //
  // `hostWidget` is a var, so bindings through it (hostWidget.marketRows)
  // don't re-evaluate when the host's own properties change. The panel
  // pulls a copy instead: on open, on refresh, and once a second while
  // open (cheap, and it also catches settings round-trips from other bar
  // instances).
  property var rows: []
  property var primaryRow: null
  property var trackedCoins: []
  property string primary: ""
  property int intervalMin: 60
  property real flatThresholdPct: Model.FLAT_DEFAULT
  property string barSection: ""
  property date lastUpdated: new Date(0)
  property string fetchError: ""

  function syncFromHost() {
    if (!hostWidget) return
    rows = hostWidget.marketRows
    primaryRow = hostWidget.primaryRow
    trackedCoins = hostWidget.trackedCoins
    primary = hostWidget.primary
    intervalMin = hostWidget.intervalMin
    flatThresholdPct = hostWidget.flatThresholdPct
    lastUpdated = hostWidget.lastUpdated
    fetchError = hostWidget.fetchError
    if (typeof hostWidget.refreshBarSection === "function") hostWidget.refreshBarSection()
    barSection = hostWidget.barSection || ""
  }

  onHostWidgetChanged: syncFromHost()

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.syncFromHost()
  }

  // Wall clock for the refresh cooldown. Ticks only while the panel is
  // open; cooldownRemaining re-evaluates against it every second.
  property date nowTick: new Date()
  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowTick = new Date()
  }

  // Seconds left in the post-refresh lockout, read from the same shared
  // gate every fetch path funnels through (Model.pollState), so the
  // button's color can never disagree with what the fetch choke point
  // will actually allow (and a follower's consume lag cannot show a
  // clickable button whose click gets dropped).
  readonly property real cooldownRemaining: Model.pollCooldownRemaining(nowTick.getTime())

  // ---- trend state
  readonly property var trendSeries: {
    if (trendRange === "1h") return Model.windowPoints(chartPrices, 60)
    if (trendRange === "1d") return chartPrices.map(function(p) { return p[1] })
    return primaryRow && primaryRow.spark7d ? primaryRow.spark7d : []
  }
  readonly property var trendChange: Model.seriesChange(trendSeries)

  // Semantic up/down colors. Omarchy themes only ship neutral + urgent, so
  // the pair is fixed here to keep up/down distinguishable on any theme.
  readonly property color upColor: "#7fc983"
  readonly property color downColor: "#d4776f"
  readonly property color trendColor: trendChange === null
    ? Color.muted
    : (trendChange >= 0 ? upColor : downColor)

  readonly property string searchText: addField.text.replace(/^\s+|\s+$/g, "").toLowerCase()

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function open() {
    root.controller.show()
    root.syncFromHost()
    root.refresh()
  }

  function openFromHotkey() {
    root.open()
  }

  function refresh() {
    // Markets come from the host widget's poll loop; a manual refresh
    // (open, right click, "r") asks it to re-check now.
    root.syncFromHost()
    if (hostWidget && typeof hostWidget.refresh === "function") hostWidget.refresh()
    refreshCharts()
  }

  // market_chart days=1 gives 5-minutely points: the raw material for both
  // the 1h window (last 12 points) and the 1d line. One extra call per
  // primary coin, only while the panel is being used. The fetch is tagged
  // with the coin it belongs to and mismatched completions are discarded,
  // so a slow response for the previous primary can never render under
  // the new primary's name.
  function refreshCharts() {
    // Wait out a killed run's pending completion (exitSeen/streamSeen
    // carry the OLD run's flags): proceeding over live state could pair
    // a stale exit with the next run's stream and consume garbage.
    if (!primary || chartProc.running || chartProc.exitSeen || chartProc.streamSeen) {
      Qt.callLater(refreshCharts)
      return
    }
    root.chartGen++
    chartProc.gen = root.chartGen
    chartProc.activeId = primary
    chartError = ""
    // Same producer-side byte cap as the host's markets fetch (see
    // BarWidget.marketsFetch): pipefail keeps curl's diagnostics, head -c
    // bounds what reaches memory. Model.shellSafeUrl %-encodes single
    // quotes so the single-quoted shell argument cannot be terminated.
    chartProc.command = ["bash", "-o", "pipefail", "-c",
      "curl -fsS --compressed --max-time 15 '" + Model.shellSafeUrl(
        "https://api.coingecko.com/api/v3/coins/" + encodeURIComponent(primary)
        + "/market_chart?vs_currency=usd&days=1")
      + "' | head -c " + Model.RESPONSE_MAX_BYTES]
    chartProc.running = true
  }

  function runSearch() {
    if (searchText === "") {
      searchResults = []
      return
    }
    if (searchProc.running) return
    searchProc.activeQuery = searchText
    searchProc.command = ["bash", "-o", "pipefail", "-c",
      "curl -fsS --compressed --max-time 10 '" + Model.shellSafeUrl(
        "https://api.coingecko.com/api/v3/search?query=" + encodeURIComponent(searchText))
      + "' | head -c " + Model.RESPONSE_MAX_BYTES]
    searchProc.running = true
  }

  function addCoin(id) {
    if (hostWidget && typeof hostWidget.addCoin === "function") hostWidget.addCoin(id)
    addField.text = ""
    searchResults = []
    Qt.callLater(syncFromHost)
  }

  function removeCoin(id) {
    if (hostWidget && typeof hostWidget.removeCoin === "function") hostWidget.removeCoin(id)
    Qt.callLater(syncFromHost)
  }

  function setPrimary(id) {
    if (hostWidget && typeof hostWidget.updateSetting === "function")
      hostWidget.updateSetting("primary", id)
    Qt.callLater(syncFromHost)
  }

  function setInterval(minutes) {
    // Assign locally too: the committed value round-trips through
    // shell.json and back via syncFromHost (up to a second), during
    // which the slider binding would otherwise snap back to the old rung.
    intervalMin = Model.clampInterval(minutes)
    if (hostWidget && typeof hostWidget.updateSetting === "function")
      hostWidget.updateSetting("intervalMin", intervalMin)
    Qt.callLater(syncFromHost)
  }

  function setFlatThreshold(pct) {
    // Same instant-feedback reasoning as setInterval.
    flatThresholdPct = Model.clampFlat(pct)
    if (hostWidget && typeof hostWidget.updateSetting === "function")
      hostWidget.updateSetting("flatThresholdPct", flatThresholdPct)
    Qt.callLater(syncFromHost)
  }

  function setBarSection(section) {
    var next = Model.clampSection(section)
    if (next === "") return
    barSection = next
    if (hostWidget && typeof hostWidget.setBarSection === "function")
      hostWidget.setBarSection(next)
  }

  // Chart-fetch generation: incremented on every refreshCharts(), so a
  // killed fetch whose StdioCollector flush lands AFTER a new primary's
  // fetch was tagged (and the id reused) still fails the generation test
  // and cannot paint the old coin's series under the new primary's name.
  property int chartGen: 0

  onPrimaryChanged: {
    // Never show the previous coin's chart under the new primary's name:
    // drop what we have, cancel any in-flight fetch for the old coin, and
    // pull fresh data for the new one. Deferred past the event loop so
    // the Process teardown below has fully cleared `running` — an
    // immediate refreshCharts() could see the stale flag and silently
    // skip the new primary's fetch.
    chartPrices = []
    chartError = ""
    chartProc.running = false
    if (opened) Qt.callLater(refreshCharts)
  }

  Process {
    id: chartProc
    property string activeId: ""
    property int gen: 0
    property string stdoutText: ""
    property int lastExitCode: 0
    property bool exitSeen: false
    property bool streamSeen: false

    function maybeFinish() {
      if (!exitSeen || !streamSeen) return
      exitSeen = false
      streamSeen = false
      if (gen !== root.chartGen || activeId !== root.primary) {
        stdoutText = ""
        stderrText = ""
        return
      }
      var points = lastExitCode === 0 ? Model.parseMarketChart(stdoutText) : []
      if (points.length > 0) {
        root.chartPrices = points
        root.chartError = ""
      } else {
        root.chartError = lastExitCode === 0
          ? "No chart data for " + root.primary
          : Model.describeFetchFailure(lastExitCode, stderrText)
      }
      stdoutText = ""
      stderrText = ""
    }

    property string stderrText: ""

    onExited: function(exitCode) {
      lastExitCode = exitCode
      exitSeen = true
      maybeFinish()
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        chartProc.stdoutText = text
        chartProc.streamSeen = true
        chartProc.maybeFinish()
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: chartProc.stderrText = text
    }
  }

  Process {
    id: searchProc
    property string activeQuery: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // The query moved on while this fetch was in flight — drop the
        // stale results and fetch the latest (weather's geocoder pattern).
        if (root.searchText !== searchProc.activeQuery) {
          if (root.searchText === "") root.searchResults = []
          else searchDebounce.restart()
          return
        }
        var results = Model.parseSearch(text)
        var filtered = []
        for (var i = 0; i < results.length && filtered.length < 8; i++) {
          if (root.trackedCoins.indexOf(results[i].id) < 0) filtered.push(results[i])
        }
        root.searchResults = filtered
      }
    }
  }

  Timer {
    id: searchDebounce
    interval: 400
    onTriggered: root.runSearch()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: addField.activeFocus && addField.text !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        // j/k and the arrow keys scroll the panel instead of dying here.
        if (!scroll.interactive) return
        var step = Style.space(36)
        var next = scroll.contentY + (dy > 0 ? step : -step)
        scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height, next))
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "s" || t === "S") root.activeTab = root.activeTab === "coins" ? "settings" : "coins"
        else if (t === "t" || t === "T") {
          var order = ["1h", "1d", "1w"]
          root.trendRange = order[(order.indexOf(root.trendRange) + 1) % order.length]
        }
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(14)

          // ------------------------------------------------------- tabs
          //
          // Header row: tab switcher on the left, manual refresh on the
          // right. The refresh icon is soft red for a minute after the
          // last successful CoinGecko check — the public API tolerates
          // ~1 call/minute, so a click inside that window is a no-op.
          Item {
            width: parent.width
            implicitHeight: Math.max(tabRow.implicitHeight, refreshButton.implicitHeight)

            Row {
              id: tabRow
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Button {
                text: "COINS"
                selected: root.activeTab === "coins"
                foreground: root.bar ? root.bar.foreground : Color.foreground
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.spacing.md
                verticalPadding: Style.spacing.xxs
                onClicked: root.activeTab = "coins"
              }

              Button {
                text: "SETTINGS"
                selected: root.activeTab === "settings"
                foreground: root.bar ? root.bar.foreground : Color.foreground
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.spacing.md
                verticalPadding: Style.spacing.xxs
                onClicked: root.activeTab = "settings"
              }
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑐"
              foreground: root.cooldownRemaining > 0
                ? Color.urgent
                : (root.bar ? root.bar.foreground : Color.foreground)
              hoverColor: Color.urgent
              tooltipText: root.cooldownRemaining > 0
                ? "CoinGecko rate limit — wait " + Math.ceil(root.cooldownRemaining) + "s"
                : "Refresh from CoinGecko now"
              onClicked: if (root.cooldownRemaining <= 0) root.refresh()
            }
          }

          Text {
            visible: root.fetchError !== ""
            width: parent.width
            text: "⚠ " + root.fetchError + " · showing last known prices"
            color: Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ==================================================== COINS TAB
          Column {
            visible: root.activeTab === "coins"
            width: parent.width
            spacing: Style.space(14)

            // ------------------------------------------------------ hero
            Item {
              width: parent.width
              implicitHeight: Math.max(heroLeft.implicitHeight, heroRight.implicitHeight)

              Column {
                id: heroLeft
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: root.primaryRow ? root.primaryRow.name : "OmaCoin"
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.heading
                  font.bold: true
                  elide: Text.ElideRight
                  width: Math.min(implicitWidth, Style.space(300))
                }

                Text {
                  text: root.primaryRow
                    ? (root.primaryRow.symbol + " · USD · VOL " + Model.formatCompactUsd(root.primaryRow.vol24h))
                    : "CoinGecko · USD"
                  color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 0.5
                  textFormat: Text.PlainText
                }
              }

              Column {
                id: heroRight
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  anchors.right: parent.right
                  text: root.primaryRow && root.primaryRow.price !== null ? Model.formatUsd(root.primaryRow.price) : "—"
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.display
                  font.bold: true
                }

                Text {
                  anchors.right: parent.right
                  visible: root.primaryRow && root.primaryRow.change24h !== null
                  text: root.primaryRow ? "24h " + Model.formatPct(root.primaryRow.change24h) : ""
                  color: root.primaryRow && root.primaryRow.change24h >= 0 ? root.upColor : root.downColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
              }
            }

            // ------------------------------------------------- trend line
            Column {
              width: parent.width
              spacing: Style.space(8)

              Item {
                width: parent.width
                height: Math.max(trendHeaderLabel.implicitHeight, trendButtons.implicitHeight)

                PanelSectionHeader {
                  id: trendHeaderLabel
                  text: "TREND"
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Row {
                  id: trendButtons
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  Repeater {
                    model: [
                      { key: "1h", label: "1H" },
                      { key: "1d", label: "1D" },
                      { key: "1w", label: "1W" }
                    ]

                    Button {
                      required property var modelData
                      text: modelData.label
                      selected: root.trendRange === modelData.key
                      foreground: root.bar ? root.bar.foreground : Color.foreground
                      fontSize: Style.font.bodySmall
                      horizontalPadding: Style.spacing.sm
                      verticalPadding: Style.spacing.xxs
                      onClicked: root.trendRange = modelData.key
                    }
                  }
                }
              }

              Sparkline {
                width: parent.width
                height: Style.space(88)
                series: root.trendSeries
                lineColor: root.trendColor
              }

              Text {
                visible: root.trendSeries.length > 0
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: {
                  var label = root.trendRange === "1h" ? "past hour" : (root.trendRange === "1d" ? "past day" : "past week")
                  return root.trendChange !== null ? Model.formatPct(root.trendChange) + " (" + label + ")" : label
                }
                color: root.trendColor
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                visible: root.trendSeries.length === 0
                width: parent.width
                text: !root.primaryRow ? "No coin selected."
                  : (root.chartError !== "" ? "Trend unavailable — " + root.chartError
                  : "Loading trend…")
                color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }

            PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

            // ---------------------------------------------- tracked coins
            PanelSectionHeader {
              text: "TRACKED · " + root.trackedCoins.length
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            Text {
              visible: root.trackedCoins.length === 0
              width: parent.width
              text: "No coins tracked. Search below to add one."
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.trackedCoins.length > 0 && root.rows.length === 0
              width: parent.width
              text: "Waiting for CoinGecko data…"
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.rows

              delegate: Rectangle {
                id: coinRow
                required property var modelData
                width: parent ? parent.width : 0
                implicitHeight: Style.space(52)
                radius: Style.cornerRadius
                color: rowMouse.containsMouse || modelData.id === root.primary
                  ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                  : "transparent"

                // Declared BEFORE the RowLayout: later siblings stack
                // above earlier ones, so the row's click target stays
                // under the ★ / ✕ action buttons instead of swallowing
                // them (first-party panels order these the same way).
                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  acceptedButtons: Qt.LeftButton
                  onClicked: root.setPrimary(coinRow.modelData.id)
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(10)

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(2)

                    Row {
                      spacing: Style.space(6)

                      Text {
                        text: coinRow.modelData.symbol
                        textFormat: Text.PlainText
                        color: root.bar ? root.bar.foreground : Color.foreground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }

                      Text {
                        text: coinRow.modelData.name
                        textFormat: Text.PlainText
                        color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, Style.space(150))
                      }
                    }

                    Text {
                      text: "1h " + Model.formatPct(coinRow.modelData.change1h)
                        + "  ·  24h " + Model.formatPct(coinRow.modelData.change24h)
                        + "  ·  7d " + Model.formatPct(coinRow.modelData.change7d)
                      color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Column {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: Style.space(2)

                    Text {
                      anchors.right: parent.right
                      text: coinRow.modelData.price !== null ? Model.formatUsd(coinRow.modelData.price) : "—"
                      color: root.bar ? root.bar.foreground : Color.foreground
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Text {
                      anchors.right: parent.right
                      text: "VOL " + Model.formatCompactUsd(coinRow.modelData.vol24h)
                      color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }

                  PanelActionButton {
                    iconText: coinRow.modelData.id === root.primary ? "★" : "☆"
                    tooltipText: coinRow.modelData.id === root.primary ? "Primary coin" : "Make primary"
                    foreground: coinRow.modelData.id === root.primary ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                    onClicked: root.setPrimary(coinRow.modelData.id)
                  }

                  PanelActionButton {
                    iconText: "✕"
                    tooltipText: "Remove " + coinRow.modelData.name
                    hoverColor: Color.urgent
                    onClicked: root.removeCoin(coinRow.modelData.id)
                  }
                }
              }
            }

            // Tracked but not yet fetched: added inside the rate-limit
            // window, so their first data lands when the deferred fetch
            // fires (up to 60s). A visible placeholder beats a dead click.
            Repeater {
              model: root.pendingCoins

              delegate: Rectangle {
                id: pendingRow
                required property string modelData
                width: parent ? parent.width : 0
                implicitHeight: Style.space(52)
                radius: Style.cornerRadius
                color: "transparent"
                border.color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 2.2)
                border.width: 1

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(10)

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(2)

                    Text {
                      text: pendingRow.modelData
                      textFormat: Text.PlainText
                      color: root.bar ? root.bar.foreground : Color.foreground
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      text: "waiting for first price · rate-limit cooldown"
                      color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }

                  PanelActionButton {
                    iconText: "✕"
                    tooltipText: "Remove " + pendingRow.modelData
                    hoverColor: Color.urgent
                    onClicked: root.removeCoin(pendingRow.modelData)
                  }
                }
              }
            }

            Text {
              visible: root.rows.length > 0
              width: parent.width
              text: "Click a coin to make it the primary shown in the bar."
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }
            // ---------------------------------------------------- add coin
            PanelSectionHeader {
              text: "ADD COIN"
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            // The id list is capped at COINS_MAX (see Model.coinList), so
            // past the limit every add is a no-op — say so instead of
            // leaving a dead search result row.
            Text {
              visible: root.trackedCoins.length >= Model.COINS_MAX
              width: parent.width
              text: "Tracked-coin limit reached (" + Model.COINS_MAX + "). Remove a coin to add another."
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            TextField {
              id: addField
              width: parent.width
              placeholderText: "Search CoinGecko (name or symbol)"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              onTextChanged: searchDebounce.restart()

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  // First Esc clears the query (and returns focus so the
                  // panel's key catcher can act); with nothing typed,
                  // let it bubble so Esc closes the panel as usual.
                  if (text !== "") {
                    text = ""
                    root.searchResults = []
                    root.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }
            }

            Repeater {
              model: root.searchResults

              delegate: Rectangle {
                id: resultRow
                required property var modelData
                width: parent ? parent.width : 0
                implicitHeight: Style.space(34)
                radius: Style.cornerRadius
                color: resultMouse.containsMouse
                  ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                  : "transparent"

                // Before the RowLayout, same z-order rule as coin rows.
                MouseArea {
                  id: resultMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.addCoin(resultRow.modelData.id)
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(10)

                  Text {
                    Layout.fillWidth: true
                    text: resultRow.modelData.name + " (" + resultRow.modelData.symbol + ")"
                    textFormat: Text.PlainText
                    color: root.bar ? root.bar.foreground : Color.foreground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Text {
                    visible: resultRow.modelData.rank !== null
                    text: "#" + resultRow.modelData.rank
                    color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  PanelActionButton {
                    iconText: "＋"
                    tooltipText: "Track " + resultRow.modelData.name
                    onClicked: root.addCoin(resultRow.modelData.id)
                  }
                }
              }
            }
          }

          // ================================================ SETTINGS TAB
          Column {
            visible: root.activeTab === "settings"
            width: parent.width
            spacing: Style.space(14)

            // ------------------------------------------- bar position
            PanelSectionHeader {
              text: "BAR POSITION"
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            Row {
              spacing: Style.space(6)

              Repeater {
                model: [
                  { key: "left", label: "LEFT" },
                  { key: "center", label: "CENTER" },
                  { key: "right", label: "RIGHT" }
                ]

                Button {
                  required property var modelData
                  text: modelData.label
                  selected: root.barSection === modelData.key
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  fontSize: Style.font.bodySmall
                  horizontalPadding: Style.spacing.md
                  verticalPadding: Style.spacing.xxs
                  onClicked: root.setBarSection(modelData.key)
                }
              }
            }

            Text {
              width: parent.width
              text: "Which bar section this widget sits in — the same left / center / right choice as when the plugin was enabled."
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

            // ------------------------------------------- check frequency
            PanelSectionHeader {
              text: "CHECK FREQUENCY"
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignRight
              text: Model.intervalLabel(Model.ladderAt(root.freqPreview >= 0 ? root.freqPreview : Model.intervalIndex(root.intervalMin)))
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            // Slider position is the ladder rung index (12 rungs, one tick
            // each): minimum 1 minute, maximum 1 day, and the specific
            // intervals CoinGecko's rate limits make meaningful.
            PanelSlider {
              bar: root.bar
              width: parent.width
              minimum: 0
              maximum: Model.ladderCount() - 1
              step: 1
              integer: true
              tickCount: Model.ladderCount()
              value: Model.intervalIndex(root.intervalMin)
              onMoved: function(v) { root.freqPreview = Math.round(v) }
              onReleased: function(v) { root.setInterval(Model.ladderAt(v)) }
            }

            Text {
              width: parent.width
              text: "CoinGecko's public API accepts one call per minute at most, so the ladder " +
                "runs from 1 minute up to once per day. Each check is a single call for every tracked coin."
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

            // ------------------------------------------------ flat band
            PanelSectionHeader {
              text: "FLAT BAND"
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignRight
              text: Model.flatLabel(root.flatPreview >= 0 ? root.flatPreview : root.flatThresholdPct)
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            // 0% disables the flat band (every move tints); 5% is the
            // ceiling. Steps of 0.1%.
            PanelSlider {
              bar: root.bar
              width: parent.width
              minimum: 0
              maximum: 5
              step: 0.1
              value: root.flatThresholdPct
              onMoved: function(v) { root.flatPreview = Math.round(v * 10) / 10 }
              onReleased: function(v) { root.setFlatThreshold(Math.round(v * 10) / 10) }
            }

            Text {
              width: parent.width
              text: "24h moves smaller than this count as flat: the bar shows the price in plain " +
                "white with a · glyph instead of a green/red tint. Default ±0.5%."
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

            Text {
              width: parent.width
              text: "Updated " + Model.formatTime(root.lastUpdated)
                + " · every " + Model.intervalLabel(root.intervalMin)
                + " · Data from CoinGecko"
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  component Sparkline: Canvas {
    id: canvas
    property var series: []
    property color lineColor: Color.accent

    onSeriesChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onLineColorChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      var pts = Model.sparkPoints(series, width, height, 3)
      if (pts.length < 2) return

      // Area fill under the line.
      ctx.beginPath()
      ctx.moveTo(pts[0].x, pts[0].y)
      for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y)
      ctx.lineTo(pts[pts.length - 1].x, height)
      ctx.lineTo(pts[0].x, height)
      ctx.closePath()
      ctx.fillStyle = Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.14)
      ctx.fill()

      // The line itself.
      ctx.beginPath()
      ctx.moveTo(pts[0].x, pts[0].y)
      for (var j = 1; j < pts.length; j++) ctx.lineTo(pts[j].x, pts[j].y)
      ctx.strokeStyle = lineColor
      ctx.lineWidth = 1.5
      ctx.stroke()
    }
  }
}
