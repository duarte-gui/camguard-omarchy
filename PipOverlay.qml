import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The floating picture-in-picture window, and the reason this plugin exists:
// watch a camera without leaving what you are doing.
//
// It is a layer-shell surface rather than a Hyprland window, which is what
// makes it behave like the Android "chat head" the original project used: it
// sits above fullscreen windows, follows you across workspaces, never takes
// keyboard focus, and never appears in the window list. The surface is
// screen-sized and click-through everywhere except the card, so dragging works
// without the overlay eating input meant for the desktop.
Item {
  id: overlay

  property var service: null

  readonly property string cameraName: service ? service.pipCamera : ""
  readonly property var cameras: service ? service.cameras : []
  readonly property var camera: service ? service.cameraByName(cameraName) : null
  readonly property string streamName: service ? service.streamFor(cameraName) : ""
  readonly property string streamUrl: (service && streamName !== "")
    ? Model.rtspUrl(service.rtspBase, streamName)
    : ""
  readonly property string label: camera ? camera.label : cameraName
  readonly property string fontFamily: Style.font.family

  // A replay layers over the live overlay rather than replacing it: the camera
  // stays pointed at the event's camera the whole time, which is what makes
  // "live" a single property assignment away.
  readonly property string replayId: service ? service.replayEventId : ""
  readonly property string replayState: service ? service.replayState : "idle"
  readonly property var replayEvent: service ? service.replayEvent : null
  readonly property bool replayMode: replayId !== ""
  readonly property bool replaying: replayMode && replayState === "ready"
  readonly property bool waitingClip: replayMode
    && (replayState === "waiting" || replayState === "fetching")
  readonly property bool clipFailed: replayMode && !replaying && !waitingClip

  // The one place that decides what the player is pointed at. While a replay is
  // still waiting this is empty on purpose — there is nothing to show yet, and
  // quietly playing the live stream instead would be answering a question the
  // user did not ask.
  readonly property string mediaUrl: replayMode
    ? (service ? service.replayClipUrl : "")
    : streamUrl

  readonly property bool active: cameraName !== "" || replayMode

  property bool userPlaced: false
  property int retryAttempt: 0
  property string statusText: ""

  // Keeps the controls up whenever the pointer is not the only thing that would
  // be holding them there.
  readonly property bool chromePinned: replayMode
    && (waitingClip || clipFailed || atEnd
        || player.playbackState === MediaPlayer.PausedState)

  readonly property string replayTitle: {
    if (!replayEvent) return label + "  replay"
    var when = Qt.formatDateTime(new Date((replayEvent.start_time || 0) * 1000), "HH:mm:ss")
    var headline = Model.eventHeadline(replayEvent, service ? service.zoneLabels : null, service ? service.eventFilter : null)
    return headline + "  " + label + " · " + when
  }

  // Replay view state, reset per request rather than per URL.
  property bool repeatClip: false
  property bool scrubbing: false
  property real scrubValue: 0
  property bool atEnd: false

  function show(name) {
    if (!service) return
    if (name !== "" && name !== service.pipCamera) {
      service.pipCamera = name
      overlay.retryAttempt = 0
    }
    restart()
  }

  function hide() {
    retryTimer.stop()
    player.stop()
    overlay.statusText = ""
    if (service) {
      service.endReplay()
      service.pipCamera = ""
    }
  }

  function cycleCamera(step) {
    if (!service || cameras.length === 0) return
    // Cycling out of a recording is leaving it: a clip playing under another
    // camera's name would be the overlay lying about what you are looking at.
    service.endReplay()
    var index = service.cameraIndex(cameraName)
    var next = (index + step + cameras.length) % cameras.length
    service.pipCamera = cameras[next].name
    overlay.retryAttempt = 0
  }

  function goLive() {
    if (service) service.endReplay()
  }

  function restart() {
    retryTimer.stop()
    if (mediaUrl === "") return
    overlay.statusText = overlay.replayMode ? "" : "connecting…"
    player.stop()
    player.source = ""
    player.source = mediaUrl
    player.play()
  }

  // Covers every way the media can change: a new camera, a quality switch, the
  // clip becoming available, or the overlay being opened for the first time.
  onMediaUrlChanged: {
    if (mediaUrl === "") {
      player.stop()
      statusText = ""
    } else {
      retryAttempt = 0
      restart()
    }
  }

  // A second toast clicked while the first is still waiting changes no URL, so
  // the sequence number is what clears the view state the previous one left.
  Connections {
    target: overlay.service
    function onReplaySeqChanged() {
      retryTimer.stop()
      overlay.atEnd = false
      overlay.scrubbing = false
      overlay.retryAttempt = 0
      overlay.statusText = ""
    }
  }

  // Pausing a frame short of the end rather than letting playback run out:
  // the ffmpeg backend clears the video output at end-of-media, and a clip that
  // finishes into a black rectangle looks like a failure rather than an ending.
  function clipFinished() {
    if (overlay.repeatClip) {
      player.position = 0
      player.play()
      return
    }
    player.pause()
    overlay.atEnd = true
  }

  function seekTo(ms) {
    if (overlay.atEnd || player.playbackState === MediaPlayer.StoppedState) player.play()
    player.position = ms
    overlay.atEnd = false
  }

  function togglePlay() {
    if (overlay.atEnd) { overlay.seekTo(0); return }
    if (player.playbackState === MediaPlayer.PlayingState) player.pause()
    else player.play()
  }

  PanelWindow {
    id: panel
    // The card has to be up during a wait, when there is no media at all yet.
    visible: overlay.active && (overlay.mediaUrl !== "" || overlay.replayMode)
    color: "transparent"

    anchors { top: true; bottom: true; left: true; right: true }

    WlrLayershell.namespace: "camguard-pip"
    WlrLayershell.layer: WlrLayer.Overlay
    // Never take the keyboard: the whole point is to keep typing in whatever is
    // underneath while the camera is up.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Click-through everywhere except the card itself.
    mask: Region { item: card }

    readonly property int pipWidthPercent: overlay.service ? overlay.service.pipWidthPercent : 34
    readonly property int pipMargin: overlay.service ? overlay.service.pipMargin : 24
    readonly property string pipCorner: overlay.service ? overlay.service.pipCorner : "bottom-right"

    readonly property var geometry: Model.pipGeometry(
      panel.width, panel.height, pipWidthPercent, pipMargin)

    function place() {
      // Width and height settle while the surface is still being built, before
      // the card and its geometry exist.
      if (!card || !geometry) return

      card.x = pipCorner.indexOf("left") >= 0
        ? pipMargin
        : panel.width - geometry.width - pipMargin
      card.y = pipCorner.indexOf("top") >= 0
        ? pipMargin
        : panel.height - geometry.height - pipMargin
    }

    onWidthChanged: if (!overlay.userPlaced) place()
    onHeightChanged: if (!overlay.userPlaced) place()
    onVisibleChanged: if (visible && !overlay.userPlaced) place()
    onPipCornerChanged: { overlay.userPlaced = false; place() }
    onPipWidthPercentChanged: if (!overlay.userPlaced) place()
    onPipMarginChanged: if (!overlay.userPlaced) place()

    Rectangle {
      id: card
      width: panel.geometry.width
      height: panel.geometry.height
      color: "#000000"
      radius: Style.cornerRadius
      clip: true

      border.width: Math.max(1, Style.space(2))
      border.color: Color.popups.border

      Component.onCompleted: panel.place()

      VideoOutput {
        id: videoOut
        anchors.fill: parent
        anchors.margins: card.border.width
        fillMode: VideoOutput.PreserveAspectFit
      }

      // The event's snapshot behind the wait. It is the one image Frigate
      // certainly has by the time the toast goes out, so it costs nothing and
      // it beats staring at a black card for half a minute.
      Image {
        anchors.fill: parent
        anchors.margins: card.border.width
        visible: overlay.replayMode && !overlay.replaying
        source: (overlay.service && overlay.replayId !== "")
          ? Model.eventSnapshotUrl(overlay.service.frigateUrl, overlay.replayId)
          : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        opacity: 0.35
      }

      // Shown until the first frame arrives, whenever the stream drops, and for
      // the whole of a replay that is still waiting for its clip.
      Column {
        anchors.centerIn: parent
        width: parent.width - Style.spacing.xxl * 2
        spacing: Style.spacing.sm
        visible: overlay.replayMode
          ? (overlay.waitingClip || overlay.clipFailed)
          : overlay.statusText !== ""

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: overlay.clipFailed ? "󰀦" : "󰞮"
          font.family: overlay.fontFamily
          font.pixelSize: Style.font.display
          color: Qt.rgba(1, 1, 1, 0.5)
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          text: overlay.replayMode
            ? (overlay.service ? overlay.service.replayMessage : "")
            : overlay.statusText
          font.family: overlay.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: Qt.rgba(1, 1, 1, 0.7)
        }

        // Names what the wait is for, rather than just that there is one: the
        // clip is written after the object leaves, which is a real number of
        // seconds away and not a hang.
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: overlay.service && overlay.replayState === "waiting"
          text: overlay.service
            ? overlay.service.replayWaitedSec + "s · the clip is written once the event ends"
            : ""
          font.family: overlay.fontFamily
          font.pixelSize: Style.font.caption
          color: Qt.rgba(1, 1, 1, 0.45)
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: overlay.replayMode
          spacing: Style.spacing.sm

          Button {
            text: "Retry"
            visible: overlay.clipFailed
            bordered: true
            foreground: "#ffffff"
            fontFamily: overlay.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: if (overlay.service) overlay.service.retryReplay()
          }

          Button {
            text: "Live"
            bordered: true
            enabled: overlay.streamUrl !== ""
            foreground: "#ffffff"
            fontFamily: overlay.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: overlay.goLive()
          }

          Button {
            text: "Close"
            bordered: true
            foreground: "#ffffff"
            fontFamily: overlay.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: overlay.hide()
          }
        }
      }

      // Controls stay out of the way until the pointer is over the card, so the
      // overlay reads as a camera feed and not a media player.
      Rectangle {
        id: chrome
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: card.border.width
        height: Style.space(28)
        // A paused, finished or waiting replay keeps its controls up: hiding
        // them would leave a frozen frame with no way out but a guess.
        opacity: hoverProbe.containsMouse || overlay.chromePinned ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }

        gradient: Gradient {
          GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.75) }
          GradientStop { position: 1.0; color: "transparent" }
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.lg
          anchors.verticalCenter: parent.verticalCenter
          // The stream name is shown, not just the camera label: when a go2rtc
          // stream is misnamed and points at another channel, the overlay
          // showing a different scene than the tile is otherwise a mystery. A
          // replay has no stream name, and the pipQuality badge would be a lie
          // there — the clip is always the recording stream.
          text: overlay.replayMode
            ? overlay.replayTitle
            : (overlay.label + "  " + overlay.streamName
               + (overlay.service && overlay.service.pipQuality === "main" ? " · HD" : ""))
          font.family: overlay.fontFamily
          font.pixelSize: Style.font.caption
          color: "#ffffff"
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xs

          PanelActionButton {
            visible: !overlay.replayMode
            iconText: "󰑐"
            tooltipText: "Next camera"
            foreground: "#ffffff"
            fontSize: Style.font.bodySmall
            onClicked: overlay.cycleCamera(1)
          }

          PanelActionButton {
            visible: overlay.replayMode
            iconText: "󰐉"
            tooltipText: "Back to live"
            foreground: "#ffffff"
            enabled: overlay.streamUrl !== ""
            fontSize: Style.font.bodySmall
            onClicked: overlay.goLive()
          }

          PanelActionButton {
            visible: !overlay.replayMode
            iconText: "󰏌"
            tooltipText: "Reconnect"
            foreground: "#ffffff"
            fontSize: Style.font.bodySmall
            onClicked: { overlay.retryAttempt = 0; overlay.restart() }
          }

          PanelActionButton {
            iconText: "󰅖"
            tooltipText: "Close"
            foreground: "#ffffff"
            hoverColor: Color.urgent
            fontSize: Style.font.bodySmall
            onClicked: overlay.hide()
          }
        }
      }

      // The transport, replay only. It lives inside `card`, which the panel's
      // mask already makes clickable, so dragging the scrub works on a surface
      // that never takes keyboard focus.
      Rectangle {
        id: transport
        visible: overlay.replaying
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: card.border.width
        height: Style.space(36)
        opacity: hoverProbe.containsMouse || overlay.chromePinned ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }

        gradient: Gradient {
          GradientStop { position: 0.0; color: "transparent" }
          GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.8) }
        }

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.sm
          anchors.rightMargin: Style.spacing.sm
          spacing: Style.spacing.sm

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: overlay.atEnd
              ? "󰑐"
              : (player.playbackState === MediaPlayer.PlayingState ? "󰏤" : "󰐊")
            tooltipText: overlay.atEnd ? "Play again" : "Play / pause"
            foreground: "#ffffff"
            fontSize: Style.font.bodySmall
            onClicked: overlay.togglePlay()
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Model.scrubLabel(overlay.scrubbing ? overlay.scrubValue : player.position,
                                   player.duration)
            font.family: overlay.fontFamily
            font.pixelSize: Style.font.caption
            color: "#ffffff"
          }

          PanelSlider {
            id: scrub
            anchors.verticalCenter: parent.verticalCenter
            // Never draw a slider that would silently ignore a drag.
            visible: player.seekable && player.duration > 0
            width: Math.max(0, parent.width - Style.space(120))
            minimum: 0
            maximum: Math.max(1, player.duration)
            step: 1000
            integer: true
            value: overlay.scrubbing ? overlay.scrubValue : player.position
            // There is no `bar` out here, and the defaults would resolve to
            // colours meant for a panel background, not for video.
            trackColor: Qt.rgba(1, 1, 1, 0.22)
            fillColor: "#ffffff"
            knobColor: "#ffffff"
            onMoved: function(value) { overlay.scrubbing = true; overlay.scrubValue = value }
            onReleased: function(value) { overlay.scrubbing = false; overlay.seekTo(value) }
          }

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑖"
            tooltipText: overlay.repeatClip ? "Repeat is on" : "Repeat"
            foreground: overlay.repeatClip ? Color.urgent : "#ffffff"
            fontSize: Style.font.bodySmall
            onClicked: overlay.repeatClip = !overlay.repeatClip
          }
        }
      }

      // Hover detection only: the buttons above keep their own clicks, and the
      // handlers below own dragging and tapping.
      MouseArea {
        id: hoverProbe
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        z: -1
      }

      TapHandler {
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onSingleTapped: function(point, button) {
          if (button === Qt.MiddleButton) overlay.hide()
          else if (overlay.replaying) overlay.togglePlay()
          else if (!overlay.replayMode) overlay.cycleCamera(1)
        }
      }

      DragHandler {
        id: dragHandler
        target: card
        xAxis.minimum: 0
        xAxis.maximum: Math.max(0, panel.width - card.width)
        yAxis.minimum: 0
        yAxis.maximum: Math.max(0, panel.height - card.height)
        onActiveChanged: if (active) overlay.userPlaced = true
      }
    }
  }

  MediaPlayer {
    id: player
    videoOutput: videoOut
    audioOutput: AudioOutput {
      muted: !(overlay.service && overlay.service.pipAudio)
    }

    onErrorOccurred: function(error, errorString) {
      // has_clip can turn true a beat before the mp4 is actually servable. That
      // is a wait, not a broken stream, so it goes back to the Service instead
      // of into the reconnect ladder below — which would hammer the clip
      // forever and never explain why.
      if (overlay.replayMode) {
        if (overlay.service) overlay.service.clipLoadFailed(errorString)
        return
      }

      overlay.statusText = errorString !== "" ? errorString : "stream error"
      retryTimer.interval = Model.retryDelay(overlay.retryAttempt)
      overlay.retryAttempt++
      if (overlay.active) retryTimer.restart()
    }

    onPlaybackStateChanged: {
      if (playbackState === MediaPlayer.PlayingState) {
        overlay.retryAttempt = 0
        if (!overlay.replayMode) overlay.statusText = ""
      } else if (playbackState === MediaPlayer.StoppedState
                 && overlay.active && !overlay.replayMode && overlay.statusText === "") {
        // A live stream that stops on its own has dropped, not finished — but a
        // clip that reaches its end lands here too, which is why a replay never
        // gets past the guard above. Without it every recording would finish
        // into "reconnecting…" and loop.
        overlay.statusText = "reconnecting…"
        retryTimer.interval = Model.retryDelay(overlay.retryAttempt)
        overlay.retryAttempt++
        retryTimer.restart()
      }
    }

    // The near-end catch is what actually runs; EndOfMedia is the backstop for
    // a clip whose duration is unknown until it stops.
    onPositionChanged: {
      if (!overlay.replaying || overlay.atEnd || overlay.scrubbing) return
      if (player.duration > 0 && player.position >= player.duration - 150) overlay.clipFinished()
    }

    onMediaStatusChanged: {
      if (mediaStatus === MediaPlayer.EndOfMedia && overlay.replaying) overlay.clipFinished()
    }
  }

  Timer {
    id: retryTimer
    repeat: false
    onTriggered: if (overlay.active && !overlay.replayMode) overlay.restart()
  }
}
