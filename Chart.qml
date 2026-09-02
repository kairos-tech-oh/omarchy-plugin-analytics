import QtQuick
import qs.Commons

// Per-bucket delta chart. One primary series (accent, filled) and an optional
// focus series drawn on top; low-coverage buckets are dashed and unfilled.
Item {
  id: root

  property var buckets: []
  property var focusBuckets: []
  property string primaryLabel: "All plugins"
  property string focusLabel: ""
  property int unit: 3600
  property color ink: Color.popups.text
  property color accent: Color.accent
  property color surface: Color.popups.background
  property string fontFamily: Style.font.family
  property string metricLabel: "views"

  property int hoverIndex: -1

  readonly property bool hasFocus: focusBuckets && focusBuckets.length > 0
  readonly property real padTop: Style.space(10)
  readonly property real padBottom: Style.space(18)
  readonly property real padRight: Style.space(40)
  readonly property real plotW: Math.max(1, width - padRight)
  readonly property real plotH: Math.max(1, height - padTop - padBottom)

  function ink_(a) { return Qt.rgba(ink.r, ink.g, ink.b, a) }
  function accent_(a) { return Qt.rgba(accent.r, accent.g, accent.b, a) }

  function range() {
    var lo = 0, hi = 0
    var all = [buckets, focusBuckets]
    for (var s = 0; s < all.length; s++) {
      var arr = all[s] || []
      for (var i = 0; i < arr.length; i++) {
        var v = Number(arr[i].v)
        if (!isFinite(v)) continue
        if (v < lo) lo = v
        if (v > hi) hi = v
      }
    }
    if (hi === lo) hi = lo + 1
    var span = hi - lo
    return { lo: lo, hi: hi + span * 0.08 }
  }

  function xFor(i, n) { return n <= 1 ? plotW / 2 : (i / (n - 1)) * plotW }
  function yFor(v, r) { return padTop + (1 - (v - r.lo) / (r.hi - r.lo)) * plotH }

  function niceStep(span) {
    var raw = span / 3
    var mag = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10))
    var norm = raw / mag
    var step = norm < 1.5 ? 1 : norm < 3.5 ? 2 : norm < 7.5 ? 5 : 10
    return step * mag
  }

  function fmt(v) {
    var a = Math.abs(v)
    if (a >= 1000000) return (v / 1000000).toFixed(1).replace(/\.0$/, "") + "M"
    if (a >= 1000) return (v / 1000).toFixed(a >= 10000 ? 0 : 1).replace(/\.0$/, "") + "k"
    return String(Math.round(v * 10) / 10)
  }

  function drawSeries(ctx, arr, r, color, fill) {
    var n = arr.length
    if (n === 0) return
    var zeroY = yFor(0, r)
    // Filled area only under observed runs; dashed stroke over interpolated ones.
    var i = 0
    while (i < n) {
      var observed = Number(arr[i].c) >= 0.5
      var j = i
      while (j + 1 < n && (Number(arr[j + 1].c) >= 0.5) === observed) j++
      var from = Math.max(0, i - 1), to = j
      if (fill && observed) {
        ctx.beginPath()
        ctx.moveTo(xFor(from, n), zeroY)
        for (var k = from; k <= to; k++) ctx.lineTo(xFor(k, n), yFor(Number(arr[k].v) || 0, r))
        ctx.lineTo(xFor(to, n), zeroY)
        ctx.closePath()
        ctx.fillStyle = Qt.rgba(color.r, color.g, color.b, 0.14)
        ctx.fill()
      }
      ctx.beginPath()
      ctx.lineWidth = 2
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.setLineDash(observed ? [] : [4, 5])
      ctx.strokeStyle = observed ? color : Qt.rgba(color.r, color.g, color.b, 0.55)
      for (var m = from; m <= to; m++) {
        var x = xFor(m, n), y = yFor(Number(arr[m].v) || 0, r)
        if (m === from) ctx.moveTo(x, y); else ctx.lineTo(x, y)
      }
      ctx.stroke()
      ctx.setLineDash([])
      i = j + 1
    }
    // End marker with a surface ring, so the latest value reads as a point.
    var lx = xFor(n - 1, n), ly = yFor(Number(arr[n - 1].v) || 0, r)
    ctx.beginPath(); ctx.arc(lx, ly, 6, 0, Math.PI * 2); ctx.fillStyle = surface; ctx.fill()
    ctx.beginPath(); ctx.arc(lx, ly, 4, 0, Math.PI * 2); ctx.fillStyle = color; ctx.fill()
  }

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
      var r = root.range()
      var fontPx = Style.font.caption
      ctx.font = fontPx + "px '" + root.fontFamily + "'"

      // Recessive gridlines at nice steps, labelled on the right.
      var step = root.niceStep(r.hi - r.lo)
      var first = Math.ceil(r.lo / step) * step
      ctx.textAlign = "left"
      ctx.textBaseline = "middle"
      for (var g = first; g <= r.hi; g += step) {
        var gy = Math.round(root.yFor(g, r)) + 0.5
        ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(root.plotW, gy)
        ctx.lineWidth = 1
        ctx.strokeStyle = root.ink_(Math.abs(g) < 1e-9 ? 0.22 : 0.09)
        ctx.stroke()
        ctx.fillStyle = root.ink_(0.5)
        ctx.fillText(root.fmt(g), root.plotW + Style.space(6), gy)
      }

      if (n === 0) {
        ctx.textAlign = "center"
        ctx.fillStyle = root.ink_(0.45)
        ctx.fillText("No data yet", root.plotW / 2, root.padTop + root.plotH / 2)
        return
      }

      var primary = root.hasFocus ? root.ink_(0.35) : root.accent
      root.drawSeries(ctx, arr, r, primary, !root.hasFocus)
      if (root.hasFocus) root.drawSeries(ctx, root.focusBuckets, r, root.accent, true)

      // Time labels: first, middle, last.
      ctx.textBaseline = "alphabetic"
      ctx.fillStyle = root.ink_(0.5)
      var ty = root.height - Style.space(4)
      var idx = [0, Math.floor((n - 1) / 2), n - 1]
      var aligns = ["left", "center", "right"]
      for (var t = 0; t < idx.length; t++) {
        if (n < 3 && t === 1) continue
        ctx.textAlign = aligns[t]
        ctx.fillText(root.timeLabel(arr[idx[t]].t), root.xFor(idx[t], n), ty)
      }

      // Crosshair snaps to the hovered bucket.
      if (root.hoverIndex >= 0 && root.hoverIndex < n) {
        var hx = Math.round(root.xFor(root.hoverIndex, n)) + 0.5
        ctx.beginPath(); ctx.moveTo(hx, root.padTop); ctx.lineTo(hx, root.padTop + root.plotH)
        ctx.lineWidth = 1; ctx.strokeStyle = root.ink_(0.35); ctx.stroke()
        var series = root.hasFocus ? [[root.focusBuckets, root.accent], [arr, root.ink_(0.6)]] : [[arr, root.accent]]
        for (var s = 0; s < series.length; s++) {
          var sa = series[s][0]
          if (root.hoverIndex >= sa.length) continue
          var hy = root.yFor(Number(sa[root.hoverIndex].v) || 0, r)
          ctx.beginPath(); ctx.arc(hx, hy, 6, 0, Math.PI * 2); ctx.fillStyle = root.surface; ctx.fill()
          ctx.beginPath(); ctx.arc(hx, hy, 4, 0, Math.PI * 2); ctx.fillStyle = series[s][1]; ctx.fill()
        }
      }
    }
  }

  function timeLabel(ts) {
    var d = new Date(Number(ts) * 1000)
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var day = d.getDate() + " " + months[d.getMonth()]
    if (root.unit >= 86400) return day
    var hh = d.getHours(), mm = d.getMinutes()
    var t = (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm
    return root.unit <= 3600 * 3 && (root.buckets.length * root.unit) <= 86400 ? t : day + " " + t
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    onPositionChanged: function (mouse) {
      var n = (root.buckets || []).length
      if (n === 0) { root.hoverIndex = -1; return }
      var i = Math.round((mouse.x / root.plotW) * (n - 1))
      root.hoverIndex = Math.max(0, Math.min(n - 1, i))
    }
    onExited: root.hoverIndex = -1
  }

  // Tooltip: value leads, label follows; lists every series at this X.
  Rectangle {
    id: tip
    visible: root.hoverIndex >= 0 && root.hoverIndex < (root.buckets || []).length
    readonly property var b: visible ? root.buckets[root.hoverIndex] : null
    readonly property var f: visible && root.hasFocus && root.hoverIndex < root.focusBuckets.length ? root.focusBuckets[root.hoverIndex] : null
    readonly property real hx: visible ? root.xFor(root.hoverIndex, root.buckets.length) : 0
    x: Math.max(0, Math.min(root.plotW - width, hx - width / 2))
    y: 0
    width: tipCol.implicitWidth + Style.space(16)
    height: tipCol.implicitHeight + Style.space(10)
    radius: Style.space(5)
    color: root.surface
    border.width: 1
    border.color: root.ink_(0.22)

    Column {
      id: tipCol
      anchors.centerIn: parent
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        renderType: Text.NativeRendering
        text: tip.b ? root.timeLabel(tip.b.t) + (Number(tip.b.c) < 0.5 ? "  ·  interpolated" : "") : ""
        color: root.ink_(0.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        textFormat: Text.PlainText
        renderType: Text.NativeRendering
        visible: tip.f !== null
        text: tip.f ? root.fmt(Number(tip.f.v) || 0) + "  " + root.focusLabel : ""
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Text {
        textFormat: Text.PlainText
        renderType: Text.NativeRendering
        text: tip.b ? root.fmt(Number(tip.b.v) || 0) + "  " + root.primaryLabel : ""
        color: root.hasFocus ? root.ink_(0.75) : root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: !root.hasFocus
      }
    }
  }

  Connections {
    target: root
    function onBucketsChanged() { canvas.requestPaint() }
    function onFocusBucketsChanged() { canvas.requestPaint() }
    function onHoverIndexChanged() { canvas.requestPaint() }
    function onInkChanged() { canvas.requestPaint() }
    function onAccentChanged() { canvas.requestPaint() }
    function onSurfaceChanged() { canvas.requestPaint() }
    function onWidthChanged() { canvas.requestPaint() }
    function onHeightChanged() { canvas.requestPaint() }
  }
}
