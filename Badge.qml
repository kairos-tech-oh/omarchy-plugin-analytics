import QtQuick
import qs.Commons

// A small attention mark: a yellow triangle for a warning, a red disc for an
// alert. Drawn, not glyphs, so it renders the same in every bar font.
Item {
  id: root
  property string kind: "warning"   // warning | alert
  property string tooltip: ""
  property real size: Style.space(14)

  // Semantic colours on purpose: "needs attention" must read the same in every theme.
  readonly property color warnColour: "#f5d33f"
  readonly property color alertColour: "#ff5c39"

  width: size
  height: size

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    renderTarget: Canvas.Image
    renderStrategy: Canvas.Immediate
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height
      if (root.kind === "alert") {
        ctx.beginPath(); ctx.arc(w / 2, h / 2, w / 2, 0, Math.PI * 2)
        ctx.fillStyle = root.alertColour; ctx.fill()
      } else {
        ctx.beginPath(); ctx.moveTo(w / 2, 0.5); ctx.lineTo(w - 0.5, h - 1); ctx.lineTo(0.5, h - 1); ctx.closePath()
        ctx.lineJoin = "round"; ctx.lineWidth = 2; ctx.strokeStyle = root.warnColour; ctx.fillStyle = root.warnColour
        ctx.stroke(); ctx.fill()
      }
      ctx.fillStyle = root.kind === "alert" ? "#ffffff" : "#1b1b1b"
      ctx.font = "bold " + Math.round(h * 0.68) + "px sans-serif"
      ctx.textAlign = "center"; ctx.textBaseline = "middle"
      ctx.fillText("!", w / 2, root.kind === "alert" ? h / 2 + 0.5 : h * 0.62)
    }
  }

  Connections {
    target: root
    function onKindChanged() { canvas.requestPaint() }
    function onWidthChanged() { canvas.requestPaint() }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
  }

  Rectangle {
    visible: hover.containsMouse && root.tooltip !== ""
    x: -width / 2 + root.width / 2
    y: root.height + Style.space(4)
    z: 10
    width: tipText.implicitWidth + Style.space(12)
    height: tipText.implicitHeight + Style.space(8)
    radius: Style.space(4)
    color: Color.tooltip.background
    border.width: 1
    border.color: Color.tooltip.border
    Text {
      id: tipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      renderType: Text.NativeRendering
      text: root.tooltip
      color: Color.tooltip.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
