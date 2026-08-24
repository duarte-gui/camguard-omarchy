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
  readonly property bool active: cameraName !== ""
  readonly property var cameras: service ? service.cameras : []
  readonly property var camera: service ? service.cameraByName(cameraName) : null
  readonly property string streamName: service ? service.streamFor(cameraName) : ""
  readonly property string streamUrl: (service && streamName !== "")
    ? Model.rtspUrl(service.rtspBase, streamName)
    : ""
  readonly property string label: camera ? camera.label : cameraName
  readonly property string fontFamily: Style.font.family

  property bool userPlaced: false
  property int retryAttempt: 0
  property string statusText: ""

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
    if (service) service.pipCamera = ""
  }

  function cycleCamera(step) {
    if (!service || cameras.length === 0) return
    var index = service.cameraIndex(cameraName)
    var next = (index + step + cameras.length) % cameras.length
    service.pipCamera = cameras[next].name
    overlay.retryAttempt = 0
  }

  function restart() {
    retryTimer.stop()
    if (streamUrl === "") return
    overlay.statusText = "connecting…"
    player.stop()
    player.source = ""
    player.source = streamUrl
    player.play()
  }

  // Covers every way the stream can change: a new camera, a quality switch, or
  // the overlay being opened for the first time.
  onStreamUrlChanged: {
    if (streamUrl === "") {
      player.stop()
      statusText = ""
    } else {
      retryAttempt = 0
      restart()
    }
  }

  PanelWindow {
    id: panel
    visible: overlay.active && overlay.streamUrl !== ""
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

      // Shown until the first frame arrives, and whenever the stream drops.
      Column {
        anchors.centerIn: parent
        spacing: Style.spacing.sm
        visible: overlay.statusText !== ""

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: "󰞮"
          font.family: overlay.fontFamily
          font.pixelSize: Style.font.display
          color: Qt.rgba(1, 1, 1, 0.5)
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: overlay.statusText
          font.family: overlay.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: Qt.rgba(1, 1, 1, 0.7)
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
        opacity: hoverProbe.containsMouse ? 1 : 0
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
          // showing a different scene than the tile is otherwise a mystery.
          text: overlay.label + "  " + overlay.streamName
            + (overlay.service && overlay.service.pipQuality === "main" ? " · HD" : "")
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
            iconText: "󰑐"
            tooltipText: "Next camera"
            foreground: "#ffffff"
            fontSize: Style.font.bodySmall
            onClicked: overlay.cycleCamera(1)
          }

          PanelActionButton {
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
          else overlay.cycleCamera(1)
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
      overlay.statusText = errorString !== "" ? errorString : "stream error"
      retryTimer.interval = Model.retryDelay(overlay.retryAttempt)
      overlay.retryAttempt++
      if (overlay.active) retryTimer.restart()
    }

    onPlaybackStateChanged: {
      if (playbackState === MediaPlayer.PlayingState) {
        overlay.retryAttempt = 0
        overlay.statusText = ""
      } else if (playbackState === MediaPlayer.StoppedState
                 && overlay.active && overlay.statusText === "") {
        // A live stream that stops on its own has dropped, not finished.
        overlay.statusText = "reconnecting…"
        retryTimer.interval = Model.retryDelay(overlay.retryAttempt)
        overlay.retryAttempt++
        retryTimer.restart()
      }
    }
  }

  Timer {
    id: retryTimer
    repeat: false
    onTriggered: if (overlay.active) overlay.restart()
  }
}
