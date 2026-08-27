import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The dropdown behind the bar icon: a live grid of every camera, and the zone
// activity that produced the alerts. State lives on the Service the bar widget
// owns, so closing this panel stops the snapshots and nothing else.
Panel {
  id: root
  moduleName: "io.github.duarte-gui.camguard"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  property int cursorIndex: 0
  property bool cursorActive: false
  property int snapshotTick: 0
  property bool setupMode: false

  readonly property var barIdentity: hostWidget || root
  readonly property int columns: 2
  readonly property var cameras: service ? service.cameras : []

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The events that would have interrupted you: the same zone allowlist and
  // label filter the notifier uses. Showing more than that would make this list
  // disagree with the badge beside it, and with the toasts that never came.
  readonly property var zoneEvents: service
    ? Model.allowedEvents(service.events, service.eventFilter, 4)
    : []

  // Every zone Frigate defines, as the picker's option list.
  readonly property var zoneOptions: {
    var out = []
    var list = service ? (service.zonesAvailable || []) : []
    for (var i = 0; i < list.length; i++) {
      out.push({
        value: Model.zoneKey(list[i]),
        label: Model.zoneLabel(list[i]),
        // The generated key is worth showing here and nowhere else: it is what
        // ends up in shell.json, so a hand-edit has something to match.
        description: list[i].zone !== list[i].label
          ? list[i].zone
          : "Alert when something enters this zone"
      })
    }
    return out
  }

  // With nothing configured every zone alerts, so the picker shows them all
  // ticked — what it displays is what actually happens.
  readonly property var selectedZones: {
    if (!service) return []
    if (service.allowAllZones) {
      var all = []
      for (var i = 0; i < zoneOptions.length; i++) all.push(zoneOptions[i].value)
      return all
    }

    var chosen = []
    var allow = service.zoneAllowlist
    for (var j = 0; j < zoneOptions.length; j++) {
      var parts = zoneOptions[j].value.split(":")
      if (Model.matchesZones(allow, parts[0], [parts[1]], false)) chosen.push(zoneOptions[j].value)
    }
    return chosen
  }

  function applyZones(values) {
    if (!hostWidget) return
    var list = []
    for (var i = 0; i < values.length; i++) list.push(String(values[i]))
    hostWidget.setSetting("notifyZones", list)
  }

  function setNotifications(enabled) {
    if (hostWidget) hostWidget.setSetting("notifyEnabled", enabled === true)
  }

  // ------------------------------------------------------------- lifecycle

  function open() {
    if (service) {
      service.fetchEvents()
      service.fetchStats()
    }
    root.controller.show()
    Qt.callLater(function() {
      root.cursorActive = false
      keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    // The mode is deliberately left alone: the popout coordinator closes this
    // panel when you Tab to a neighbour, and coming back should land where you
    // were rather than resetting to the cameras.
    if (zonePicker.popupOpen) zonePicker.close()
    root.controller.hide()
  }

  // The bar button always means "show me the cameras".
  function toggle() {
    if (root.opened) {
      root.close()
      return
    }
    root.setupMode = false
    root.open()
  }

  // Opens straight onto the zone picker, so `omarchy-shell camguard setup` and
  // the gear button land in the same place.
  function openSetup() {
    root.setupMode = true
    if (!root.opened) root.open()
  }

  onSetupModeChanged: if (!setupMode && zonePicker.popupOpen) zonePicker.close()

  function bumpSnapshots() {
    root.snapshotTick++
  }

  function refresh() {
    if (hostWidget) hostWidget.refresh()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function openFrigate() {
    if (hostWidget) hostWidget.openFrigate()
  }

  function openPip(name) {
    if (hostWidget) hostWidget.openPip(name)
  }

  function togglePip() {
    if (hostWidget) hostWidget.togglePip("")
  }

  function closePip() {
    if (hostWidget) hostWidget.closePip()
  }

  // The recording of one event, in the overlay. The clip often does not exist
  // yet when this is reached from a fresh detection, so the overlay shows what
  // it is waiting for rather than 404ing into whatever handles mp4.
  function openEventClip(event) {
    if (!event || !hostWidget) return
    hostWidget.openClip(event.id, event.camera)
  }

  // ---------------------------------------------------------------- cursor

  function moveCursor(dx, dy) {
    cursorActive = true
    cursorIndex = Model.gridMove(cursorIndex, cameras.length, columns, dx, dy)
  }

  function activateCursor() {
    if (cameras.length === 0) return
    var index = Math.max(0, Math.min(cursorIndex, cameras.length - 1))
    openPip(cameras[index].name)
  }

  onCamerasChanged: if (cursorIndex >= cameras.length) cursorIndex = Math.max(0, cameras.length - 1)

  // Snapshots are only worth fetching while somebody is looking at them.
  Timer {
    interval: service ? Math.max(250, service.snapshotIntervalMs) : 1000
    running: root.opened && root.cameras.length > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: root.snapshotTick++
  }

  // ------------------------------------------------------------------- ui

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(540))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        // The first arrow only reveals the cursor, so a keyboard-summoned panel
        // does not land with a highlight nobody asked for.
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "s" || text === "S") root.setupMode = !root.setupMode
        else if (text === "r" || text === "R") root.refresh()
        else if (text === "p" || text === "P") root.togglePip()
        else if (text === "o" || text === "O") root.openFrigate()
        else if (text === "q" || text === "Q") root.closePip()
        else if (text >= "1" && text <= "9") {
          var index = parseInt(text, 10) - 1
          if (index < root.cameras.length) {
            root.cursorIndex = index
            root.cursorActive = true
            root.activateCursor()
          }
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.spacing.xxl

          PanelHero {
            width: parent.width
            title: root.setupMode ? "Alert zones" : "CamGuard"
            meta: root.setupMode
              ? (root.service && root.service.allowAllZones
                  ? "every zone alerts"
                  : root.selectedZones.length + " of " + root.zoneOptions.length + " zones alert")
              : (root.service ? root.service.statusLine : "")
            // The pill is narrow: a sentence belongs in the body, not up here.
            detail: root.setupMode
              ? ""
              : root.service && root.service.recentCount > 0
              ? root.service.recentCount
                + (root.service.recentCount === 1 ? " detection" : " detections")
                + " in the last " + root.service.badgeWindowMin + " min"
              : "No detections recently"
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: root.setupMode ? "󰒓" : (root.service && root.service.online ? "󰞮" : "󱞚")
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                color: !root.setupMode && root.service && !root.service.online
                  ? root.urgent
                  : root.foreground
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.xs

                PanelActionButton {
                  iconText: root.setupMode ? "󰁍" : "󰒓"
                  tooltipText: root.setupMode ? "Back to the cameras (s)" : "Choose which zones alert (s)"
                  foreground: root.setupMode ? root.urgent : root.foreground
                  onClicked: root.setupMode = !root.setupMode
                }

                PanelActionButton {
                  visible: !root.setupMode
                  iconText: root.hostWidget && root.hostWidget.pipOpen ? "󰅖" : "󰐊"
                  tooltipText: root.hostWidget && root.hostWidget.pipOpen
                    ? "Close the overlay (q)"
                    : "Open the overlay (p)"
                  foreground: root.hostWidget && root.hostWidget.pipOpen ? root.urgent : root.foreground
                  onClicked: root.togglePip()
                }

                PanelActionButton {
                  visible: !root.setupMode
                  iconText: "󰑐"
                  tooltipText: "Refresh (r)"
                  foreground: root.foreground
                  onClicked: root.refresh()
                }

                PanelActionButton {
                  iconText: "󰏌"
                  tooltipText: "Open Frigate (o)"
                  foreground: root.foreground
                  onClicked: root.openFrigate()
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: !root.setupMode && root.cameras.length === 0
            text: root.service && root.service.online
              ? "No cameras found. Set them in the widget's settings."
              : "Cannot reach " + (root.service ? root.service.frigateUrl : "Frigate")
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: root.dim
          }

          Grid {
            id: grid
            width: parent.width
            columns: root.columns
            spacing: Style.spacing.lg
            visible: !root.setupMode && root.cameras.length > 0

            readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

            Repeater {
              model: root.cameras

              CameraTile {
                required property var modelData
                required property int index

                width: grid.cellWidth
                height: Math.round(grid.cellWidth * 9 / 16)

                camera: modelData
                frigateUrl: root.service ? root.service.frigateUrl : ""
                snapshotHeight: root.service ? root.service.snapshotHeight : 270
                tick: root.snapshotTick
                cameraOnline: root.service ? root.service.cameraOnline(modelData.name) : false
                event: root.service ? root.service.latestEventFor(modelData.name) : null
                nowTick: root.service ? root.service.tick : 0
                zoneLabels: root.service ? root.service.zoneLabels : null
                eventFilter: root.service ? root.service.eventFilter : null
                foreground: root.foreground
                urgent: root.urgent
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.cursorIndex === index

                onActivated: {
                  root.cursorIndex = index
                  root.cursorActive = true
                  root.openPip(modelData.name)
                }
                onSecondaryActivated: {
                  root.cursorIndex = index
                  var event = root.service ? root.service.latestEventFor(modelData.name) : null
                  if (event) root.openEventClip(event)
                }
              }
            }
          }

          // ---- settings page: which zones are worth interrupting you for
          Column {
            width: parent.width
            spacing: Style.spacing.xxl
            visible: root.setupMode

            Row {
              width: parent.width
              spacing: Style.spacing.lg

              ToggleSwitch {
                id: notifyToggle
                anchors.verticalCenter: parent.verticalCenter
                checked: root.service ? root.service.notifyEnabled : true
                foreground: root.foreground
                accent: root.urgent
                onToggled: root.setNotifications(!checked)
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xxs

                Text {
                  text: "Desktop notifications"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  color: root.foreground
                }

                Text {
                  text: root.service && root.service.notifyEnabled
                    ? "A toast with the snapshot; clicking it replays the recording."
                    : "Detections still show in the panel, but nothing interrupts you."
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.dim
                }
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm

              PanelSectionHeader {
                width: parent.width
                text: "Zones that raise an alert"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              MultiSelect {
                id: zonePicker
                width: parent.width
                label: "Zones"
                showLabel: false
                values: root.selectedZones
                options: root.zoneOptions
                emptyText: root.service && root.service.online
                  ? "Frigate has no zones configured"
                  : "Waiting for Frigate…"
                noSelectionText: "No zones — nothing will alert"
                foreground: root.foreground
                accent: root.urgent
                fontFamily: root.fontFamily
                onChanged: function(values) { root.applyZones(values) }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Zones come from Frigate itself. A detection that never enters "
                  + "one of them is never a notification, whatever it is — and the "
                  + "same filter decides the bar badge, the tile captions and the "
                  + "list of recent alerts."
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
              }
            }
          }

          PanelSeparator {
            width: parent.width
            visible: !root.setupMode && root.zoneEvents.length > 0
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: !root.setupMode && root.zoneEvents.length > 0

            PanelSectionHeader {
              width: parent.width
              text: "Recent alerts"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.zoneEvents

              Item {
                id: eventRow
                required property var modelData

                width: column.width
                height: Style.spacing.popupRowHeight

                Row {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.md

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰶑"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    color: root.urgent
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.eventHeadline(eventRow.modelData, root.service ? root.service.zoneLabels : null,
                        root.service ? root.service.eventFilter : null)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    color: root.foreground
                  }
                }

                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: (root.service ? root.service.cameraLabel(eventRow.modelData.camera) : "")
                    + " · " + Model.badgeText(eventRow.modelData,
                        root.service ? root.service.tick : 0,
                        root.service ? root.service.zoneLabels : null,
                        root.service ? root.service.eventFilter : null)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.dim
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  // These rows are history, so a click means "show me what
                  // happened". The live view of that camera is the right
                  // button, and the grid above.
                  onClicked: function(event) {
                    if (event.button === Qt.RightButton) root.openPip(eventRow.modelData.camera)
                    else root.openEventClip(eventRow.modelData)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
