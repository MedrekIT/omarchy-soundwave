import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Dot sound-wave media widget. The bar shows a btop-style braille graph of
// what is actually coming out of the speakers (via cava, when installed);
// clicking it opens a card with the track, a bigger graph, a draggable
// progress bar, transport controls, and a button that jumps to the window
// (and, where the player supports it, the tab) the audio comes from.
BarWidget {
  id: root
  moduleName: "medrekit.soundwave"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Reuse Omarchy's media service for player selection so this widget agrees
  // with the media keys and OSD; fall back to the first MPRIS player.
  readonly property var mediaService: bar && bar.shell ? bar.shell.firstPartyServiceFor("omarchy.media") : null
  readonly property var player: mediaService ? mediaService.activePlayer
    : (Mpris.players && Mpris.players.values.length > 0 ? Mpris.players.values[0] : null)

  readonly property bool hasMedia: !!player && !!(player.trackTitle || player.trackArtist)
  readonly property bool isPlaying: !!player && !!player.isPlaying
  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  readonly property string artUrl: player && player.trackArtUrl ? player.trackArtUrl : ""
  readonly property real length: player && player.lengthSupported ? Math.max(0, player.length) : 0
  // Absolute seeking (dragging the bar) needs a known length and position;
  // relative seeking (the 10 s buttons) only needs the player to allow it.
  // Firefox reports neither length nor position, so it gets the buttons only.
  readonly property bool canSeek: !!player && player.canSeek && player.positionSupported && length > 0
  readonly property bool canSeekRelative: !!player && player.canSeek

  property bool popupOpen: false
  function close() { popupOpen = false }

  readonly property color fg: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color cardFg: bar ? bar.foreground : Commons.Color.foreground

  // Shown only while something can actually be heard (or its card is open).
  // After the sound stops it lingers a few seconds, so skipping tracks or a
  // quiet intro does not make it blink in and out.
  readonly property bool wantShown: hasMedia && (popupOpen || (audible && !silent))
  readonly property bool shown: wantShown || (hasMedia && hideDelay.running)
  onWantShownChanged: if (!wantShown) hideDelay.restart()
  Timer { id: hideDelay; interval: 3000 }

  // Slides open and closed like the tray drawer: same 600 ms ease-out, the
  // widget's length growing from zero with its dots revealed under a clip.
  property real reveal: shown ? 1 : 0
  Behavior on reveal {
    NumberAnimation { duration: Style.duration(600); easing.type: Easing.OutCubic }
  }

  visible: reveal > 0
  clip: true
  implicitWidth: vertical ? barSize : Math.round((wave.implicitWidth + Style.space(16)) * reveal)
  implicitHeight: vertical ? Math.round((wave.implicitHeight + Style.space(16)) * reveal) : barSize

  onHasMediaChanged: if (!hasMedia) popupOpen = false

  function formatTime(seconds) {
    var s = Math.max(0, Math.floor(seconds || 0))
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    var sec = s % 60
    var mm = h > 0 && m < 10 ? "0" + m : String(m)
    return (h > 0 ? h + ":" : "") + mm + ":" + (sec < 10 ? "0" : "") + sec
  }

  function act(action) {
    if (!player) return
    if (mediaService) {
      mediaService.runAction(action, false, mediaService.playerKey(player))
    } else if (action === "playPause" && player.canTogglePlaying) {
      player.togglePlaying()
    } else if (action === "next" && player.canGoNext) {
      player.next()
    } else if (action === "previous" && player.canGoPrevious) {
      player.previous()
    }
  }

  // With a known position, jump to an exact time: browsers turn a relative
  // MPRIS seek into the site's own skip action, which ignores the offset
  function seekBy(offset) {
    if (!canSeekRelative) return
    if (canSeek) {
      player.positionChanged()
      player.position = Math.max(0, Math.min(length - 1, player.position + offset))
    } else {
      player.seek(offset)
    }
    Qt.callLater(function() { if (root.player) root.player.positionChanged() })
  }


  // ------------------------------------------------------------- audio levels
  //
  // Muted means nothing can be heard from this player: the output device is
  // muted or at zero, or every PipeWire stream belonging to the player is.
  // The graph then rests flat even though MPRIS still says "playing".
  readonly property var sink: Pipewire.defaultAudioSink
  readonly property bool sinkMuted: !!sink && !!sink.audio && (sink.audio.muted || sink.audio.volume <= 0.001)
  readonly property var playerStreams: {
    var out = []
    var svc = mediaService
    if (!svc || !player || !svc.playbackStreams) return out
    var key = svc.streamLabelKey(svc.playerAppLabel(player))
    if (!key) return out
    var list = svc.playbackStreams
    for (var i = 0; i < list.length; i++) {
      var sk = svc.streamLabelKey(svc.rawStreamLabel(list[i]))
      if (sk && (sk === key || sk.indexOf(key) !== -1 || key.indexOf(sk) !== -1)) out.push(list[i])
    }
    return out
  }
  readonly property bool streamsMuted: {
    if (playerStreams.length === 0) return false
    for (var i = 0; i < playerStreams.length; i++) {
      var a = playerStreams[i].audio
      if (a && !a.muted && a.volume > 0.001) return false
    }
    return true
  }
  readonly property bool muted: sinkMuted || streamsMuted
  readonly property bool audible: isPlaying && !muted

  PwObjectTracker { objects: root.sink ? [root.sink].concat(root.playerStreams) : root.playerStreams }

  // Real spectrum from cava (64 bins, 0..100) while audible and on screen.
  // Silence, including a muted browser tab, arrives as zeros.
  property bool cavaAvailable: false
  property var cavaLevels: []
  readonly property bool waveShown: visible && !(bar && bar.barHidden)
  readonly property string cavaConfig: String(Qt.resolvedUrl("cava.conf")).replace(/^file:\/\//, "")

  Process {
    id: cavaProbe
    command: ["sh", "-c", "command -v cava >/dev/null"]
    running: true
    onExited: function(code) { root.cavaAvailable = code === 0 }
  }

  Process {
    id: cavaProc
    command: ["cava", "-p", root.cavaConfig]
    // Runs whenever the player is audible, even while the widget is hidden,
    // since it is also what notices the sound coming back.
    running: root.cavaAvailable && root.audible
    onRunningChanged: {
      root.cavaLevels = []
      root.silent = false
      if (running) silenceTimer.restart()
    }
    stdout: SplitParser {
      onRead: function(line) {
        var parts = String(line).split(";")
        var out = []
        for (var i = 0; i < parts.length && out.length < 128; i++) {
          if (parts[i] === "") continue
          var v = Number(parts[i])
          out.push(isFinite(v) ? Math.max(0, Math.min(100, v)) / 100 : 0)
        }
        root.cavaLevels = out
        for (var j = 0; j < out.length; j++) {
          if (out[j] > 0.02) { root.silent = false; silenceTimer.restart(); break }
        }
      }
    }
  }

  // "Playing" with no sound (a muted browser tab, a silent gap) for a few
  // seconds counts as silent. Only cava can tell; without it this stays false.
  property bool silent: false
  Timer {
    id: silenceTimer
    interval: 2500
    onTriggered: root.silent = true
  }

  // Without cava there is no audio data to draw; fall back to a generated
  // wave so the widget still shows that something is playing.
  property var synthLevels: []
  property real synthT: 0
  Timer {
    interval: 90
    repeat: true
    running: !root.cavaAvailable && root.audible && (root.waveShown || root.popupOpen) && !Style.reduceMotion
    onTriggered: {
      root.synthT += 0.09
      var out = []
      for (var i = 0; i < 24; i++) {
        var w = 0.5 * Math.abs(Math.sin(root.synthT * (2.3 + i * 0.37) + i * 1.3))
              + 0.3 * Math.abs(Math.sin(root.synthT * (5.1 + i * 0.21) + i * 0.7))
              + 0.2 * Math.random()
        out.push(Math.min(1, w * (1 - i / 40)))
      }
      root.synthLevels = out
    }
  }

  readonly property var levels: !audible ? [] : (cavaAvailable ? cavaLevels : synthLevels)

  // ---------------------------------------------------------- go to player

  function goToPlayer() {
    if (!player) return
    clientsProc.running = false
    clientsProc.running = true
  }

  // Score each Hyprland client against the active player: same process id
  // (browsers put it in their MPRIS bus name), window title containing the
  // track title (the playing tab is usually the active one), and a class that
  // matches the player's desktop entry or name.
  function pickClient(clients) {
    var p = player
    if (!p || !Array.isArray(clients)) return null

    var bus = String(p.dbusName || "")
    var pids = []
    var m = bus.match(/instance[_]?([0-9_]+)/)
    if (m) {
      var parts = m[1].split("_")
      for (var k = 0; k < parts.length; k++) if (parts[k]) pids.push(Number(parts[k]))
    }

    var entry = String(p.desktopEntry || "").toLowerCase()
    var ident = String(p.identity || "").toLowerCase()
    var busApp = bus.replace(/^org\.mpris\.MediaPlayer2\./, "").split(".")[0].toLowerCase()
    var track = String(p.trackTitle || "").toLowerCase()

    var best = null
    var bestScore = 0
    for (var i = 0; i < clients.length && i < 500; i++) {
      var c = clients[i]
      if (!c || typeof c.address !== "string") continue
      var cls = String(c["class"] || c.initialClass || "").toLowerCase()
      var ctitle = String(c.title || "").toLowerCase()
      var score = 0
      if (pids.indexOf(Number(c.pid)) !== -1) score += 4
      if (track.length > 2 && ctitle.indexOf(track) !== -1) score += 3
      if (cls && (cls === entry || cls === busApp || cls === ident
          || (entry && cls.indexOf(entry) !== -1) || (busApp && cls.indexOf(busApp) !== -1))) score += 2
      if (score > bestScore) { best = c; bestScore = score }
    }
    return best
  }

  function focusFromClients(text) {
    var clients = null
    try { clients = JSON.parse(text) } catch (e) { clients = null }
    var target = pickClient(clients)
    var address = target ? String(target.address) : ""

    if (/^0x[0-9a-fA-F]{1,16}$/.test(address)) {
      focusProc.command = ["hyprctl", "dispatch", "hl.dsp.focus({ window = \"address:" + address + "\" })"]
      focusProc.running = false
      focusProc.running = true
    }
    // Let the player raise itself too; Chromium-based browsers switch to the
    // tab that is playing when asked.
    if (player && player.canRaise) player.raise()

    if (!/^0x/.test(address) && !(player && player.canRaise) && bar && bar.shell)
      bar.shell.summon("omarchy.osd", JSON.stringify({ icon: "media", message: strings.t("goToNotFound") }))

    popupOpen = false
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector { onStreamFinished: root.focusFromClients(text) }
  }

  Process { id: focusProc }

  // omarchy-shell medrekit.soundwave toggle   — open/close the card (bindable)
  // omarchy-shell medrekit.soundwave goTo     — jump to the playing window
  ShellIpc {
    target: "medrekit.soundwave"

    function toggle(): string {
      if (!root.shown) return "hidden"
      root.popupOpen = !root.popupOpen
      return root.popupOpen ? "open" : "closed"
    }

    function goTo(): string {
      if (!root.player) return "no-player"
      root.goToPlayer()
      return "ok"
    }
  }

  // MPRIS does not push position updates; poll it while the card is open.
  Timer {
    interval: 1000
    repeat: true
    running: root.popupOpen && !!root.player && root.player.positionSupported
    triggeredOnStart: true
    onTriggered: if (root.player) root.player.positionChanged()
  }

  // ---------------------------------------------------------------- bar

  BarDots {
    id: wave
    anchors.centerIn: parent
    // On a vertical bar the columns must also fit across the bar's width.
    readonly property int wantedColumns: Math.max(4, Math.min(24, Math.round(Number(root.setting("columns", 10)) || 10)))
    readonly property int fitColumns: Math.max(3, Math.floor((root.barSize - Style.space(8) + gap) / (dot + gap)))
    columns: root.vertical ? Math.min(wantedColumns, fitColumns) : wantedColumns
    rows: 5
    // The whole wave takes `height` percent of the bar's thickness (30–80,
    // default 50), leaving clear space above and below. Whole pixels keep
    // the dots crisp: 5 dots + 4 gaps of half a dot is 7 dots tall.
    readonly property real heightSetting: Number(root.setting("height", 50)) || 50
    readonly property real heightFraction: Math.max(0.3, Math.min(0.8, heightSetting <= 1 ? heightSetting : heightSetting / 100))
    readonly property real maxHeight: root.barSize * heightFraction
    dot: Math.max(2, Math.floor(maxHeight / 7))
    gap: Math.max(1, Math.round(dot * 0.5))
    levels: root.levels
    opacity: root.reveal
    color: root.audible && !root.silent ? root.fg : Qt.darker(root.fg, 1.6)
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) root.act("playPause")
      else root.popupOpen = !root.popupOpen
    }
    onEntered: if (root.bar && !root.popupOpen) root.bar.showTooltip(root, root.title + (root.artist ? " — " + root.artist : ""))
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // ---------------------------------------------------------------- card

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(12)

      // Track info + go-to button
      Row {
        width: parent.width
        spacing: Style.space(10)

        BorderSurface {
          id: art
          width: Style.space(56)
          height: Style.space(56)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.cardFg, Commons.Color.accent)
          borderSpec: Border.controlSpec("normal", root.cardFg, Commons.Color.accent)

          SizedImage {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            crop: true
            url: root.popupOpen ? root.artUrl : ""
            visible: url != ""
          }

          Text {
            anchors.centerIn: parent
            visible: root.artUrl === ""
            textFormat: Text.PlainText
            text: "󰝚"
            color: root.cardFg
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          width: parent.width - art.width - goTo.width - Style.space(20)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(3)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.title || strings.t("nothingPlaying")
            color: root.cardFg
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.artist
            visible: text !== ""
            color: Qt.darker(root.cardFg, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.player ? (root.player.identity || root.player.desktopEntry || "") : ""
            visible: text !== ""
            color: Qt.darker(root.cardFg, 1.6)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Button {
          id: goTo
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰁔"
          tooltipText: strings.t("goTo")
          foreground: root.cardFg
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.goToPlayer()
        }
      }

      // Big dot graph
      DotWave {
        id: bigWave
        anchors.horizontalCenter: parent.horizontalCenter
        chars: Math.max(8, Math.floor(column.width / Math.max(1, charWidth)))
        lines: 3
        levels: root.popupOpen ? root.levels : []
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        fontSize: Style.font.subtitle
        color: root.audible ? root.cardFg : Qt.darker(root.cardFg, 1.8)
        topColor: root.audible ? Commons.Color.accent : Qt.darker(root.cardFg, 1.8)
      }

      // Progress bar
      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.length > 0

        PanelSlider {
          id: progress
          width: parent.width
          bar: root.bar
          enabled: root.canSeek
          opacity: enabled ? 1 : 0.6
          minimum: 0
          maximum: Math.max(1, root.length)
          step: 5
          value: root.player && root.player.positionSupported ? root.player.position : 0
          onReleased: function(v) {
            if (root.canSeek) {
              root.player.position = v
              Qt.callLater(function() { if (root.player) root.player.positionChanged() })
            }
          }
        }

        Item {
          width: parent.width
          height: elapsed.implicitHeight

          Text {
            id: elapsed
            anchors.left: parent.left
            textFormat: Text.PlainText
            text: root.formatTime(progress.liveValue)
            color: Qt.darker(root.cardFg, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: root.formatTime(root.length)
            color: Qt.darker(root.cardFg, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Transport controls; never mirrored, matching their glyphs.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)
        LayoutMirroring.enabled: false
        LayoutMirroring.childrenInherit: true

        Button {
          iconText: "󰒮"
          tooltipText: strings.t("previous")
          foreground: root.cardFg
          enabled: !!root.player && root.player.canGoPrevious
          opacity: enabled ? 1 : 0.4
          onClicked: root.act("previous")
        }

        Button {
          iconText: "󰴪"
          tooltipText: strings.t("back10")
          foreground: root.cardFg
          enabled: root.canSeekRelative
          opacity: enabled ? 1 : 0.4
          onClicked: root.seekBy(-10)
        }

        Button {
          iconText: root.isPlaying ? "󰏤" : "󰐊"
          tooltipText: strings.t("playPause")
          foreground: root.cardFg
          horizontalPadding: Style.spacing.panelGap
          iconSize: Style.font.iconLarge
          enabled: !!root.player && (root.player.canTogglePlaying || root.player.canPlay || root.player.canPause)
          opacity: enabled ? 1 : 0.4
          onClicked: root.act("playPause")
        }

        Button {
          iconText: "󰵱"
          tooltipText: strings.t("forward10")
          foreground: root.cardFg
          enabled: root.canSeekRelative
          opacity: enabled ? 1 : 0.4
          onClicked: root.seekBy(10)
        }

        Button {
          iconText: "󰒭"
          tooltipText: strings.t("next")
          foreground: root.cardFg
          enabled: !!root.player && root.player.canGoNext
          opacity: enabled ? 1 : 0.4
          onClicked: root.act("next")
        }
      }
    }
  }
}
