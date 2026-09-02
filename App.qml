import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Sanitise.js" as Sanitise
import "Markdown.js" as Markdown

// The app window: a real toplevel Hyprland tiles, painted translucent over the
// wallpaper. Opened with `omarchy-shell shell toggle kairos.plugin-analytics`.
Item {
  id: root

  // ------------------------------------------------------------ lifecycle
  readonly property bool opened: window.visible
  property var shell: null
  readonly property string moduleId: "kairos.plugin-analytics"
  property bool closingFromHost: false

  function open(payloadJson) {
    root.closingFromHost = false
    window.visible = true
    root.nowMs = Date.now()
    root.authorDraft = store.author()
    store.refreshSummary()
    var wanted = ""
    try {
      var payload = JSON.parse(String(payloadJson || "{}"))
      if (payload && typeof payload === "object") wanted = Sanitise.pluginId(payload.plugin)
    } catch (error) { wanted = "" }
    if (wanted !== "") root.selectPlugin(wanted)
    store.requestSeries(root.windowName, root.metric)
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.closingFromHost = true
    window.visible = false
    root.closingFromHost = false
  }

  function requestClose() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.moduleId)
    else root.close()
  }

  function notifyHostClosed() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.moduleId)
  }

  function toggle() { root.opened ? root.requestClose() : root.open("{}") }

  Store {
    id: store
    onRevisionChanged: {
      if (root.authorDraft === "") root.authorDraft = store.author()
      if (root.opened) store.requestSeries(root.windowName, root.metric)
    }
    onReadmeStateChanged: {
      root.readmeBlocks = store.readmeState === "ok" ? Markdown.parse(store.readmeText, 600) : []
      if (store.readmeState !== "loading" && root.scrollTopPending) {
        root.scrollTopPending = false
        Qt.callLater(function () { mainFlick.contentY = 0 })
      }
    }
  }

  // ---------------------------------------------------------------- theme
  // 0.90 is the alpha Theme Forge measured Omakade's window ground at; the
  // wallpaper reads through, while every data surface is painted on top.
  readonly property real surfaceAlpha: 0.90
  readonly property color ground: Color.menu.background
  readonly property color surface: Qt.rgba(ground.r, ground.g, ground.b, surfaceAlpha)
  readonly property color ink: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color dim: Qt.rgba(ink.r, ink.g, ink.b, 0.55)
  readonly property color faint: Qt.rgba(ink.r, ink.g, ink.b, 0.28)
  readonly property color hairline: Qt.rgba(ink.r, ink.g, ink.b, 0.12)
  readonly property string uiFont: Style.font.menuFamily
  readonly property string monoFont: "monospace"

  function ink_(a) { return Qt.rgba(ink.r, ink.g, ink.b, a) }

  // ---------------------------------------------------------------- state
  property string windowName: "7d"
  property string metric: "views"
  property string selectedId: ""
  property real nowMs: Date.now()
  property var readmeBlocks: []
  property real copiedAt: 0
  property string authorDraft: ""

  onWindowNameChanged: if (opened) store.requestSeries(windowName, metric)
  onMetricChanged: if (opened) store.requestSeries(windowName, metric)

  // The README arrives after the selection, so the scroll reset has to wait for it.
  property bool scrollTopPending: false

  function selectPlugin(id) {
    root.selectedId = id
    mainFlick.contentY = 0
    root.scrollTopPending = id !== ""
    if (id !== "") store.requestReadme(id, false)
  }

  function selected() { return root.selectedId === "" ? null : store.plugin(root.selectedId) }

  function win() { return store.win(root.windowName) }

  function entryFor(id) {
    var w = win()
    return w && w.plugins ? (w.plugins[id] || null) : null
  }

  function asOfText() {
    var d = store.summary()
    var t = root.nowMs
    if (!d || !d.asOf) return "no snapshot yet"
    var age = t / 1000 - Number(d.asOf)
    return "as of " + Model.relTime(age) + (age > 2.5 * 3600 ? " · stale" : "")
  }

  function openExternal(url) {
    var safe = Model.safeExternalUrl(url)
    if (safe !== "") Qt.openUrlExternally(safe)
  }

  function copyInstall(repo) {
    store.copy(Model.installCommand(repo))
    root.copiedAt = Date.now()
  }

  function moveSelection(delta) {
    var list = store.plugins()
    var ids = [""]
    for (var i = 0; i < list.length; i++) ids.push(list[i].id)
    var idx = ids.indexOf(root.selectedId)
    var next = Math.max(0, Math.min(ids.length - 1, (idx < 0 ? 0 : idx) + delta))
    root.selectPlugin(ids[next])
  }

  // Tile text for either the aggregate or the selected plugin.
  function tileValue(name) {
    var w = win()
    if (!w) return "–"
    var src = root.selectedId === "" ? w.agg : entryFor(root.selectedId)
    if (!src) return "–"
    if (name === "stars") {
      var s = src.stars
      if (!s) return "–"
      if (root.windowName === "all") return Model.compact(root.selectedId === "" ? s.total : s.now)
      return s.delta !== null && s.delta !== undefined ? Model.signed(s.delta) : "–"
    }
    var a = src[name]
    if (!a) return "–"
    if (root.windowName === "all") {
      if (root.selectedId === "") return Model.compact(a.total)
      var p = selected()
      return Model.compact(p && p.totals ? p.totals[name] : 0)
    }
    return Model.signed(a.net)
  }

  function tileSub(name) {
    var w = win()
    if (!w) return ""
    var p = selected()
    var totals = root.selectedId === "" ? null : (p ? p.totals : null)
    if (name === "stars") {
      if (root.selectedId === "") return Model.compact(w.agg.stars ? w.agg.stars.total : 0) + " total"
      return Model.compact(totals ? totals.stars : 0) + " on GitHub"
    }
    var a = root.selectedId === "" ? w.agg[name] : (entryFor(root.selectedId) || {})[name]
    if (!a) return ""
    var total = root.selectedId === "" ? a.total : (totals ? totals[name] : 0)
    if (root.windowName === "all") return Model.signed(a.net) + " since " + Model.dateShort(w.agg.since)
    var sub = Model.compact(total) + " total"
    if (name === "copies") {
      var rate = root.selectedId === "" ? w.agg.copyRate : (entryFor(root.selectedId) || {}).copyRate
      if (rate !== null && rate !== undefined) sub += " · " + Model.rate(rate) + " rate"
    }
    return sub
  }

  function tileTrend(name) {
    var w = win()
    if (!w || root.windowName === "all" || name === "stars") return ""
    var src = root.selectedId === "" ? w.agg : entryFor(root.selectedId)
    return src ? Model.trendText(src[name]) : ""
  }

  function rankText() {
    var e = entryFor(root.selectedId)
    if (!e || !e.rank || !e.rank.now) return "–"
    return "#" + Math.round(Number(e.rank.now))
  }

  function rankSub() {
    var e = entryFor(root.selectedId)
    var d = store.summary()
    if (!e || !e.rank) return ""
    var parts = []
    if (d && d.nr) parts.push("of " + Number(d.nr).toLocaleString() + " plugins")
    if (e.rank.improvement) parts.push((e.rank.improvement > 0 ? "↑" : "↓") + Math.abs(e.rank.improvement) + " places")
    return parts.join(" · ")
  }

  Timer {
    interval: 60000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // --------------------------------------------------------------- window
  FloatingWindow {
    id: window
    title: "Plugin Analytics"
    color: root.surface
    implicitWidth: 1200
    implicitHeight: 800
    minimumSize: Qt.size(780, 540)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost) root.notifyHostClosed()
    }

    FocusScope {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.AfterItem
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) { root.requestClose(); event.accepted = true }
        else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_R) { store.collect(true); event.accepted = true }
        else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) { root.moveSelection(1); event.accepted = true }
        else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) { root.moveSelection(-1); event.accepted = true }
      }

      Item {
        id: content
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding

        // ------------------------------------------------------- header
        Item {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.max(titleCol.implicitHeight, controls.implicitHeight)

          Column {
            id: titleCol
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            width: parent.width - controls.width - Style.space(16)

            Text {
              textFormat: Text.PlainText
              renderType: Text.NativeRendering
              text: "Plugin Analytics"
              color: root.ink
              font.family: root.uiFont
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              renderType: Text.NativeRendering
              width: parent.width
              text: {
                var r = store.resolvedState()
                var parts = []
                if (store.author() !== "") parts.push(store.author())
                if (r.ok) parts.push(r.count + (r.count === 1 ? " plugin" : " plugins"))
                parts.push(store.collecting ? "collecting…" : root.asOfText())
                return parts.join(" · ")
              }
              color: root.dim
              font.family: root.uiFont
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }

          Row {
            id: controls
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            ButtonGroup {
              options: Model.WINDOWS
              value: root.windowName
              foreground: root.ink
              background: root.ground
              accent: root.accent
              fontFamily: root.uiFont
              fontSize: Style.font.bodySmall
              focusable: false
              anchors.verticalCenter: parent.verticalCenter
              onChanged: function (v) { root.windowName = v }
            }
            Button {
              text: store.collecting ? "Collecting…" : "Refresh"
              foreground: root.ink
              accent: root.accent
              bordered: true
              enabled: !store.collecting
              tooltipText: "Take a snapshot now (Ctrl+R)"
              anchors.verticalCenter: parent.verticalCenter
              onClicked: store.collect(true)
            }
            Button {
              text: "×"
              foreground: root.ink
              accent: root.accent
              fontSize: Style.font.title
              tooltipText: "Close (Esc)"
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.requestClose()
            }
          }
        }

        Rectangle {
          id: headerRule
          anchors.top: header.bottom
          anchors.topMargin: Style.space(12)
          anchors.left: parent.left
          anchors.right: parent.right
          height: 1
          color: root.hairline
        }

        // --------------------------------------------------------- body
        Item {
          anchors.top: headerRule.bottom
          anchors.topMargin: Style.space(14)
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right

          // Sidebar: every tracked plugin, sorted by the window's delta.
          Item {
            id: sidebar
            width: Style.space(370)
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left

            Flickable {
              anchors.fill: parent
              contentWidth: width
              contentHeight: sideCol.implicitHeight
              clip: true
              interactive: contentHeight > height
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              Column {
                id: sideCol
                width: parent.width
                spacing: Style.space(4)

                Rectangle {
                  width: parent.width
                  radius: Style.space(6)
                  color: root.selectedId === "" ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.10) : (allHover.containsMouse ? root.ink_(0.05) : "transparent")
                  border.width: root.selectedId === "" ? 1 : 0
                  border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.5)
                  implicitHeight: allCol.implicitHeight + Style.space(16)

                  MouseArea { id: allHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.selectPlugin("") }

                  Row {
                    id: allCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: Style.space(8); anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10)
                    spacing: Style.space(10)
                    Column {
                      width: parent.width - allDelta.width - parent.spacing
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(1)
                      Text {
                        textFormat: Text.PlainText; renderType: Text.NativeRendering
                        text: "All plugins"
                        color: root.selectedId === "" ? root.accent : root.ink
                        font.family: root.uiFont; font.pixelSize: Style.font.subtitle; font.bold: true
                      }
                      Text {
                        textFormat: Text.PlainText; renderType: Text.NativeRendering
                        width: parent.width
                        text: Model.coverageCaption(root.win(), root.windowName)
                        color: root.dim
                        font.family: root.uiFont; font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                    Text {
                      id: allDelta
                      textFormat: Text.PlainText; renderType: Text.NativeRendering
                      anchors.verticalCenter: parent.verticalCenter
                      text: { var w = root.win(); return w && w.agg && w.agg[root.metric] ? Model.signed(w.agg[root.metric].net) : "–" }
                      color: root.ink
                      font.family: root.uiFont; font.pixelSize: Style.font.heading; font.bold: true
                      horizontalAlignment: Text.AlignRight
                      width: Style.space(64)
                    }
                  }
                }

                Repeater {
                  model: Model.pluginsSorted(root.win(), store.plugins(), root.metric)
                  PluginRow {
                    required property var modelData
                    width: sideCol.width
                    plugin: modelData.plugin
                    entry: modelData.entry
                    metric: root.metric
                    buckets: store.seriesMatches(root.windowName, root.metric) ? store.seriesFor(modelData.plugin.id) : []
                    focused: root.selectedId === modelData.plugin.id
                    ink: root.ink
                    accent: root.accent
                    surface: root.ground
                    fontFamily: root.uiFont
                    onClicked: root.selectPlugin(root.selectedId === modelData.plugin.id ? "" : modelData.plugin.id)
                  }
                }

                Text {
                  textFormat: Text.PlainText; renderType: Text.NativeRendering
                  width: parent.width
                  visible: !store.resolvedState().ok
                  text: store.author() === "" ? "Set an author on the right to start tracking." : "No plugins resolved yet."
                  color: root.dim
                  font.family: root.uiFont; font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  topPadding: Style.space(8)
                }
              }
            }
          }

          Rectangle {
            id: splitRule
            anchors.left: sidebar.right
            anchors.leftMargin: Style.space(14)
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: root.hairline
          }

          // Main: overview or one plugin.
          Flickable {
            id: mainFlick
            anchors.left: splitRule.right
            anchors.leftMargin: Style.space(18)
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            contentWidth: width
            contentHeight: mainCol.implicitHeight
            clip: true
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: mainCol
              width: parent.width
              spacing: Style.space(16)

              // ------------------------------------------------ author
              Rectangle {
                width: parent.width
                visible: !store.resolvedState().ok
                radius: Style.space(6)
                color: root.ink_(0.045)
                border.width: 1
                border.color: store.resolvedState().reason === "no-author-match" ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.6) : root.hairline
                implicitHeight: setupCol.implicitHeight + Style.space(24)

                Column {
                  id: setupCol
                  anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                  anchors.margins: Style.space(12)
                  spacing: Style.space(8)
                  Text {
                    textFormat: Text.PlainText; renderType: Text.NativeRendering
                    width: parent.width
                    text: {
                      var r = store.resolvedState()
                      if (r.reason === "no-author-match") return "No plugins found for author '" + store.author() + "'"
                      if (store.collecting) return "Collecting the first snapshot…"
                      return "Track your marketplace plugins"
                    }
                    color: store.resolvedState().reason === "no-author-match" ? Color.urgent : root.ink
                    font.family: root.uiFont; font.pixelSize: Style.font.subtitle; font.bold: true
                    wrapMode: Text.WordWrap
                  }
                  Text {
                    textFormat: Text.PlainText; renderType: Text.NativeRendering
                    width: parent.width
                    text: "Enter the author exactly as the catalog lists it — the display name (e.g. kairos) or the GitHub owner from your repo URL (e.g. kairos-tech-oh)."
                    color: root.dim
                    font.family: root.uiFont; font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                  Row {
                    width: parent.width
                    spacing: Style.space(8)
                    TextField {
                      id: setupField
                      width: parent.width - setupGo.width - parent.spacing
                      text: root.authorDraft
                      placeholderText: "author or GitHub owner"
                      foreground: root.ink; accent: root.accent
                      font.family: root.uiFont; font.pixelSize: Style.font.body
                      onTextChanged: root.authorDraft = text
                      onAccepted: store.resolveAuthor(text)
                    }
                    Button {
                      id: setupGo
                      text: "Track"
                      foreground: root.ink; accent: root.accent; bordered: true
                      anchors.verticalCenter: parent.verticalCenter
                      enabled: Sanitise.author(root.authorDraft) !== "" && !store.collecting
                      onClicked: store.resolveAuthor(root.authorDraft)
                    }
                  }
                }
              }

              // ----------------------------------------- detail header
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.selectedId !== "" && store.resolvedState().ok

                Row {
                  width: parent.width
                  spacing: Style.space(10)
                  Text {
                    id: detailName
                    textFormat: Text.PlainText; renderType: Text.NativeRendering
                    text: { var p = root.selected(); return p ? p.name : "" }
                    color: root.ink
                    font.family: root.uiFont; font.pixelSize: Style.font.display; font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.width * 0.6)
                  }
                  Text {
                    textFormat: Text.PlainText; renderType: Text.NativeRendering
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                      var p = root.selected()
                      if (!p) return ""
                      var parts = [p.id]
                      if (p.category !== "") parts.push(p.category)
                      if (p.addedAt !== "") parts.push("listed " + p.addedAt)
                      if (p.matchedBy === "owner") parts.push("matched by repo owner")
                      return parts.join(" · ")
                    }
                    color: root.dim
                    font.family: root.uiFont; font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width - detailName.width - parent.spacing
                  }
                }

                Row {
                  spacing: Style.space(8)
                  Button {
                    text: "Repository ↗"
                    foreground: root.ink; accent: root.accent; bordered: true
                    fontSize: Style.font.bodySmall
                    enabled: { var p = root.selected(); return p && Model.safeExternalUrl(p.repo) !== "" }
                    tooltipText: { var p = root.selected(); return Sanitise.barSafe(p ? p.repo : "") }
                    onClicked: { var p = root.selected(); if (p) root.openExternal(p.repo) }
                  }
                  Button {
                    text: "Marketplace ↗"
                    foreground: root.ink; accent: root.accent; bordered: true
                    fontSize: Style.font.bodySmall
                    tooltipText: Sanitise.barSafe(Model.marketplaceUrl(root.selectedId))
                    onClicked: root.openExternal(Model.marketplaceUrl(root.selectedId))
                  }
                  Button {
                    text: Date.now() - root.copiedAt < 2000 && root.nowMs > 0 ? "Copied" : "Copy install command"
                    foreground: root.ink; accent: root.accent
                    fontSize: Style.font.bodySmall
                    enabled: { var p = root.selected(); return p && p.repo !== "" }
                    tooltipText: { var p = root.selected(); return Sanitise.barSafe(p ? Model.installCommand(p.repo) : "") }
                    onClicked: { var p = root.selected(); if (p) root.copyInstall(p.repo) }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText; renderType: Text.NativeRendering
                width: parent.width
                visible: root.selectedId === "" && store.resolvedState().ok
                text: "All plugins · " + Model.windowLabel(root.windowName) + " · " + Model.coverageCaption(root.win(), root.windowName)
                color: root.dim
                font.family: root.uiFont; font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              // ------------------------------------------------- tiles
              Row {
                id: tiles
                width: parent.width
                spacing: Style.space(10)
                visible: store.resolvedState().ok
                readonly property real tileWidth: (width - spacing * 3) / 4

                StatTile { width: tiles.tileWidth; label: "VIEWS";  value: root.tileValue("views");  sub: root.tileSub("views");  trend: root.tileTrend("views");  ink: root.ink; accent: root.accent; fontFamily: root.uiFont; emphasis: root.metric === "views" }
                StatTile { width: tiles.tileWidth; label: "COPIES"; value: root.tileValue("copies"); sub: root.tileSub("copies"); trend: root.tileTrend("copies"); ink: root.ink; accent: root.accent; fontFamily: root.uiFont; emphasis: root.metric === "copies" }
                StatTile { width: tiles.tileWidth; label: "HEARTS"; value: root.tileValue("hearts"); sub: root.tileSub("hearts"); trend: root.tileTrend("hearts"); ink: root.ink; accent: root.accent; fontFamily: root.uiFont; emphasis: root.metric === "hearts" }
                StatTile {
                  width: tiles.tileWidth
                  label: root.selectedId === "" ? "STARS" : "RANK BY VIEWS"
                  value: root.selectedId === "" ? root.tileValue("stars") : root.rankText()
                  sub: root.selectedId === "" ? root.tileSub("stars") : root.rankSub()
                  ink: root.ink; accent: root.accent; fontFamily: root.uiFont
                }
              }

              // ------------------------------------------------- chart
              Column {
                width: parent.width
                spacing: Style.space(6)
                visible: store.resolvedState().ok

                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  PanelSectionHeader {
                    text: Sanitise.barSafe(root.selectedId === "" ? "TREND" : "TREND · " + (root.selected() ? root.selected().name.toUpperCase() : "") + " VS ALL")
                    foreground: root.ink
                    fontFamily: root.uiFont
                    width: parent.width - metricGroup.width - parent.spacing
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  ButtonGroup {
                    id: metricGroup
                    options: Model.METRICS
                    value: root.metric
                    foreground: root.ink
                    background: root.ground
                    accent: root.accent
                    fontFamily: root.uiFont
                    fontSize: Style.font.caption
                    focusable: false
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: function (v) { root.metric = v }
                  }
                }
                Chart {
                  width: parent.width
                  height: Style.space(240)
                  buckets: store.seriesMatches(root.windowName, root.metric) ? store.series.agg : []
                  focusBuckets: root.selectedId !== "" && store.seriesMatches(root.windowName, root.metric) ? store.seriesFor(root.selectedId) : []
                  focusLabel: root.selected() ? root.selected().name : ""
                  primaryLabel: "all plugins"
                  unit: store.series ? Number(store.series.unit) : 3600
                  ink: root.ink; accent: root.accent; surface: root.ground; fontFamily: root.uiFont
                  opacity: store.seriesLoading && !store.seriesMatches(root.windowName, root.metric) ? 0.5 : 1
                  Behavior on opacity { NumberAnimation { duration: 160 } }
                }
                Text {
                  textFormat: Text.PlainText; renderType: Text.NativeRendering
                  width: parent.width
                  text: {
                    var d = store.summary()
                    var count = d && d.collector ? Number(d.collector.snapshotCount || 0) : 0
                    if (count < 2) return "Trends appear after the second hourly snapshot · " + (count === 1 ? "1 taken" : "none yet")
                    var s = store.series
                    if (!s || !store.seriesMatches(root.windowName, root.metric)) return ""
                    var u = Number(s.unit)
                    var unitText = u >= 604800 ? "week" : u >= 86400 ? (u / 86400) + "-day" : (u / 3600) + "-hour"
                    var parts = [root.metric + " per " + unitText.replace(/^1-/, "") + " bucket"]
                    for (var i = 0; i < s.agg.length; i++) if (Number(s.agg[i].c) < 0.5) { parts.push("dashed = estimated across a collection gap"); break }
                    return parts.join(" · ")
                  }
                  color: root.dim
                  font.family: root.uiFont; font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              // ------------------------------------------------ README
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.selectedId !== "" && store.resolvedState().ok

                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  PanelSectionHeader {
                    text: "README"
                    foreground: root.ink
                    fontFamily: root.uiFont
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - readmeRefresh.width - readmeOpen.width - parent.spacing * 2
                  }
                  Button {
                    id: readmeOpen
                    text: "Open on GitHub ↗"
                    foreground: root.ink; accent: root.accent
                    fontSize: Style.font.caption
                    visible: store.readmeState === "ok" && store.readmeId === root.selectedId
                    onClicked: { var p = root.selected(); if (p) root.openExternal(p.repo + "#readme") }
                  }
                  Button {
                    id: readmeRefresh
                    text: store.readmeState === "loading" ? "Fetching…" : "Refresh"
                    foreground: root.ink; accent: root.accent
                    fontSize: Style.font.caption
                    enabled: store.readmeState !== "loading"
                    onClicked: store.requestReadme(root.selectedId, true)
                  }
                }

                Text {
                  textFormat: Text.PlainText; renderType: Text.NativeRendering
                  width: parent.width
                  visible: store.readmeState !== "ok" || store.readmeId !== root.selectedId
                  text: {
                    if (store.readmeId !== root.selectedId) return ""
                    if (store.readmeState === "loading") return "Fetching README from the repository…"
                    if (store.readmeState === "missing") return "No README found at the repository root."
                    if (store.readmeState === "error") return "Could not fetch the README right now."
                    return ""
                  }
                  color: root.dim
                  font.family: root.uiFont; font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }

                Text {
                  textFormat: Text.PlainText; renderType: Text.NativeRendering
                  width: parent.width
                  visible: store.readmeState === "ok" && store.readmeId === root.selectedId
                  text: (store.readmeStale ? "cached copy · " : "") + store.readmeUrl + "  ·  rendered as plain text"
                  color: root.faint
                  font.family: root.uiFont; font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }

                Column {
                  width: parent.width
                  spacing: Style.space(10)
                  visible: store.readmeState === "ok" && store.readmeId === root.selectedId

                  Repeater {
                    model: root.readmeBlocks

                    Item {
                      required property var modelData
                      readonly property string kind: String(modelData.type || "para")
                      readonly property bool isCode: kind === "code" || kind === "table"
                      readonly property bool isQuote: kind === "quote"
                      readonly property bool isHeading: kind === "heading"
                      width: mainCol.width
                      implicitHeight: kind === "hr" ? Style.space(8) : blockText.implicitHeight + (isCode ? Style.space(20) : 0)

                      Rectangle {
                        visible: isCode
                        anchors.fill: parent
                        radius: Style.space(5)
                        color: root.ink_(0.06)
                      }
                      Rectangle {
                        visible: isQuote
                        x: 0; y: 0; width: 3; height: parent.height
                        color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.7)
                      }
                      Rectangle {
                        visible: kind === "hr"
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width; height: 1
                        color: root.hairline
                      }
                      Text {
                        id: blockText
                        textFormat: Text.PlainText
                        renderType: Text.NativeRendering
                        visible: kind !== "hr"
                        x: isCode ? Style.space(10) : (isQuote ? Style.space(12) : 0)
                        y: isCode ? Style.space(10) : 0
                        width: parent.width - x - (isCode ? Style.space(10) : 0)
                        text: String(modelData.text || "")
                        color: isQuote ? root.dim : (isHeading ? root.ink : root.ink_(0.88))
                        font.family: isCode ? root.monoFont : root.uiFont
                        font.pixelSize: isHeading
                          ? (modelData.level <= 1 ? Style.font.heading : modelData.level === 2 ? Style.font.title : Style.font.subtitle)
                          : (isCode ? Style.font.bodySmall : Style.font.body)
                        font.bold: isHeading
                        lineHeight: 1.25
                        wrapMode: isCode ? Text.WrapAnywhere : Text.WordWrap
                      }
                    }
                  }
                }
              }

              // ---------------------------------------------- collector
              Column {
                width: parent.width
                spacing: Style.space(6)
                visible: root.selectedId === ""

                PanelSectionHeader { text: "COLLECTOR"; foreground: root.ink; fontFamily: root.uiFont }
                Text {
                  textFormat: Text.PlainText; renderType: Text.NativeRendering
                  width: parent.width
                  text: {
                    var d = store.summary()
                    var c = d && d.collector ? d.collector : null
                    if (!c) return "No state yet. The first snapshot is taken as soon as an author is set."
                    var parts = []
                    if (c.timerActive && c.linger) parts.push("systemd user timer active with lingering — collects hourly through logouts, reboots and shell crashes")
                    else if (c.timerActive) parts.push("systemd user timer active — hourly while logged in")
                    else parts.push("in-shell hourly collection only — the bar widget sets up the persistent timer once an author resolves")
                    if (c.snapshotCount) parts.push(Model.compact(c.snapshotCount) + " snapshots since " + Model.dateLong(c.firstTs))
                    if (c.lastError) parts.push("last error: " + Sanitise.plainOneLine(c.lastError, 80))
                    return parts.join("\n")
                  }
                  color: root.dim
                  font.family: root.uiFont; font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  visible: store.resolvedState().ok
                  Text {
                    textFormat: Text.PlainText; renderType: Text.NativeRendering
                    text: "Author"
                    color: root.dim
                    font.family: root.uiFont; font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  TextField {
                    id: authorField
                    width: Style.space(320)
                    text: root.authorDraft
                    placeholderText: "author or GitHub owner"
                    foreground: root.ink; accent: root.accent
                    font.family: root.uiFont; font.pixelSize: Style.font.bodySmall
                    onTextChanged: root.authorDraft = text
                    onAccepted: store.resolveAuthor(text)
                  }
                  Button {
                    text: "Apply"
                    foreground: root.ink; accent: root.accent
                    fontSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                    enabled: Sanitise.author(root.authorDraft) !== "" && Sanitise.author(root.authorDraft) !== store.author() && !store.collecting
                    onClicked: store.resolveAuthor(root.authorDraft)
                  }
                }
              }

              Item { width: 1; height: Style.space(8) }
            }
          }
        }
      }
    }
  }
}
