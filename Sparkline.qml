import QtQuick
import qs.Commons

// Miniature series for a table row: line only, dashed where interpolated.
Item {
  id: root
  property var buckets: []
  property color color: Color.accent
  property color surface: Color.popups.background

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    renderTarget: Canvas.Image
    renderStrategy: Canvas.Immediate

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var arr = root.buckets || []
      var n = arr.length
      if (n < 2) return
      var lo = 0, hi = 0
      for (var i = 0; i < n; i++) {
        var v = Number(arr[i].v) || 0
        if (v < lo) lo = v
        if (v > hi) hi = v
      }
      if (hi === lo) hi = lo + 1
      var pad = 3
      function x(i) { return pad + (i / (n - 1)) * (width - pad * 2) }
      function y(v) { return pad + (1 - (v - lo) / (hi - lo)) * (height - pad * 2) }
      var zy = y(0)
      ctx.beginPath(); ctx.moveTo(0, Math.round(zy) + 0.5); ctx.lineTo(width, Math.round(zy) + 0.5)
      ctx.lineWidth = 1; ctx.strokeStyle = Qt.rgba(root.color.r, root.color.g, root.color.b, 0.18); ctx.stroke()
      ctx.lineWidth = 1.5
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      var k = 0
      while (k < n) {
        var observed = Number(arr[k].c) >= 0.5
        var j = k
        while (j + 1 < n && (Number(arr[j + 1].c) >= 0.5) === observed) j++
        ctx.beginPath()
        ctx.setLineDash(observed ? [] : [3, 3])
        ctx.strokeStyle = observed ? root.color : Qt.rgba(root.color.r, root.color.g, root.color.b, 0.5)
        for (var m = Math.max(0, k - 1); m <= j; m++) {
          if (m === Math.max(0, k - 1)) ctx.moveTo(x(m), y(Number(arr[m].v) || 0))
          else ctx.lineTo(x(m), y(Number(arr[m].v) || 0))
        }
        ctx.stroke()
        ctx.setLineDash([])
        k = j + 1
      }
      ctx.beginPath(); ctx.arc(x(n - 1), y(Number(arr[n - 1].v) || 0), 2.5, 0, Math.PI * 2)
      ctx.fillStyle = root.color; ctx.fill()
    }
  }

  Connections {
    target: root
    function onBucketsChanged() { canvas.requestPaint() }
    function onColorChanged() { canvas.requestPaint() }
    function onWidthChanged() { canvas.requestPaint() }
    function onHeightChanged() { canvas.requestPaint() }
  }
}
