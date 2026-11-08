import QtQuick
import qs.Commons

// Compact dot graph for the bar: round dots drawn directly (not font glyphs,
// so they stay round at any size), mirrored around the vertical centre like a
// waveform. With no signal each column shows only its middle dot, a flat line
// through the centre of the bar.
Item {
  id: root

  // Levels in 0..1, any length (low frequencies first); empty means silence.
  property var levels: []
  property int columns: 10
  // Odd, so there is a middle row to rest on.
  property int rows: 5
  property real dot: 3
  property real gap: 2
  property color color: Color.foreground

  readonly property var heights: computeHeights(levels, columns, rows)

  implicitWidth: columns * dot + (columns - 1) * gap
  implicitHeight: rows * dot + (rows - 1) * gap

  // Lit rows per column: 1, 3, 5, ... so the column grows evenly both ways.
  function computeHeights(src, cols, rowCount) {
    var out = []
    var n = src ? src.length : 0
    var half = (rowCount - 1) / 2
    for (var j = 0; j < cols; j++) {
      var v = 0
      if (n > 0) {
        var a = Math.floor(j * n / cols)
        var b = Math.max(a + 1, Math.floor((j + 1) * n / cols))
        for (var i = a; i < b && i < n; i++) v = Math.max(v, Number(src[i]) || 0)
      }
      v = Math.max(0, Math.min(1, v))
      out.push(1 + 2 * Math.round(v * half))
    }
    return out
  }

  Row {
    anchors.centerIn: parent
    spacing: root.gap

    Repeater {
      model: root.columns

      Column {
        id: col
        required property int index
        readonly property int lit: root.heights[index] || 1
        spacing: root.gap

        Repeater {
          model: root.rows

          Rectangle {
            required property int index
            width: root.dot
            height: root.dot
            radius: root.dot / 2
            color: root.color
            // opacity, not visible: a hidden item would collapse the Column.
            // No fade: dots follow the audio frame by frame.
            opacity: Math.abs(index - (root.rows - 1) / 2) < col.lit / 2 ? 1 : 0
          }
        }
      }
    }
  }
}
