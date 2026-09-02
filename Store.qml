import QtQuick
import Quickshell
import Quickshell.Io
import "Sanitise.js" as Sanitise

// Shared data access for the app window: summary.json, chart series, README
// fetches, and the few helper actions. All I/O goes through the helper.
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME") || ""

  function stateHome() {
    var configured = Quickshell.env("XDG_STATE_HOME") || ""
    if (configured !== "") return configured
    return home === "" ? "" : home + "/.local/state"
  }

  readonly property string summaryPath: stateHome() === "" ? "" : stateHome() + "/kairos.plugin-analytics/summary.json"
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    while (url.length > 1 && url.charAt(url.length - 1) === "/") url = url.substring(0, url.length - 1)
    return decodeURIComponent(url)
  }
  readonly property string helperPath: pluginDir + "/helper/collect.py"

  // ------------------------------------------------------------- summary

  Reader {
    id: summaryReader
    path: root.summaryPath
    capBytes: 1048576
  }

  readonly property int revision: summaryReader.revision

  function summary() {
    var r = summaryReader.revision
    return summaryReader.record
  }

  function refreshSummary() { summaryReader.requestRead() }

  function author() {
    var d = summary()
    return d ? Sanitise.author(d.author) : ""
  }

  function win(name) {
    var d = summary()
    return d && d.windows ? (d.windows[name] || null) : null
  }

  function plugins() {
    var d = summary()
    var out = []
    var list = d && d.plugins ? d.plugins : []
    for (var i = 0; i < list.length && i < 50; i++) {
      var p = list[i]
      var id = Sanitise.pluginId(p.id)
      if (id === "") continue
      out.push({ id: id, name: Sanitise.plainOneLine(p.name || id, 60), repo: String(p.repo || ""),
                 category: Sanitise.plainOneLine(p.category, 30), addedAt: Sanitise.plainOneLine(p.addedAt, 20),
                 matchedBy: String(p.matchedBy || ""), totals: p.totals || {}, firstTs: p.firstTs })
    }
    return out
  }

  function plugin(id) {
    var list = plugins()
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
    return null
  }

  function resolvedState() {
    var d = summary()
    if (!d) return { ok: false, reason: "no-data", count: 0 }
    var r = d.resolved || {}
    return { ok: r.ok === true, reason: String(r.reason || (r.ok ? "" : "no-data")), count: Number(r.count || 0) }
  }

  // -------------------------------------------------------------- series

  property var series: null
  property bool seriesLoading: false
  property bool seriesPending: false
  property string seriesWindow: ""
  property string seriesMetric: ""
  readonly property int seriesCapBytes: 524288

  function requestSeries(windowName, metric) {
    root.seriesWindow = windowName
    root.seriesMetric = metric
    if (root.helperPath === "") return
    if (seriesProc.running) { root.seriesPending = true; return }
    root.seriesLoading = true
    seriesProc.command = ["timeout", "-k", "2", "20", root.helperPath, "--budget", "15",
                          "series", "--window", windowName, "--metric", metric]
    seriesProc.running = true
  }

  function seriesMatches(windowName, metric) {
    return root.series && root.series.window === windowName && root.series.metric === metric
  }

  function seriesFor(id) {
    var s = root.series
    return s && s.plugins && s.plugins[id] ? s.plugins[id] : []
  }

  function utf8ByteLength(text) {
    var bytes = 0
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i)
      if (code < 0x80) bytes += 1
      else if (code < 0x800) bytes += 2
      else if (code >= 0xd800 && code <= 0xdbff) { bytes += 4; i++ }
      else bytes += 3
    }
    return bytes
  }

  Process {
    id: seriesProc
    running: false
    command: ["true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        root.seriesLoading = false
        if (root.utf8ByteLength(raw) > root.seriesCapBytes) { root.series = null; return }
        try {
          var parsed = JSON.parse(raw)
          root.series = parsed && parsed.ok === true ? parsed : null
        } catch (e) { root.series = null }
      }
    }
    onExited: function () {
      root.seriesLoading = false
      if (root.seriesPending) {
        root.seriesPending = false
        Qt.callLater(function () { root.requestSeries(root.seriesWindow, root.seriesMetric) })
      }
    }
  }

  // ------------------------------------------------------------- collect

  property bool collecting: false

  function collect(force) {
    if (root.helperPath === "" || collectProc.running) return
    collectProc.command = ["timeout", "-k", "5", "200", root.helperPath, "--budget", "150", "collect"]
      .concat(force ? ["--force"] : [])
    root.collecting = true
    collectProc.running = true
  }

  function resolveAuthor(author) {
    var clean = Sanitise.author(author)
    if (clean === "" || root.helperPath === "" || collectProc.running) return
    collectProc.command = ["timeout", "-k", "5", "200", root.helperPath, "--budget", "150",
                           "resolve", "--author", clean]
    root.collecting = true
    collectProc.running = true
  }

  Process {
    id: collectProc
    running: false
    command: ["true"]
    onExited: function (exitCode) {
      root.collecting = false
      if (exitCode !== 0) console.warn("plugin-analytics", "collect exited", exitCode)
      summaryReader.requestRead()
    }
  }

  // -------------------------------------------------------------- readme

  property string readmeId: ""
  property string readmeText: ""
  property string readmeUrl: ""
  property string readmeState: "idle"   // idle | loading | ok | missing | error
  property bool readmeStale: false
  readonly property int readmeCapBytes: 600000

  function requestReadme(id, refresh) {
    var clean = Sanitise.pluginId(id)
    if (clean === "" || root.helperPath === "") return
    if (readmeProc.running) return
    root.readmeId = clean
    root.readmeState = "loading"
    readmeProc.command = ["timeout", "-k", "2", "60", root.helperPath, "--budget", "45",
                          "readme", "--plugin", clean].concat(refresh ? ["--refresh"] : [])
    readmeProc.running = true
  }

  Process {
    id: readmeProc
    running: false
    command: ["true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (root.utf8ByteLength(raw) > root.readmeCapBytes) { root.readmeState = "error"; root.readmeText = ""; return }
        try {
          var parsed = JSON.parse(raw)
          if (parsed && parsed.ok === true) {
            root.readmeText = String(parsed.text || "")
            root.readmeUrl = String(parsed.url || "")
            root.readmeStale = parsed.stale === true
            root.readmeState = "ok"
          } else {
            root.readmeText = ""
            root.readmeState = parsed && parsed.reason === "not-found" ? "missing" : "error"
          }
        } catch (e) { root.readmeText = ""; root.readmeState = "error" }
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && root.readmeState === "loading") root.readmeState = "error"
    }
  }

  // -------------------------------------------------------------- images
  // One download at a time, for the plugin whose README is showing. Results are
  // keyed by the URL as written in the README; the helper normalises it.
  property var images: ({})
  property int imageRevision: 0
  property var imageQueue: []
  property string imagePlugin: ""
  readonly property int imageCapBytes: 8192

  function imageState(url) {
    var r = root.imageRevision
    return root.images[url] || null
  }

  function requestImages(pluginId, urls) {
    var clean = Sanitise.pluginId(pluginId)
    if (clean === "") return
    if (clean !== root.imagePlugin) { root.images = ({}); root.imagePlugin = clean; root.imageRevision++ }
    var queue = []
    for (var i = 0; i < urls.length && queue.length < 24; i++) {
      var u = String(urls[i] || "")
      if (u === "" || root.images[u]) continue
      var next = ({})
      for (var k in root.images) next[k] = root.images[k]
      next[u] = { state: "queued" }
      root.images = next
      queue.push(u)
    }
    root.imageQueue = root.imageQueue.concat(queue)
    root.imageRevision++
    root.pumpImages()
  }

  function pumpImages() {
    if (imageProc.running || root.imageQueue.length === 0 || root.helperPath === "") return
    var url = root.imageQueue[0]
    root.imageQueue = root.imageQueue.slice(1)
    root.setImage(url, { state: "loading" })
    imageProc.url = url
    imageProc.command = ["timeout", "-k", "2", "60", root.helperPath, "--budget", "45",
                         "image", "--plugin", root.imagePlugin, "--url", url]
    imageProc.running = true
  }

  function setImage(url, value) {
    var next = ({})
    for (var k in root.images) next[k] = root.images[k]
    next[url] = value
    root.images = next
    root.imageRevision++
  }

  Process {
    id: imageProc
    property string url: ""
    running: false
    command: ["true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        var result = { state: "error" }
        if (root.utf8ByteLength(raw) <= root.imageCapBytes) {
          try {
            var parsed = JSON.parse(raw)
            if (parsed && parsed.ok === true && /^\/[^\0]+\.(png|jpg|gif|webp)$/.test(String(parsed.path || ""))) {
              result = { state: "ok", path: String(parsed.path), width: Number(parsed.width) || 0,
                         height: Number(parsed.height) || 0, format: String(parsed.format || "") }
            } else {
              result = { state: "refused", reason: parsed && parsed.reason ? String(parsed.reason) : "error" }
            }
          } catch (e) { result = { state: "error" } }
        }
        root.setImage(imageProc.url, result)
      }
    }
    onExited: function () { Qt.callLater(root.pumpImages) }
  }

  // ------------------------------------------------------------- actions

  property string clipPayload: ""
  Process {
    id: clipProc
    running: false
    command: ["wl-copy"]
    stdinEnabled: false
    onStarted: { write(root.clipPayload); root.clipPayload = ""; stdinEnabled = false }
  }
  function copy(text) {
    root.clipPayload = String(text || "")
    clipProc.stdinEnabled = true
    clipProc.running = true
  }
}
