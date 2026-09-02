import QtQuick
import Quickshell.Io

// A bounded reader for one state file the helper maintains.
// FileView only watches; the read goes through dd with nofollow/nonblock.
Item {
  id: root
  visible: false

  property string path: ""
  property int capBytes: 1048576
  property var record: null
  property int revision: 0

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

  function readable() { return String(root.path || "") !== "" }

  function requestRead() {
    if (!readable() || reader.running) return
    reader.running = true
  }

  function parse(content) {
    var text = String(content || "")
    if (utf8ByteLength(text) > root.capBytes) {
      console.warn("plugin-analytics", "state file over cap, ignoring")
      root.record = null
      root.revision++
      return
    }
    if (text.replace(/^\s+|\s+$/g, "") === "") { root.record = null; root.revision++; return }
    try {
      var parsed = JSON.parse(text)
      root.record = (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : null
    } catch (error) {
      root.record = null
    }
    root.revision++
  }

  Process {
    id: reader
    running: false
    command: ["timeout", "-k", "2", "6", "dd", "if=" + root.path,
              "iflag=nofollow,nonblock,fullblock", "bs=" + String(root.capBytes + 1),
              "count=1", "status=none"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && root.record !== null) { root.record = null; root.revision++ }
    }
  }

  FileView {
    path: root.path
    watchChanges: true
    blockAllReads: true
    printErrors: false
    onFileChanged: root.requestRead()
  }

  // Floor under a missed inotify event after an atomic replace.
  Timer {
    interval: 60000
    running: root.readable()
    repeat: true
    onTriggered: root.requestRead()
  }

  onPathChanged: root.requestRead()
  Component.onCompleted: root.requestRead()
}
