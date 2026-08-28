.pragma library

// Pure helpers for OmaCoin: settings normalization, CoinGecko response
// parsing, formatting, and cross-instance poll coordination. No Qt imports
// — everything here is plain JS shared by the bar widget and the panel.

// ---------------------------------------------------------------- settings

// CoinGecko's public API allows roughly 10-30 calls/minute from an IP and
// refreshes its price cache every 30-60s, so one call per minute is the
// fastest check frequency it meaningfully accepts. The ladder runs from
// that minimum up to once per day; the default is once per hour.
var INTERVAL_LADDER = [1, 2, 5, 10, 15, 30, 60, 120, 240, 360, 720, 1440]

// 24h moves smaller than the flat threshold (percent) count as "no
// direction": plain foreground, "·" glyph. Default ±0.5%.
var FLAT_DEFAULT = 0.5

// ---- untrusted-input limits ------------------------------------------
//
// Two sources are treated as untrusted: same-user IPC callers (addCoin /
// removeCoin / setPrimary / hand-edited shell.json) that can persist
// arbitrarily long values, and CoinGecko responses parsed into long-lived
// objects in the shared shell process. These caps bound what can be
// persisted, requested, and retained.
var COIN_ID_RE = /^[a-z0-9][a-z0-9._-]*$/
var COIN_ID_MAX_LEN = 64
var COINS_MAX = 16
// Producer-side byte cap: every fetch pipes curl through `head -c`, so a
// hostile or broken endpoint can never stream more than this into memory.
var RESPONSE_MAX_BYTES = 1048576
var MARKETS_MAX_ROWS = 50       // COINS_MAX ids are requested; margin for junk rows
var SEARCH_MAX_RESULTS = 25     // the popup shows 8; parse only the head of the list
var CHART_MAX_POINTS = 2000     // days=1 is ~288 5-minutely points
var SPARKLINE_MAX_POINTS = 1000 // sparkline_in_7d is ~168 hourly points
var NAME_MAX_LEN = 80
var SYMBOL_MAX_LEN = 24

// Sanitize and bound a remote string before it reaches QML: strips control
// characters and truncates to maxLen. Rendering layers additionally use
// Text.PlainText so markup in remote text can never be interpreted.
function safeString(value, maxLen) {
  var s = String(value === null || value === undefined ? "" : value).replace(/[\u0000-\u001f\u007f]/g, "")
  if (s.length > maxLen) s = s.slice(0, maxLen)
  return s
}

// Shell-quoting guard for URLs passed into `bash -c 'curl ... <url> ...'`.
// encodeURIComponent leaves single quotes literal; percent-encode them so a
// quote character in user input can never terminate the quoted argument.
function shellSafeUrl(url) {
  return String(url).replace(/'/g, "%27")
}

function intervalLabel(minutes) {
  var m = Number(minutes)
  if (!isFinite(m) || m < 60) return m + (m === 1 ? " minute" : " minutes")
  if (m < 1440) {
    var h = m / 60
    var hs = (h === Math.floor(h) ? String(h) : h.toFixed(1))
    return hs + (h === 1 ? " hour" : " hours")
  }
  return "1 day"
}

// Snap any hand-edited value onto the ladder (nearest rung).
function clampInterval(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 60
  var best = INTERVAL_LADDER[0]
  for (var i = 1; i < INTERVAL_LADDER.length; i++) {
    if (Math.abs(INTERVAL_LADDER[i] - n) < Math.abs(best - n)) best = INTERVAL_LADDER[i]
  }
  return best
}

// Ladder rung index for a (snapped) interval — the frequency slider's
// position. Falls back to the 60-minute rung if unmatched.
function intervalIndex(minutes) {
  var target = clampInterval(minutes)
  for (var i = 0; i < INTERVAL_LADDER.length; i++) {
    if (INTERVAL_LADDER[i] === target) return i
  }
  return INTERVAL_LADDER.indexOf(60)
}

function ladderAt(i) {
  var idx = Math.max(0, Math.min(INTERVAL_LADDER.length - 1, Math.round(Number(i) || 0)))
  return INTERVAL_LADDER[idx]
}

// Clamp the flat threshold onto the slider's range, snapped to 0.1%.
function clampFlat(value) {
  var n = Number(value)
  if (!isFinite(n)) return FLAT_DEFAULT
  return Math.max(0, Math.min(5, Math.round(n * 10) / 10))
}

// Bar section is host layout, not an inline setting: which of
// bar.layout.{left,center,right} this widget's entry lives in.
function clampSection(value) {
  var s = String(value === null || value === undefined ? "" : value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (s === "left" || s === "center" || s === "right") return s
  return ""
}

// Which bar section holds `id`. layout arrays arrive as QVariantList, so
// duck-type length the same way coinList does.
function barSectionOf(layout, id) {
  if (!layout || typeof layout !== "object") return ""
  var key = String(id || "")
  if (key === "") return ""
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var arr = layout[sections[s]]
    var n = arr && typeof arr.length === "number" ? arr.length : 0
    for (var i = 0; i < n; i++) {
      var entry = arr[i]
      var eid = (entry && typeof entry === "object") ? String(entry.id || "") : String(entry || "")
      if (eid === key) return sections[s]
    }
  }
  return ""
}

function ladderCount() {
  return INTERVAL_LADDER.length
}

function flatLabel(pct) {
  var n = clampFlat(pct)
  return n === 0 ? "0% — no flat band" : "±" + n.toFixed(1) + "%"
}

// Normalize a coins setting (array, or comma-separated string from a
// hand-edited shell.json) into a deduplicated lowercase id array.
function coinList(value) {
  // QML hands inline shell.json arrays over as QVariantList, which fails
  // Array.isArray — so duck-type instead: anything with a length and
  // array-style indexing counts.
  var raw = []
  if (Array.isArray(value)) raw = value.slice()
  else if (typeof value === "string") raw = value.split(",")
  else if (value && typeof value.length === "number") {
    for (var v = 0; v < value.length; v++) raw.push(value[v])
  }
  var seen = {}
  var out = []
  // Strict id rules: CoinGecko ids are short lowercase tokens. Anything
  // outside the charset (or over COIN_ID_MAX_LEN) is dropped, and the
  // list itself is capped at COINS_MAX — this one loop bounds every input
  // path at once: IPC addCoin/removeCoin, popup search adds, and a
  // hand-edited shell.json entry.
  for (var i = 0; i < raw.length; i++) {
    var id = String(raw[i] || "").replace(/^\s+|\s+$/g, "").toLowerCase()
    if (id === "" || seen[id]) continue
    if (!COIN_ID_RE.test(id) || id.length > COIN_ID_MAX_LEN) continue
    seen[id] = true
    out.push(id)
    if (out.length >= COINS_MAX) break
  }
  return out
}

// The primary must be one of the tracked coins; fall back to the first.
function primaryId(coins, primarySetting) {
  var list = coinList(coins)
  var wanted = String(primarySetting || "").toLowerCase()
  for (var i = 0; i < list.length; i++) if (list[i] === wanted) return list[i]
  return list.length > 0 ? list[0] : ""
}

// ---------------------------------------------------------------- parsing

function parseJson(raw) {
  var text = String(raw || "").replace(/^\s+|\s+$/g, "")
  if (text === "") return null
  // Belt against oversized payloads reaching JSON.parse even when the
  // producer-side pipe cap is bypassed. A truncated document fails the
  // parse and surfaces as a fetch error — correct, not silent.
  if (text.length > RESPONSE_MAX_BYTES) text = text.slice(0, RESPONSE_MAX_BYTES)
  try { return JSON.parse(text) } catch (e) { return null }
}

function num(value) {
  // Missing fields must stay missing: Number(null) === 0 would render
  // absent change data as "+0.00%" with a green tint.
  if (value === null || value === undefined || value === "") return null
  var n = Number(value)
  return isFinite(n) ? n : null
}

// /api/v3/coins/markets?vs_currency=usd&ids=...&sparkline=true
// &price_change_percentage=1h,24h,7d  →  map keyed by coin id.
function parseMarkets(raw) {
  var data = parseJson(raw)
  if (!Array.isArray(data)) return null
  var map = {}
  var count = 0
  for (var i = 0; i < data.length && count < MARKETS_MAX_ROWS; i++) {
    var r = data[i]
    if (!r || !r.id) continue
    var id = safeString(r.id, COIN_ID_MAX_LEN)
    map[id] = {
      id: id,
      symbol: safeString(r.symbol || r.id, SYMBOL_MAX_LEN).toUpperCase(),
      name: safeString(r.name || r.id, NAME_MAX_LEN),
      price: num(r.current_price),
      vol24h: num(r.total_volume),
      high24h: num(r.high_24h),
      low24h: num(r.low_24h),
      change24h: num(num(r.price_change_percentage_24h_in_currency) !== null
        ? r.price_change_percentage_24h_in_currency : r.price_change_percentage_24h),
      change7d: num(r.price_change_percentage_7d_in_currency),
      // Bounded copy of the remote array; sparkPoints() draws every entry,
      // so drop the nulls that num() produced for non-finite raw values.
      spark7d: (r.sparkline_in_7d && Array.isArray(r.sparkline_in_7d.price))
        ? r.sparkline_in_7d.price.slice(0, SPARKLINE_MAX_POINTS).map(num)
          .filter(function(v) { return v !== null }) : []
    }
  }
  return map
}

// Order the parsed markets map along the tracked-coin list; unknown ids
// (delisted / typo) are kept out — the add flow re-resolves them by search.
function orderRows(map, coins) {
  var out = []
  var list = coinList(coins)
  for (var i = 0; i < list.length; i++) if (map && map[list[i]]) out.push(map[list[i]])
  return out
}

function rowById(rows, id) {
  var wanted = String(id || "")
  for (var i = 0; i < rows.length; i++) if (rows[i].id === wanted) return rows[i]
  return null
}

// /api/v3/search?query=...  →  [{id, name, symbol, rank}]
function parseSearch(raw) {
  var data = parseJson(raw)
  if (!data || !Array.isArray(data.coins)) return []
  var out = []
  for (var i = 0; i < data.coins.length && out.length < SEARCH_MAX_RESULTS; i++) {
    var c = data.coins[i]
    if (!c || !c.id) continue
    out.push({
      id: safeString(c.id, COIN_ID_MAX_LEN),
      name: safeString(c.name || c.id, NAME_MAX_LEN),
      symbol: safeString(c.symbol || "", SYMBOL_MAX_LEN).toUpperCase(),
      rank: num(c.market_cap_rank)
    })
  }
  return out
}

// /api/v3/coins/{id}/market_chart?vs_currency=usd&days=1  →  [[ts, price]...]
function parseMarketChart(raw) {
  var data = parseJson(raw)
  if (!data || !Array.isArray(data.prices)) return []
  var out = []
  for (var i = 0; i < data.prices.length && out.length < CHART_MAX_POINTS; i++) {
    var p = data.prices[i]
    if (!Array.isArray(p) || p.length < 2) continue
    var price = num(p[1])
    var ts = num(p[0])
    if (price === null || ts === null) continue
    out.push([ts, price])
  }
  return out
}

// Slice a [[ts, price]] series down to its last `minutes` (5-minutely data
// from days=1, so an hour is ~12 points). Returns [] when the window has
// too few points — substituting the full day would mislabel the trend.
function windowPoints(series, minutes) {
  if (!Array.isArray(series) || series.length === 0) return []
  var last = series[series.length - 1][0]
  var cutoff = last - minutes * 60 * 1000
  var out = []
  for (var i = 0; i < series.length; i++) {
    if (series[i][0] >= cutoff) out.push(series[i][1])
  }
  return out.length >= 2 ? out : []
}

function seriesChange(prices) {
  if (!Array.isArray(prices) || prices.length < 2) return null
  var first = Number(prices[0])
  var last = Number(prices[prices.length - 1])
  if (!isFinite(first) || !isFinite(last) || first === 0) return null
  return (last - first) / first * 100
}

// ------------------------------------------------------------- formatting

function group(intPart) {
  var negative = intPart.indexOf("-") === 0
  var digits = negative ? intPart.slice(1) : intPart
  var out = ""
  while (digits.length > 3) {
    out = "," + digits.slice(-3) + out
    digits = digits.slice(0, -3)
  }
  return (negative ? "-" : "") + digits + out
}

function formatUsd(value) {
  if (value === null || value === undefined) return "—"
  var n = Number(value)
  if (!isFinite(n) || n < 0) return "—"
  if (n >= 1000) return "$" + group(String(Math.round(n)))
  if (n >= 1) return "$" + group(String(Math.floor(n))) + "." + decimals(n, 2)
  if (n >= 0.01) return "$0." + decimals(n, 4)
  if (n === 0) return "$0.00"
  var sig = n.toPrecision(4).replace(/0+$/, "").replace(/\.$/, "")
  return "$" + (sig.indexOf(".") < 0 ? sig + ".00" : sig)
}

function decimals(n, places) {
  var s = n.toFixed(places)
  var dot = s.indexOf(".")
  return dot < 0 ? "00" : s.slice(dot + 1)
}

function formatCompactUsd(value) {
  var n = Number(value)
  if (!isFinite(n) || n <= 0) return "—"
  if (n >= 1e12) return "$" + (n / 1e12).toFixed(1) + "T"
  if (n >= 1e9) return "$" + (n / 1e9).toFixed(1) + "B"
  if (n >= 1e6) return "$" + (n / 1e6).toFixed(1) + "M"
  if (n >= 1e3) return "$" + (n / 1e3).toFixed(1) + "K"
  return "$" + Math.round(n)
}

function formatPct(value) {
  if (value === null || value === undefined) return "—"
  var n = Number(value)
  if (!isFinite(n)) return "—"
  return (n > 0 ? "+" : "") + n.toFixed(2) + "%"
}

function formatTime(date) {
  if (!date || typeof date.getTime !== "function" || date.getTime() === 0) return "—"
  var h = date.getHours()
  var m = date.getMinutes()
  return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

// ---------------------------------------------------------------- sparkline

// Map a price series onto a w×h canvas with padding. Flat series draw a
// midline rather than a divide-by-zero.
function sparkPoints(series, w, h, pad) {
  if (!Array.isArray(series) || series.length < 2 || w <= 0 || h <= 0) return []
  var min = Infinity, max = -Infinity
  for (var i = 0; i < series.length; i++) {
    var v = Number(series[i])
    if (!isFinite(v)) continue
    if (v < min) min = v
    if (v > max) max = v
  }
  if (!isFinite(min) || !isFinite(max)) return []
  var span = max - min
  var mid = h / 2
  var points = []
  for (var j = 0; j < series.length; j++) {
    var x = pad + (w - pad * 2) * j / (series.length - 1)
    var y = span > 0 ? pad + (h - pad * 2) * (1 - (series[j] - min) / span) : mid
    points.push({ x: x, y: y })
  }
  return points
}

// ------------------------------------------------- poll coordination
//
// A .pragma library is loaded once per QML engine and this state is shared
// by every OmaCoin widget instance in the shell process. The host runs
// one engine for the whole shell: shell.qml creates every plugin component
// with Qt.createComponent, and the per-monitor bar surfaces are Variants
// expansions inside plugins/bar/Bar.qml — same document, same engine (its
// moduleWidgets() hands live per-monitor widget objects to plain JS, which
// only works within one engine). So exactly one instance (the "leader")
// runs the poll loop and publishes results; the others consume them,
// keeping the one-CoinGecko-call-per-check contract no matter how many
// monitors show the widget. Leadership is heartbeat-based so a destroyed
// leader is re-elected within one heartbeat window.
//
// `seq` increments on EVERY publish (success or failure) — followers
// consume on seq change, not on timestamp, because a failed check
// republishes with the unchanged last-success timestamp and an error
// message the followers must still see.
var pollState = { leader: null, beat: 0, seq: 0, rows: [], updated: 0, error: "", lastSuccessMs: 0 }

// The public API tolerates roughly one call per minute, so every fetch
// path (poll tick, manual refresh, retry) funnels through this gate
// rather than trusting each caller to check a cooldown itself.
var POLL_COOLDOWN_MS = 60000

function pollGateOpen(nowMs) {
  return nowMs - pollState.lastSuccessMs >= POLL_COOLDOWN_MS
}

// Seconds left in the lockout — the panel's refresh button paints this
// as its countdown. Zero when no check has ever succeeded.
function pollCooldownRemaining(nowMs) {
  if (pollState.lastSuccessMs === 0) return 0
  return Math.max(0, (POLL_COOLDOWN_MS - (nowMs - pollState.lastSuccessMs)) / 1000)
}

function pollClaim(widget, nowMs) {
  if (pollState.leader === widget) { pollState.beat = nowMs; return true }
  if (pollState.leader === null || nowMs - pollState.beat > 20000) {
    pollState.leader = widget
    pollState.beat = nowMs
    return true
  }
  return false
}

function pollRelease(widget) {
  if (pollState.leader === widget) pollState.leader = null
}

function pollPublish(widget, rows, updatedMs, error, ok) {
  if (pollState.leader !== widget) return
  pollState.rows = rows
  pollState.updated = updatedMs
  pollState.error = error
  pollState.beat = Date.now()
  pollState.seq++
  if (ok) pollState.lastSuccessMs = updatedMs
}

function pollConsume(widget) {
  if (pollState.leader === widget) return null
  return pollSnapshot()
}

// Last published markets, regardless of who the leader is. A widget
// rebuilt by a bar-layout move becomes the new leader with empty
// marketRows; it must still be able to take the previous publish so
// the bar does not go blank while the rate-limit gate defers a fetch.
function pollSnapshot() {
  if (pollState.seq === 0) return null
  return { rows: pollState.rows, updated: pollState.updated, error: pollState.error, seq: pollState.seq }
}

function pollLeaderInstance() {
  return pollState.leader
}

// ------------------------------------------------------------- retries

// Escalating backoff between failed checks: hammering an already
// rate-limited (or unreachable) API only deepens the hole. Four retries,
// then the failure stands until the next scheduled check.
var RETRY_BACKOFF_SEC = [30, 60, 120, 300]

function retryBackoffMs(retryNumber) {
  var i = Math.max(1, Math.min(RETRY_BACKOFF_SEC.length, Math.round(Number(retryNumber) || 1))) - 1
  return RETRY_BACKOFF_SEC[i] * 1000
}

// ----------------------------------------------------- failure reasons

// Map a failed curl run to a short human reason. curl -f exits 22 on
// HTTP >= 400 with the status on stderr ("...returned error: 429"); the
// exit codes below are curl's own (DNS, connect, timeout, TLS).
function describeFetchFailure(exitCode, stderrText) {
  var err = String(stderrText || "").replace(/\s+/g, " ").replace(/^ | $/g, "")
  var m = err.match(/error: (\d{3})/)
  if (m) return "CoinGecko HTTP " + m[1] + (m[1] === "429" ? " (rate limited)" : "")
  var code = Math.round(Number(exitCode) || 0)
  if (code === 6) return "DNS lookup failed"
  if (code === 7) return "could not connect"
  if (code === 28) return "timed out"
  if (code === 22) return "CoinGecko HTTP error"
  if (code === 60 || code === 35) return "TLS error"
  if (code === 141) return "response too large"
  if (code > 0) return "curl exit " + code
  return "malformed response"
}
