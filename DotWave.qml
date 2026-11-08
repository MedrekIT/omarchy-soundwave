import QtQuick
import qs.Commons

// btop-style dot graph drawn with Unicode braille: every character is a 2x4
// grid of dots, so `chars` characters by `lines` lines give a canvas of
// (chars * 2) dot columns by (lines * 4) dot rows. Columns fill from the
// bottom; with no signal every column rests on its bottom dot, like btop's
// baseline.
Item {
  id: root

  // Spectrum or synthetic levels in 0..1, any length (low frequencies first).
  // Resampled to the dot columns. Empty means silence.
  property var levels: []
  property int chars: 5
  property int lines: 1
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property color color: Color.foreground
  // Multi-line graphs blend from `color` on the bottom line to `topColor`.
  property color topColor: color

  readonly property int dotCols: chars * 2
  readonly property int dotRows: lines * 4
  readonly property real charWidth: metrics.advanceWidth
  readonly property var heights: computeHeights(levels, dotCols, dotRows)

  implicitWidth: charWidth * chars
  implicitHeight: graph.implicitHeight

  // Dot bits per braille cell, top to bottom, left column then right column.
  readonly property var leftBits: [0x01, 0x02, 0x04, 0x40]
  readonly property var rightBits: [0x08, 0x10, 0x20, 0x80]

  function computeHeights(src, cols, rows) {
    var out = []
    var n = src ? src.length : 0
    for (var j = 0; j < cols; j++) {
      var v = 0
      if (n > 0) {
        var a = Math.floor(j * n / cols)
        var b = Math.max(a + 1, Math.floor((j + 1) * n / cols))
        for (var i = a; i < b && i < n; i++) v = Math.max(v, Number(src[i]) || 0)
      }
      out.push(Math.max(1, Math.min(rows, Math.round(Math.max(0, Math.min(1, v)) * rows))))
    }
    return out
  }

  function lineText(lineIndex) {
    var fromBottom = (lines - 1 - lineIndex) * 4
    var s = ""
    for (var c = 0; c < chars; c++) {
      var hl = heights[c * 2] || 1
      var hr = heights[c * 2 + 1] || 1
      var code = 0
      for (var i = 0; i < 4; i++) {
        var rowFromBottom = fromBottom + (3 - i)
        if (rowFromBottom < hl) code |= leftBits[i]
        if (rowFromBottom < hr) code |= rightBits[i]
      }
      s += String.fromCharCode(0x2800 + code)
    }
    return s
  }

  function lineColor(lineIndex) {
    if (lines <= 1) return color
    var t = 1 - lineIndex / (lines - 1)
    return Qt.rgba(color.r + (topColor.r - color.r) * t,
                   color.g + (topColor.g - color.g) * t,
                   color.b + (topColor.b - color.b) * t,
                   color.a + (topColor.a - color.a) * t)
  }

  TextMetrics {
    id: metrics
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    text: "⣿"
  }

  Column {
    id: graph
    spacing: 0

    Repeater {
      model: root.lines

      Text {
        required property int index
        textFormat: Text.PlainText
        text: root.lineText(index)
        color: root.lineColor(index)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        // Butt lines together so a multi-line graph reads as one canvas.
        lineHeightMode: Text.FixedHeight
        lineHeight: Math.ceil(root.fontSize * 1.05)
      }
    }
  }
}
