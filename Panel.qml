import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Sanitise.js" as Sanitise

// Analytics panel. Reads summary.json the helper maintains, asks the helper for
// chart series on demand, and runs an hourly collect when no systemd timer does.
Panel {
  id: root
  moduleName: "kairos.plugin-analytics"
  ipcTarget: "kairos.plugin-analytics"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ------------------------------------------------------------------ paths

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

  // --------------------------------------------------------------- settings

  // The bar setting wins when set; otherwise the author the helper already knows
  // (set from the app window or a previous run) keeps the widget working.
  readonly property string settingsAuthor: Sanitise.author(setting("author", ""))
  readonly property string author: settingsAuthor !== "" ? settingsAuthor : storedAuthor()

  function storedAuthor() {
    var d = summaryData()
    return d ? Sanitise.author(d.author) : ""
  }

  function openApp() {
    if (root.bar && root.bar.shell && typeof root.bar.shell.summon === "function") {
      root.close()
      root.bar.shell.summon(root.moduleName, "{}")
    }
  }
  readonly property string barMetric: String(setting("barMetric", "views"))
  readonly property string barWindow: String(setting("barWindow", "24h"))
  readonly property string defaultWindow: String(setting("defaultWindow", "7d"))
  readonly property bool autoTimer: setting("autoTimer", true) !== false

  function updateSettings(patch) {
    var merged = Object.assign({}, root.settings || {}, patch)
    root.settings = merged
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, merged)
  }

  // ------------------------------------------------------------------ state

  property string windowName: "7d"
  property bool windowPicked: false
  property string metric: "views"
  property string focusId: ""
  property var series: null
  property bool seriesLoading: false
  property bool collecting: false
  property real lastCollectAttempt: 0
  property real nowMs: Date.now()
  property bool showSetup: false

  onDefaultWindowChanged: if (!windowPicked) windowName = defaultWindow

  readonly property color ink: Color.popups.text
  readonly property color surface: Color.popups.background
  readonly property color accent: Color.accent
  readonly property string fontFamily: Style.font.family

  function ink_(a) { return Qt.rgba(ink.r, ink.g, ink.b, a) }

  // Reading the revision inside the function is what makes bindings re-run.
  function summaryData() {
    var revision = summaryReader.revision
    return summaryReader.record
  }

  function win() {
    var d = summaryData()
    return d && d.windows ? (d.windows[root.windowName] || null) : null
  }

  function plugins() {
    var d = summaryData()
    var out = []
    var list = d && d.plugins ? d.plugins : []
    for (var i = 0; i < list.length && i < 50; i++) {
      var p = list[i]
      var id = Sanitise.pluginId(p.id)
      if (id === "") continue
      out.push({ id: id, name: Sanitise.plainOneLine(p.name || id, 60), repo: String(p.repo || ""),
                 category: Sanitise.plainOneLine(p.category, 30), matchedBy: String(p.matchedBy || ""),
                 totals: p.totals || {}, firstTs: p.firstTs,
                 listing: p.listing && typeof p.listing === "object" ? p.listing : ({}) })
    }
    return out
  }

  function resolvedState() {
    var d = summaryData()
    if (!d) return { ok: false, reason: root.author === "" ? "no-author" : "no-data" }
    var r = d.resolved || {}
    return { ok: r.ok === true, reason: String(r.reason || (r.ok ? "" : "no-data")), count: Number(r.count || 0) }
  }

  function asOfText() {
    var d = summaryData()
    var t = root.nowMs
    if (!d || !d.asOf) return "no snapshot yet"
    var age = t / 1000 - Number(d.asOf)
    var text = "as of " + Model.relTime(age)
    if (age > 2.5 * 3600) text += " · stale"
    return text
  }

  // ---------------------------------------------------------- bar exports

  readonly property string label: Sanitise.barSafe(labelSource())
  readonly property string tooltip: Sanitise.barSafe(tooltipSource())

  function labelSource() {
    var d = summaryData()
    if (!d || !d.windows || !d.windows[root.barWindow]) return "▲ –"
    var a = d.windows[root.barWindow].agg ? d.windows[root.barWindow].agg[root.barMetric] : null
    if (!a) return "▲ –"
    var n = Math.round(Number(a.net) || 0)
    return (n < 0 ? "▼ " : "▲ ") + Model.compact(Math.abs(n))
  }

  function tooltipSource() {
    var d = summaryData()
    if (!d || !d.windows || !d.windows[root.barWindow]) return "Plugin Analytics — set your author to start tracking"
    var w = d.windows[root.barWindow]
    var parts = [root.barWindow]
    var ms = ["views", "copies", "hearts"]
    for (var i = 0; i < ms.length; i++) if (w.agg && w.agg[ms[i]]) parts.push(Model.signed(w.agg[ms[i]].net) + " " + ms[i])
    var rows = Model.pluginsSorted(w, root.plugins(), root.barMetric)
    var top = []
    for (var j = 0; j < rows.length && j < 4; j++) top.push(rows[j].plugin.name + " " + Model.signed(rows[j].delta))
    return parts.join(" · ") + (top.length ? "  —  " + top.join(", ") : "")
  }

  // ---------------------------------------------------------------- collect

  function maybeCollect(force) {
    if (root.helperPath === "" || collectProc.running || root.author === "") return
    var d = summaryData()
    var now = Date.now() / 1000
    if (!force) {
      var asOf = d && d.asOf ? Number(d.asOf) : 0
      var timerActive = d && d.collector && d.collector.timerActive === true
      if (timerActive && asOf && now - asOf < 2 * 3600) return
      if (asOf && now - asOf < 3600) return
      if (root.lastCollectAttempt > 0 && now - root.lastCollectAttempt >= 0 && now - root.lastCollectAttempt < 600) return
    }
    root.lastCollectAttempt = now
    collectProc.command = ["timeout", "-k", "5", "200", root.helperPath, "--budget", "150",
                           "collect", "--author", root.author].concat(force ? ["--force"] : [])
    root.collecting = true
    collectProc.running = true
  }

  function resolveAuthor() {
    if (root.helperPath === "" || collectProc.running || root.author === "") return
    root.lastCollectAttempt = Date.now() / 1000
    collectProc.command = ["timeout", "-k", "5", "200", root.helperPath, "--budget", "150",
                           "resolve", "--author", root.author]
    root.collecting = true
    collectProc.running = true
  }

  // The author is install-time configuration: `omarchy bar set <id> author <name>`
  // (or the bar settings UI). When it changes, re-resolve against the catalog.
  readonly property string setAuthorCommand: "omarchy bar set kairos.plugin-analytics author <your-author-or-github-owner>"
  property string lastResolvedFor: ""

  onSettingsAuthorChanged: {
    if (root.settingsAuthor !== "" && root.settingsAuthor !== root.lastResolvedFor && root.settingsAuthor !== root.storedAuthor()) {
      root.lastResolvedFor = root.settingsAuthor
      root.focusId = ""
      root.timerSetupTried = false
      Qt.callLater(root.resolveAuthor)
    }
  }

  function copySetAuthor() {
    root.clipPayload = root.setAuthorCommand
    clipProc.stdinEnabled = true
    clipProc.running = true
  }

  Process {
    id: collectProc
    running: false
    command: ["true"]
    onExited: function (exitCode) {
      root.collecting = false
      if (exitCode !== 0) console.warn("plugin-analytics", "collect exited", exitCode)
      summaryReader.requestRead()
      Qt.callLater(root.maybeEnsureTimer)
    }
  }

  // The timer is what makes history survive logouts and reboots, so it is set up
  // automatically once an author resolves; a setting turns that off.
  property bool timerSetupTried: false
  property bool timerSettingUp: false

  function timerState() {
    var d = summaryData()
    var c = d && d.collector ? d.collector : null
    return { active: c ? c.timerActive === true : false, linger: c ? c.linger === true : false,
             setup: c && c.timerSetup ? c.timerSetup : null }
  }

  function maybeEnsureTimer() {
    if (!root.autoTimer || root.timerSetupTried) return
    if (!root.resolvedState().ok) return
    var t = timerState()
    if (t.active && t.linger) return
    root.ensureTimer()
  }

  function ensureTimer() {
    if (root.helperPath === "" || timerProc.running) return
    root.timerSetupTried = true
    root.timerSettingUp = true
    timerProc.command = ["timeout", "-k", "5", "90", root.helperPath, "--budget", "60", "ensure-timer"]
    timerProc.running = true
  }

  Process {
    id: timerProc
    running: false
    command: ["true"]
    stdout: StdioCollector { waitForEnd: true }
    onExited: function (exitCode) {
      root.timerSettingUp = false
      if (exitCode !== 0) console.warn("plugin-analytics", "ensure-timer exited", exitCode)
      summaryReader.requestRead()
    }
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: { root.nowMs = Date.now(); root.maybeCollect(false) }
  }

  Timer {
    interval: 4000
    running: true
    repeat: false
    onTriggered: root.maybeCollect(false)
  }

  // ----------------------------------------------------------------- series

  readonly property int seriesCapBytes: 524288

  function requestSeries() {
    if (!root.opened || root.helperPath === "" || root.author === "") return
    if (seriesProc.running) { root.seriesPending = true; return }
    root.seriesLoading = true
    seriesProc.command = ["timeout", "-k", "2", "20", root.helperPath, "--budget", "15",
                          "series", "--window", root.windowName, "--metric", root.metric]
    seriesProc.running = true
  }
  property bool seriesPending: false

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
        } catch (e) {
          root.series = null
        }
      }
    }
    onExited: function (exitCode) {
      root.seriesLoading = false
      if (root.seriesPending) { root.seriesPending = false; Qt.callLater(root.requestSeries) }
    }
  }

  onWindowNameChanged: requestSeries()
  onMetricChanged: requestSeries()
  onOpenedChanged: if (opened) { root.nowMs = Date.now(); requestSeries(); summaryReader.requestRead() }

  function seriesFor(id) {
    var s = root.series
    if (!s || !s.plugins || !s.plugins[id]) return []
    return s.plugins[id]
  }

  function seriesMatches() {
    return root.series && root.series.window === root.windowName && root.series.metric === root.metric
  }

  // --------------------------------------------------------------- clipboard

  function setupCommands() {
    return "mkdir -p ~/.config/systemd/user\n"
      + "cp ~/.config/omarchy/plugins/kairos.plugin-analytics/systemd/* ~/.config/systemd/user/\n"
      + "systemctl --user daemon-reload\n"
      + "systemctl --user enable --now kairos-plugin-analytics.timer\n"
  }

  property string clipPayload: ""
  Process {
    id: clipProc
    running: false
    command: ["wl-copy"]
    stdinEnabled: false
    onStarted: { write(root.clipPayload); root.clipPayload = ""; stdinEnabled = false }
  }
  function copySetup() {
    root.clipPayload = root.setupCommands()
    clipProc.stdinEnabled = true
    clipProc.running = true
  }

  Reader {
    id: summaryReader
    path: root.summaryPath
    capBytes: 1048576
    onRevisionChanged: if (root.opened) root.requestSeries()
  }

  function openFromHotkey() { root.open() }
  function refresh() { root.maybeCollect(true) }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  // ------------------------------------------------------------------- view

  function tileValue(name) {
    var w = win()
    if (!w || !w.agg) return "–"
    if (name === "stars") {
      var s = w.agg.stars
      if (root.windowName === "all") return Model.compact(s ? s.total : 0)
      return s && s.delta !== null && s.delta !== undefined ? Model.signed(s.delta) : "–"
    }
    var a = w.agg[name]
    if (!a) return "–"
    if (root.windowName === "all") return Model.compact(a.total)
    return Model.signed(a.net)
  }

  function tileSub(name) {
    var w = win()
    if (!w || !w.agg) return ""
    if (name === "stars") {
      var s = w.agg.stars
      if (root.windowName === "all") return "GitHub stars"
      return Model.compact(s ? s.total : 0) + " total"
    }
    var a = w.agg[name]
    if (!a) return ""
    if (root.windowName === "all") return Model.signed(a.net) + " since " + Model.dateShort(w.agg.since)
    var sub = Model.compact(a.total) + " total"
    if (name === "copies" && w.agg.copyRate !== null && w.agg.copyRate !== undefined) sub += " · " + Model.rate(w.agg.copyRate) + " rate"
    return sub
  }

  function tileTrend(name) {
    var w = win()
    if (!w || !w.agg || root.windowName === "all" || name === "stars") return ""
    return Model.trendText(w.agg[name])
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(14)

          // ---------------------------------------------------------- header
          Row {
            width: parent.width
            spacing: Style.space(8)

            Column {
              width: parent.width - refreshButton.width - appButton.width - parent.spacing * 2
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                renderType: Text.NativeRendering
                width: parent.width
                text: "PLUGIN ANALYTICS"
                color: root.ink
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                renderType: Text.NativeRendering
                width: parent.width
                text: {
                  var r = root.resolvedState()
                  var parts = []
                  if (root.author !== "") parts.push(root.author)
                  if (r.ok) parts.push(r.count + (r.count === 1 ? " plugin" : " plugins"))
                  parts.push(root.collecting ? "collecting…" : root.asOfText())
                  return parts.join(" · ")
                }
                color: root.ink_(0.6)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Button {
              id: appButton
              text: "Open app"
              foreground: root.ink
              accent: root.accent
              anchors.verticalCenter: parent.verticalCenter
              tooltipText: "Full window with repository links and READMEs (SUPER + ALT + A)"
              onClicked: root.openApp()
            }

            Button {
              id: refreshButton
              text: root.collecting ? "Collecting…" : "Refresh"
              foreground: root.ink
              accent: root.accent
              bordered: true
              enabled: !root.collecting && root.author !== ""
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.maybeCollect(true)
            }
          }

          // ----------------------------------------------------------- setup
          Rectangle {
            id: setupCard
            width: parent.width
            visible: !root.resolvedState().ok
            radius: Style.space(6)
            color: root.ink_(0.045)
            border.width: 1
            border.color: root.resolvedState().reason === "no-author-match" ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.6) : root.ink_(0.12)
            implicitHeight: setupCol.implicitHeight + Style.space(24)

            Column {
              id: setupCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                renderType: Text.NativeRendering
                width: parent.width
                text: {
                  var r = root.resolvedState()
                  if (r.reason === "no-author-match") return "No plugins found for author '" + root.author + "'"
                  if (r.reason === "no-author") return "Track your marketplace plugins"
                  if (root.collecting) return "Collecting the first snapshot…"
                  return "Waiting for the first snapshot"
                }
                color: root.resolvedState().reason === "no-author-match" ? Color.urgent : root.ink
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                wrapMode: Text.WordWrap
              }
              Text {
                textFormat: Text.PlainText
                renderType: Text.NativeRendering
                width: parent.width
                text: "This widget tracks the plugins you publish. Set your author once, exactly as the catalog lists it — the display name (e.g. kairos) or the GitHub owner from your repo URLs (e.g. kairos-tech-oh):"
                color: root.ink_(0.65)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Rectangle {
                width: parent.width
                radius: Style.space(5)
                color: root.ink_(0.06)
                implicitHeight: cmdText.implicitHeight + Style.space(14)
                Text {
                  id: cmdText
                  textFormat: Text.PlainText
                  renderType: Text.NativeRendering
                  anchors.fill: parent
                  anchors.margins: Style.space(7)
                  text: root.setAuthorCommand
                  color: root.ink_(0.85)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WrapAnywhere
                }
              }
              Row {
                spacing: Style.space(8)
                Button {
                  text: "Copy command"
                  foreground: root.ink
                  accent: root.accent
                  bordered: true
                  fontSize: Style.font.caption
                  onClicked: root.copySetAuthor()
                }
                Text {
                  textFormat: Text.PlainText
                  renderType: Text.NativeRendering
                  text: "or use this widget's settings in the bar"
                  color: root.ink_(0.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }
          }

          // ---------------------------------------------------------- window
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.resolvedState().ok

            ButtonGroup {
              options: Model.WINDOWS
              value: root.windowName
              foreground: root.ink
              background: root.surface
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              focusable: false
              onChanged: function (v) { root.windowPicked = true; root.windowName = v }
            }

            Text {
              textFormat: Text.PlainText
              renderType: Text.NativeRendering
              width: parent.width
              text: Model.coverageCaption(root.win(), root.windowName)
              color: root.ink_(0.55)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // ----------------------------------------------------------- tiles
          Row {
            id: tiles
            width: parent.width
            spacing: Style.space(8)
            visible: root.resolvedState().ok
            readonly property real tileWidth: (width - spacing * 3) / 4

            StatTile { width: tiles.tileWidth; label: "VIEWS";  value: root.tileValue("views");  sub: root.tileSub("views");  trend: root.tileTrend("views");  ink: root.ink; accent: root.accent; fontFamily: root.fontFamily; emphasis: root.metric === "views" }
            StatTile { width: tiles.tileWidth; label: "COPIES"; value: root.tileValue("copies"); sub: root.tileSub("copies"); trend: root.tileTrend("copies"); ink: root.ink; accent: root.accent; fontFamily: root.fontFamily; emphasis: root.metric === "copies" }
            StatTile { width: tiles.tileWidth; label: "HEARTS"; value: root.tileValue("hearts"); sub: root.tileSub("hearts"); trend: root.tileTrend("hearts"); ink: root.ink; accent: root.accent; fontFamily: root.fontFamily; emphasis: root.metric === "hearts" }
            StatTile { width: tiles.tileWidth; label: "STARS";  value: root.tileValue("stars");  sub: root.tileSub("stars");  ink: root.ink; accent: root.accent; fontFamily: root.fontFamily }
          }

          // ----------------------------------------------------------- chart
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.resolvedState().ok

            Row {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: Sanitise.barSafe(root.focusId !== "" ? "TREND · " + root.focusName().toUpperCase() : "TREND")
                foreground: root.ink
                fontFamily: root.fontFamily
                width: parent.width - metricGroup.width - clearFocus.width - parent.spacing * 2
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: clearFocus
                visible: root.focusId !== ""
                width: visible ? implicitWidth : 0
                text: "all plugins"
                foreground: root.ink
                accent: root.accent
                fontSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.focusId = ""
              }

              ButtonGroup {
                id: metricGroup
                options: Model.METRICS
                value: root.metric
                foreground: root.ink
                background: root.surface
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                focusable: false
                anchors.verticalCenter: parent.verticalCenter
                onChanged: function (v) { root.metric = v }
              }
            }

            Chart {
              width: parent.width
              height: Style.space(170)
              buckets: root.seriesMatches() ? root.series.agg : []
              focusBuckets: root.focusId !== "" && root.seriesMatches() ? root.seriesFor(root.focusId) : []
              focusLabel: root.focusName()
              primaryLabel: "all plugins"
              unit: root.series ? Number(root.series.unit) : 3600
              ink: root.ink
              accent: root.accent
              surface: root.surface
              fontFamily: root.fontFamily
              opacity: root.seriesLoading && !root.seriesMatches() ? 0.5 : 1
              Behavior on opacity { NumberAnimation { duration: 160 } }
            }

            Text {
              textFormat: Text.PlainText
              renderType: Text.NativeRendering
              width: parent.width
              text: {
                var d = root.summaryData()
                var count = d && d.collector ? Number(d.collector.snapshotCount || 0) : 0
                if (count < 2) return "Trends appear after the second hourly snapshot · " + (count === 1 ? "1 taken" : "none yet")
                var s = root.series
                if (!s || !root.seriesMatches()) return ""
                var u = Number(s.unit)
                var unitText = u >= 604800 ? "week" : u >= 86400 ? (u / 86400) + "-day" : (u / 3600) + "-hour"
                var parts = [Model.windowLabel(root.windowName) + " · " + root.metric + " per " + unitText.replace(/^1-/, "") + " bucket"]
                var anyInterp = false
                for (var i = 0; i < s.agg.length; i++) if (Number(s.agg[i].c) < 0.5) { anyInterp = true; break }
                if (anyInterp) parts.push("dashed = estimated across a collection gap")
                return parts.join(" · ")
              }
              color: root.ink_(0.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // --------------------------------------------------------- plugins
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.resolvedState().ok

            Row {
              width: parent.width
              PanelSectionHeader {
                text: "PLUGINS"
                foreground: root.ink
                fontFamily: root.fontFamily
                width: parent.width / 2
              }
              Text {
                textFormat: Text.PlainText
                renderType: Text.NativeRendering
                width: parent.width / 2
                horizontalAlignment: Text.AlignRight
                text: "Δ " + root.metric + " · " + Model.windowLabel(root.windowName) + " · click to focus"
                color: root.ink_(0.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Repeater {
              model: Model.pluginsSorted(root.win(), root.plugins(), root.metric)

              PluginRow {
                required property var modelData
                width: contentColumn.width
                plugin: modelData.plugin
                entry: modelData.entry
                metric: root.metric
                buckets: root.seriesMatches() ? root.seriesFor(modelData.plugin.id) : []
                focused: root.focusId === modelData.plugin.id
                ink: root.ink
                accent: root.accent
                surface: root.surface
                fontFamily: root.fontFamily
                onClicked: root.focusId = root.focusId === modelData.plugin.id ? "" : modelData.plugin.id
              }
            }
          }

          // ------------------------------------------------------- collector
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "COLLECTOR"
              foreground: root.ink
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              renderType: Text.NativeRendering
              width: parent.width
              text: {
                var d = root.summaryData()
                var c = d && d.collector ? d.collector : null
                if (!c) return "No state yet. The first snapshot is taken as soon as an author is set."
                var parts = []
                if (c.timerActive && c.linger) parts.push("systemd user timer active with lingering — collects hourly through logouts, reboots and shell crashes")
                else if (c.timerActive) parts.push("systemd user timer active — hourly while you are logged in; lingering not enabled, so nothing runs after logout")
                else if (root.timerSettingUp) parts.push("setting up the hourly timer…")
                else parts.push("in-shell hourly collection only — runs while omarchy-shell does")
                if (c.timerSetup && c.timerSetup.error) parts.push("timer setup failed: " + Sanitise.plainOneLine(c.timerSetup.error, 100))
                if (c.snapshotCount) parts.push(Model.compact(c.snapshotCount) + " snapshots since " + Model.dateShort(c.firstTs))
                if (c.lastError) parts.push("last error: " + Sanitise.plainOneLine(c.lastError, 80))
                if (c.corruptLines) parts.push(c.corruptLines + " unreadable lines skipped")
                return parts.join("\n")
              }
              color: root.ink_(0.65)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(8)
              visible: !(root.timerState().active && root.timerState().linger)

              Button {
                text: root.timerSettingUp ? "Enabling…" : "Enable persistent collection"
                foreground: root.ink
                accent: root.accent
                fontSize: Style.font.caption
                bordered: true
                enabled: !root.timerSettingUp && root.author !== ""
                onClicked: root.ensureTimer()
              }
              Button {
                text: root.showSetup ? "Hide manual steps" : "Manual steps"
                foreground: root.ink
                accent: root.accent
                fontSize: Style.font.caption
                onClicked: root.showSetup = !root.showSetup
              }
              Button {
                visible: root.showSetup
                text: "Copy"
                foreground: root.ink
                accent: root.accent
                fontSize: Style.font.caption
                onClicked: root.copySetup()
              }
            }

            Rectangle {
              width: parent.width
              visible: root.showSetup
              radius: Style.space(5)
              color: root.ink_(0.05)
              implicitHeight: setupText.implicitHeight + Style.space(16)
              Text {
                id: setupText
                textFormat: Text.PlainText
                renderType: Text.NativeRendering
                anchors.fill: parent
                anchors.margins: Style.space(8)
                text: "Equivalent manual steps, user scope only:\n\n" + root.setupCommands() + "loginctl enable-linger $USER\n\nThe last line keeps your user services running after logout."
                color: root.ink_(0.8)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }
            }

            Text {
              textFormat: Text.PlainText
              renderType: Text.NativeRendering
              width: parent.width
              visible: root.resolvedState().ok
              text: "Tracking author " + root.author + " · change it with: " + root.setAuthorCommand
              color: root.ink_(0.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WrapAnywhere
            }
          }
        }
      }
    }
  }

  function focusName() {
    if (root.focusId === "") return ""
    var list = root.plugins()
    for (var i = 0; i < list.length; i++) if (list[i].id === root.focusId) return list[i].name
    return root.focusId
  }
}
