import QtQuick
import qs.Commons
import "Model.js" as Model

// One plugin in the breakdown: name and delta lead, sparkline and context follow.
Rectangle {
  id: root

  property var plugin: ({})
  property var entry: null
  property string metric: "views"
  property var buckets: []
  property bool focused: false
  property color ink: Color.popups.text
  property color accent: Color.accent
  property color surface: Color.popups.background
  property string fontFamily: Style.font.family

  signal clicked()

  readonly property var m: entry && entry[metric] ? entry[metric] : null
  readonly property string status: entry ? String(entry.status || "ok") : "untracked"
  readonly property real share: m && m.share !== undefined && m.share !== null ? Number(m.share) : -1
  readonly property var rank: entry && entry.rank ? entry.rank : null
  readonly property string matchedNote: plugin && plugin.matchedBy === "owner" ? "via repo" : ""

  function ink_(a) { return Qt.rgba(ink.r, ink.g, ink.b, a) }

  radius: Style.space(6)
  color: focused ? Qt.rgba(accent.r, accent.g, accent.b, 0.10) : (hover.containsMouse ? ink_(0.05) : "transparent")
  border.width: focused ? 1 : 0
  border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.5)
  implicitHeight: body.implicitHeight + Style.space(16)

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }

  Column {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(8)
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(4)

    Row {
      width: parent.width
      spacing: Style.space(10)

      Column {
        width: parent.width - deltaText.width - spark.width - parent.spacing * 2
        spacing: Style.space(1)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          renderType: Text.NativeRendering
          width: parent.width
          text: root.plugin ? String(root.plugin.name || root.plugin.id || "") : ""
          color: root.focused ? root.accent : root.ink
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          renderType: Text.NativeRendering
          width: parent.width
          text: {
            if (root.status === "missing") return "not in the latest stats payload"
            if (root.status === "untracked") return "no snapshots yet"
            var parts = []
            var t = root.plugin && root.plugin.totals ? root.plugin.totals : null
            if (t && t.views !== undefined && t.views !== null) parts.push(Model.compact(t.views) + " views")
            if (root.entry && root.entry.copyRate !== undefined && root.entry.copyRate !== null) parts.push(Model.rate(root.entry.copyRate) + " copy rate")
            if (root.rank && root.rank.now) {
              var r = "#" + Math.round(Number(root.rank.now))
              if (root.rank.improvement !== undefined && root.rank.improvement !== null && root.rank.improvement !== 0)
                r += " (" + (root.rank.improvement > 0 ? "↑" : "↓") + Math.abs(root.rank.improvement) + ")"
              parts.push(r)
            }
            if (root.matchedNote !== "") parts.push(root.matchedNote)
            return parts.join(" · ")
          }
          color: root.ink_(0.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        id: deltaText
        textFormat: Text.PlainText
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
        text: root.m ? Model.signed(root.m.net) : "–"
        color: root.status === "ok" ? root.ink : root.ink_(0.45)
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
        horizontalAlignment: Text.AlignRight
        width: Style.space(64)
      }

      Sparkline {
        id: spark
        width: Style.space(84)
        height: Style.space(26)
        anchors.verticalCenter: parent.verticalCenter
        buckets: root.buckets
        color: root.focused ? root.accent : root.ink_(0.55)
        surface: root.surface
      }
    }

    // Share of the author's total for this window, when the metric admits one.
    Item {
      width: parent.width
      height: Style.space(4)
      visible: root.share >= 0
      Rectangle {
        width: parent.width; height: parent.height; radius: height / 2
        color: root.ink_(0.08)
      }
      Rectangle {
        width: Math.max(0, Math.min(1, root.share / 100)) * parent.width
        height: parent.height; radius: height / 2
        color: root.focused ? root.accent : root.ink_(0.45)
        Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
      }
    }
  }
}
