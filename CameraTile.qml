import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One camera in the grid.
//
// The preview is a JPEG snapshot pulled on a timer rather than a decoded RTSP
// stream: four simultaneous decodes inside the shell process would cost far
// more than a thumbnail is worth, and a still frame gives "camera is stuck" for
// free. Two images are cross-faded so the tile never blanks between frames the
// way a single re-sourced Image does.
Item {
  id: tile

  property var camera: null
  property string frigateUrl: ""
  property int snapshotHeight: 270
  property int tick: 0
  property bool cameraOnline: true
  property var event: null
  property int nowTick: 0
  property var zoneLabels: null

  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property bool hasCursor: false

  signal activated()
  signal secondaryActivated()

  readonly property string label: camera ? camera.label : ""
  readonly property string cameraName: camera ? camera.name : ""
  readonly property bool live: cameraOnline && failures < 3 && loadedOnce
  readonly property bool alerting: Model.isRecent(event, 120, nowTick)

  property int failures: 0
  property bool loadedOnce: false
  property bool frontIsA: true

  clip: true

  function requestFrame() {
    if (!camera || frigateUrl === "") return
    var next = Model.snapshotUrl(frigateUrl, camera.name, snapshotHeight, tick)
    var back = frontIsA ? imageB : imageA
    if (String(back.source) === next) return
    back.source = next
  }

  onTickChanged: requestFrame()
  onCameraChanged: { failures = 0; loadedOnce = false; requestFrame() }
  onFrigateUrlChanged: requestFrame()
  Component.onCompleted: requestFrame()

  function frameReady(which) {
    failures = 0
    loadedOnce = true
    frontIsA = (which === "a")
  }

  function frameFailed() {
    if (failures < 99) failures++
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(tile.foreground.r, tile.foreground.g, tile.foreground.b, 0.06)
  }

  Image {
    id: imageA
    anchors.fill: parent
    fillMode: Image.PreserveAspectCrop
    cache: false
    asynchronous: true
    smooth: true
    visible: opacity > 0
    opacity: tile.frontIsA && tile.loadedOnce ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120 } }
    onStatusChanged: {
      if (status === Image.Ready) tile.frameReady("a")
      else if (status === Image.Error) tile.frameFailed()
    }
  }

  Image {
    id: imageB
    anchors.fill: parent
    fillMode: Image.PreserveAspectCrop
    cache: false
    asynchronous: true
    smooth: true
    visible: opacity > 0
    opacity: !tile.frontIsA && tile.loadedOnce ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120 } }
    onStatusChanged: {
      if (status === Image.Ready) tile.frameReady("b")
      else if (status === Image.Error) tile.frameFailed()
    }
  }

  // A frozen frame is worse than an honest gap, so a camera Frigate has lost is
  // dimmed and labelled rather than left looking live.
  Rectangle {
    anchors.fill: parent
    visible: !tile.live
    color: Qt.rgba(0, 0, 0, tile.loadedOnce ? 0.55 : 0.0)

    Column {
      anchors.centerIn: parent
      spacing: Style.spacing.sm

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "󱞚"
        font.family: tile.fontFamily
        font.pixelSize: Style.font.heading
        color: Qt.darker(tile.foreground, 1.4)
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: tile.loadedOnce || tile.failures > 0 ? "no signal" : "connecting…"
        font.family: tile.fontFamily
        font.pixelSize: Style.font.caption
        color: Qt.darker(tile.foreground, 1.4)
      }
    }
  }

  // Caption strip. Kept as a gradient rather than a solid bar so it reads over
  // both a bright daytime frame and a dark night one.
  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.space(26)

    gradient: Gradient {
      GradientStop { position: 0.0; color: "transparent" }
      GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.65) }
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.lg
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.spacing.sm
      text: tile.label
      font.family: tile.fontFamily
      font.pixelSize: Style.font.caption
      color: "#ffffff"
    }
  }

  // Recent detection marker. The zone is the whole point of the alert, so it is
  // what the badge names.
  Rectangle {
    visible: tile.event !== null && tile.event !== undefined
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.margins: Style.spacing.sm
    height: Style.space(16)
    width: badgeRow.implicitWidth + Style.spacing.lg
    radius: height / 2
    color: tile.alerting
      ? Qt.rgba(tile.urgent.r, tile.urgent.g, tile.urgent.b, 0.92)
      : Qt.rgba(0, 0, 0, 0.6)

    Row {
      id: badgeRow
      anchors.centerIn: parent
      spacing: Style.spacing.xs

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰶑"
        font.family: tile.fontFamily
        font.pixelSize: Style.font.caption
        color: "#ffffff"
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Model.badgeText(tile.event, tile.nowTick, tile.zoneLabels)
        font.family: tile.fontFamily
        font.pixelSize: Style.font.caption
        color: "#ffffff"
      }
    }
  }

  Rectangle {
    anchors.fill: parent
    color: "transparent"
    border.width: tile.hasCursor ? Style.hoverBorderWidth + 1 : (mouse.containsMouse ? Style.normalBorderWidth : 0)
    border.color: tile.hasCursor ? tile.foreground : Qt.rgba(tile.foreground.r, tile.foreground.g, tile.foreground.b, 0.5)
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(event) {
      if (event.button === Qt.RightButton) tile.secondaryActivated()
      else tile.activated()
    }
  }
}
