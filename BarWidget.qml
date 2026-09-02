import QtQuick
import qs.Commons
import qs.Ui
import "Sanitise.js" as Sanitise

// Bar slot. The panel is loaded eagerly so the label is live without opening it.
BarWidget {
  id: root
  moduleName: "kairos.plugin-analytics"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  function refresh() { if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh() }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: true

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // The shell renders these two through its own AutoText elements, so they are
  // scrubbed here wholesale even though the panel already sanitised its inputs.
  WidgetButton {
    id: button
    bar: root.bar
    text: Sanitise.barSafe(panelLoader.item ? panelLoader.item.label : "▲ –")
    tooltipText: Sanitise.barSafe(panelLoader.item ? panelLoader.item.tooltip : "Plugin Analytics")
    hasVisualContent: true
    labelVisible: true
    horizontalMargin: 12
    onPressed: function (b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
