import QtQuick
import qs.Commons

// One metric: small label, the window delta as the hero, context underneath.
Rectangle {
  id: root

  property string label: ""
  property string value: ""
  property string sub: ""
  property string trend: ""
  property color ink: Color.popups.text
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property bool emphasis: false

  radius: Style.space(6)
  color: Qt.rgba(ink.r, ink.g, ink.b, 0.045)
  implicitHeight: col.implicitHeight + Style.space(20)

  Column {
    id: col
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(10)
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      renderType: Text.NativeRendering
      text: root.label
      color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      elide: Text.ElideRight
      width: parent.width
    }
    Text {
      textFormat: Text.PlainText
      renderType: Text.NativeRendering
      text: root.value
      color: root.emphasis ? root.accent : root.ink
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
      font.bold: true
      elide: Text.ElideRight
      width: parent.width
    }
    Text {
      textFormat: Text.PlainText
      renderType: Text.NativeRendering
      text: root.sub
      color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
      width: parent.width
    }
    Text {
      textFormat: Text.PlainText
      renderType: Text.NativeRendering
      visible: root.trend !== ""
      text: root.trend
      color: root.trend.charAt(0) === "−" ? Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.55) : root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      width: parent.width
    }
  }
}
