.pragma library

// Pure presentation helpers: formatting and labels, no I/O.

var WINDOWS = [
  { value: "24h", label: "24h" }, { value: "7d", label: "7d" }, { value: "30d", label: "30d" },
  { value: "90d", label: "90d" }, { value: "180d", label: "6mo" }, { value: "365d", label: "1yr" },
  { value: "all", label: "All" }
]

var METRICS = [
  { value: "views", label: "Views" }, { value: "copies", label: "Copies" }, { value: "hearts", label: "Hearts" }
]

function windowLabel(name) {
  for (var i = 0; i < WINDOWS.length; i++) if (WINDOWS[i].value === name) return WINDOWS[i].label
  return name === "today" ? "Today" : String(name)
}

function num(v) {
  var n = Number(v)
  return isFinite(n) ? n : 0
}

function compact(v) {
  var n = num(v)
  var a = Math.abs(n)
  var s = n < 0 ? "-" : ""
  if (a >= 1000000) return s + (a / 1000000).toFixed(a >= 10000000 ? 0 : 1).replace(/\.0$/, "") + "M"
  if (a >= 1000) return s + (a / 1000).toFixed(a >= 10000 ? 0 : 1).replace(/\.0$/, "") + "k"
  return s + String(Math.round(a))
}

function signed(v) {
  var n = Math.round(num(v))
  if (n > 0) return "+" + compact(n)
  if (n < 0) return "−" + compact(-n)
  return "0"
}

function pct(v) {
  if (v === undefined || v === null || !isFinite(Number(v))) return ""
  var n = Number(v)
  var r = Math.abs(n) >= 100 ? Math.round(n) : n.toFixed(Math.abs(n) >= 10 ? 0 : 1)
  return (n > 0 ? "+" : n < 0 ? "−" : "") + String(Math.abs(r)) + "%"
}

function rate(v) {
  if (v === undefined || v === null || !isFinite(Number(v))) return "–"
  return Math.round(Number(v) * 100) + "%"
}

function relTime(seconds) {
  var s = Math.max(0, Math.round(num(seconds)))
  if (s < 90) return "just now"
  var m = Math.round(s / 60)
  if (m < 60) return m + "m ago"
  var h = Math.round(m / 60)
  if (h < 48) return h + "h ago"
  return Math.round(h / 24) + "d ago"
}

function dateShort(ts) {
  if (!ts) return ""
  var d = new Date(num(ts) * 1000)
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return d.getDate() + " " + months[d.getMonth()]
}

function timeLabel(ts, unitSeconds) {
  if (!ts) return ""
  var d = new Date(num(ts) * 1000)
  if (unitSeconds < 86400) {
    var hh = d.getHours()
    var mm = d.getMinutes()
    var t = (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm
    return unitSeconds <= 3600 * 6 ? t : dateShort(ts) + " " + t
  }
  return dateShort(ts)
}

function hours(v) {
  var h = num(v)
  if (h < 1) return "<1h"
  if (h < 48) return Math.round(h) + "h"
  return (h / 24).toFixed(h < 240 ? 1 : 0).replace(/\.0$/, "") + "d"
}

// One-line honesty caption for a window: what the number actually covers.
function coverageCaption(win, name) {
  if (!win || !win.agg) return ""
  var agg = win.agg
  if (name === "all") return "Tracked since " + dateShort(agg.since)
  var parts = []
  if (agg.partial) parts.push("since " + dateShort(agg.since))
  else parts.push("full window")
  var cov = num(agg.coverage)
  if (cov < 0.98 && !agg.partial) parts.push(Math.round(cov * 100) + "% covered")
  else if (cov < 0.98 && agg.partial) parts.push(Math.round(cov * 100) + "% covered")
  return parts.join(" · ")
}

function trendText(entry) {
  if (!entry) return ""
  if (entry.changePct !== undefined && entry.changePct !== null) return pct(entry.changePct) + " vs prev"
  if (entry.trend === "new") return "new"
  return ""
}

function pluginsSorted(win, plugins, metric) {
  var out = []
  for (var i = 0; i < plugins.length; i++) {
    var p = plugins[i]
    var e = win && win.plugins ? win.plugins[p.id] : null
    var m = e && e[metric] ? e[metric] : null
    out.push({ plugin: p, entry: e, delta: m ? num(m.net) : 0 })
  }
  out.sort(function (a, b) { return b.delta - a.delta })
  return out
}

function ordinal(n) {
  var v = Math.round(num(n))
  var s = ["th", "st", "nd", "rd"], r = v % 100
  return v + (s[(r - 20) % 10] || s[r] || s[0])
}

// Deep link to a plugin's page on the marketplace site.
function marketplaceUrl(id) {
  return "https://plugins.omarchy.org/?plugin=" + encodeURIComponent(String(id || ""))
}

function installCommand(repo) {
  return "omarchy plugin add " + String(repo || "") + " --enable"
}

// Only two destinations are ever opened externally, and only over https.
function safeExternalUrl(url) {
  var text = String(url || "")
  if (/[\x00-\x20<>"'\\]/.test(text)) return ""
  return /^https:\/\/(github\.com|plugins\.omarchy\.org)\/[^\s]*$/.test(text) ? text : ""
}

function dateLong(ts) {
  if (!ts) return ""
  var d = new Date(num(ts) * 1000)
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return d.getDate() + " " + months[d.getMonth()] + " " + d.getFullYear()
}
