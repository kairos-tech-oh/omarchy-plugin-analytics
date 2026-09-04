import QtQuick
import qs.Commons
import "Model.js" as Model

// A marketplace-style card: the listing preview, dimmed, with the trend drawn
// over it; the name and description below; current counts along the bottom.
Rectangle {
  id: root

  property var plugin: ({})
  property var entry: null
  property string metric: "views"
  property var buckets: []
  property var image: null            // Store.imageState(preview)
  property color ink: Color.menu.text
  property color accent: Color.accent
  property color ground: Color.menu.background
  property string fontFamily: Style.font.menuFamily

  signal clicked()

  readonly property var totals: plugin && plugin.totals ? plugin.totals : ({})
  readonly property var listing: plugin && plugin.listing ? plugin.listing : ({})
  readonly property var m: entry && entry[metric] ? entry[metric] : null
  readonly property var delta: Model.entryDelta(m)
  readonly property bool hasImage: image !== null && image.state === "ok" && image.width > 0 && artImage.status !== Image.Error
  readonly property color cardAccent: Model.accentColor(plugin ? plugin.accent : "", accent)
  readonly property int openIssues: totals.issues ? Number(totals.issues) : 0
  readonly property string warningText: {
    if (!listing || !listing.verification) return ""
    if (listing.upstream === "failed") return "Marketplace compatibility check failed"
    if (listing.upstream === "unreachable") return "Marketplace could not reach the repository"
    if (listing.verification === "unverified") return listing.coverage === "update-unverified" ? "Latest update not yet verified" : "Listing is unverified"
    return ""
  }

  function ink_(a) { return Qt.rgba(ink.r, ink.g, ink.b, a) }

  radius: Style.space(8)
  color: hover.containsMouse ? ink_(0.07) : ink_(0.045)
  border.width: 1
  border.color: hover.containsMouse ? Qt.rgba(accent.r, accent.g, accent.b, 0.5) : ink_(0.10)
  implicitHeight: art.height + body.implicitHeight + Style.space(24)
  clip: true

  Behavior on color { ColorAnimation { duration: 120 } }
  Behavior on border.color { ColorAnimation { duration: 120 } }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }

  // ------------------------------------------------------------- artwork
  Item {
    id: art
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: Math.round(width * 9 / 16)
    clip: true

    // Placeholder in the listing's own accent, the way the marketplace draws it.
    Rectangle {
      anchors.fill: parent
      visible: !root.hasImage
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(root.cardAccent.r, root.cardAccent.g, root.cardAccent.b, 0.30) }
        GradientStop { position: 1.0; color: Qt.rgba(root.cardAccent.r, root.cardAccent.g, root.cardAccent.b, 0.06) }
      }
      Text {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -Style.space(10)
        textFormat: Text.PlainText
        renderType: Text.NativeRendering
        text: root.plugin && root.plugin.initials ? root.plugin.initials : ""
        color: Qt.rgba(root.cardAccent.r, root.cardAccent.g, root.cardAccent.b, 0.85)
        font.family: root.fontFamily
        font.pixelSize: Style.font.displayLarge
        font.bold: true
      }
    }

    Image {
      id: artImage
      anchors.fill: parent
      visible: root.hasImage
      source: root.image !== null && root.image.state === "ok" ? "file://" + root.image.path : ""
      asynchronous: true
      cache: false
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: 720
      smooth: true
      opacity: 0.42
    }

    // Dark wash so the chart and figures read over any artwork.
    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(root.ground.r, root.ground.g, root.ground.b, 0.15) }
        GradientStop { position: 1.0; color: Qt.rgba(root.ground.r, root.ground.g, root.ground.b, 0.80) }
      }
    }

    Sparkline {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(6)
      height: Math.round(parent.height * 0.62)
      buckets: root.buckets
      color: root.accent
      surface: root.ground
      fill: true
      lineWidth: 2
    }

    Row {
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.margins: Style.space(8)
      spacing: Style.space(4)
      Badge { visible: root.warningText !== ""; kind: "warning"; tooltip: root.warningText }
      Badge { visible: root.openIssues > 0; kind: "alert"; tooltip: root.openIssues === 1 ? "1 open issue" : root.openIssues + " open issues" }
    }

    Column {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(8)
      spacing: 0
      Text {
        anchors.right: parent.right
        textFormat: Text.PlainText
        renderType: Text.NativeRendering
        text: root.delta === null ? "–" : Model.signed(root.delta)
        color: root.ink
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        anchors.right: parent.right
        textFormat: Text.PlainText
        renderType: Text.NativeRendering
        text: root.metric
        color: root.ink_(0.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ---------------------------------------------------------------- body
  Column {
    id: body
    anchors.top: art.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: Style.space(12)
    anchors.topMargin: Style.space(10)
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      renderType: Text.NativeRendering
      width: parent.width
      text: root.plugin ? String(root.plugin.name || root.plugin.id || "") : ""
      color: root.ink
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
        var parts = []
        if (root.plugin && root.plugin.category) parts.push(root.plugin.category)
        if (root.listing && root.listing.version && root.listing.version !== "unknown") parts.push("v" + root.listing.version)
        if (root.listing && root.listing.verification === "verified") parts.push("verified")
        return parts.join(" · ")
      }
      color: root.ink_(0.55)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
    Text {
      textFormat: Text.PlainText
      renderType: Text.NativeRendering
      width: parent.width
      text: root.plugin ? String(root.plugin.description || "") : ""
      color: root.ink_(0.7)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
      visible: text !== ""
    }

    Item { width: 1; height: Style.space(2) }

    // Current counts, three across: a value over its label, ink not colour.
    Grid {
      id: stats
      width: parent.width
      columns: 3
      columnSpacing: Style.space(8)
      rowSpacing: Style.space(6)
      readonly property real cellWidth: (width - columnSpacing * (columns - 1)) / columns
      readonly property var items: [
        { v: Model.compact(root.totals.views || 0), l: "views" },
        { v: Model.compact(root.totals.copies || 0), l: "copies" },
        { v: Model.compact(root.totals.hearts || 0), l: "hearts" },
        { v: Model.compact(root.totals.stars || 0), l: "stars" },
        { v: root.totals.rank ? "#" + Math.round(Number(root.totals.rank)) : "–", l: "rank" },
        { v: String(root.openIssues) + ((root.totals.prs || 0) ? " + " + root.totals.prs : ""), l: (root.totals.prs || 0) ? "issues + PRs" : "issues" }
      ]
      Repeater {
        model: stats.items
        Column {
          required property var modelData
          width: stats.cellWidth
          spacing: 0
          Text {
            textFormat: Text.PlainText
            renderType: Text.NativeRendering
            width: parent.width
            text: modelData.v
            color: root.metric === modelData.l ? root.accent : root.ink
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            renderType: Text.NativeRendering
            width: parent.width
            text: modelData.l
            color: root.ink_(0.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
