import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar button, and the owner of everything that must outlive the dropdown:
// the Frigate poller and the floating overlay both live here, not in Panel.qml,
// so closing the panel does not stop the stream or the alerts.
//
// Left click opens the panel, right click throws the last camera that alerted
// into the overlay, middle click opens Frigate itself.
BarWidget {
  id: root
  moduleName: "io.github.duarte-gui.camguard"

  // ---- Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  //      requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  // The bar instantiates one of these per monitor. Only the instance on the
  // first screen polls Frigate and owns the overlay, so a second display does
  // not double every notification.
  readonly property var hostWindow: root.QsWindow ? root.QsWindow.window : null
  readonly property bool isLeader: !hostWindow || !hostWindow.screen
    || Quickshell.screens.length === 0
    || String(hostWindow.screen.name) === String(Quickshell.screens[0].name)

  readonly property bool pipOpen: service.player === "mpv"
    ? mpvProcess.running
    : service.pipCamera !== ""

  // Ui/BarWidget has no barForeground of its own — that lives on the bar.
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property color iconColor: {
    if (!service.everConnected) return Qt.darker(barForeground, 1.55)
    if (!service.online) return bar ? bar.urgent : Color.urgent
    return barForeground
  }

  readonly property string statusText: {
    var text = service.statusLine
    if (service.online && service.recentCount > 0)
      text += " · " + service.recentCount + (service.recentCount === 1 ? " detection" : " detections")
    return text
  }

  Service {
    id: service
    settings: root.settings
    panelOpen: root.opened
    leader: root.isLeader
  }

  // -------------------------------------------------------------------- pip

  function openPip(cameraName) {
    var target = String(cameraName || "")
    target = target === "" ? defaultPipCamera() : service.resolveCamera(target)

    if (target === "") {
      var asked = String(cameraName || "")
      if (asked === "") return "no cameras"
      var known = []
      for (var i = 0; i < service.cameras.length; i++) known.push(service.cameras[i].name)
      return "unknown camera: " + asked + " (known: " + known.join(", ") + ")"
    }

    service.pipCamera = target

    if (service.player === "mpv") startMpv(target)
    else if (pipLoader.item) pipLoader.item.show(target)

    return "ok"
  }

  function closePip() {
    if (service.player === "mpv") mpvProcess.running = false
    else if (pipLoader.item) pipLoader.item.hide()
    service.pipCamera = ""
  }

  function togglePip(cameraName) {
    var target = service.resolveCamera(String(cameraName || ""))
    if (root.pipOpen && (target === "" || target === service.pipCamera)) closePip()
    else openPip(String(cameraName || ""))
  }

  function cyclePip() {
    if (service.cameras.length === 0) return "no cameras"
    var index = service.cameraIndex(service.pipCamera)
    var next = (index + 1 + service.cameras.length) % service.cameras.length
    return openPip(service.cameras[next].name)
  }

  // Right click should land on whatever is worth looking at: the camera that
  // alerted most recently, or the first one when nothing has.
  function defaultPipCamera() {
    if (service.pipCamera !== "") return service.pipCamera

    var newest = null
    var list = service.events || []
    for (var i = 0; i < list.length; i++) {
      if (((list[i].zones || []).length) === 0) continue
      if (service.cameraIndex(list[i].camera) < 0) continue
      newest = list[i].camera
      break
    }

    if (newest) return newest
    return service.cameras.length > 0 ? service.cameras[0].name : ""
  }

  function startMpv(cameraName) {
    var stream = service.streamFor(cameraName)
    if (stream === "") return

    // Flags and the dedicated wayland app id mirror the overlay recipe Omarchy
    // already ships in omarchy-capture-screenrecording, so the window rules in
    // hypr/camguard.lua can pin it without catching every other mpv window.
    var args = [
      "mpv",
      Model.rtspUrl(service.rtspBase, stream),
      "--title=CamGuardPiP",
      "--wayland-app-id=camguard-pip",
      "--ontop",
      "--no-border",
      "--no-osc",
      "--osd-level=0",
      "--really-quiet",
      "--force-window=immediate",
      "--keepaspect",
      "--autofit=" + service.pipWidthPercent + "%"
    ]

    args.push(service.pipAudio ? "--audio=yes" : "--no-audio")

    var extra = String(service.mpvArgs || "").split(/\s+/)
    for (var i = 0; i < extra.length; i++) {
      if (extra[i] !== "") args.push(extra[i])
    }

    // Restarting through the same Process means closing the overlay later is a
    // property assignment rather than hunting the window down with pkill.
    mpvProcess.running = false
    mpvProcess.command = args
    mpvProcess.running = true
  }

  Process {
    id: mpvProcess
    running: false
    onExited: if (service.player === "mpv") service.pipCamera = ""
  }

  Loader {
    id: pipLoader
    active: service.player === "native" && root.isLeader
    source: Qt.resolvedUrl("PipOverlay.qml")
    visible: false
    onLoaded: root.injectPip()
  }

  function injectPip() {
    var target = pipLoader.item
    if (!target) return
    target.service = service
  }

  // --------------------------------------------------------------- actions

  // Persist one inline setting back to shell.json, the same way omarchy.clock
  // stores a cycled format: apply locally first so the UI reacts on the click,
  // then let the bar write the entry.
  function setSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var name in root.settings) {
      if (name !== "id") entry[name] = root.settings[name]
    }
    entry[key] = value

    root.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function openFrigate() {
    if (bar) bar.run("xdg-open " + Model.shellQuote(service.frigateUrl))
  }

  function openSetup() {
    if (panelLoader.item) panelLoader.item.openSetup()
  }

  function refresh() {
    service.refresh()
    if (panelLoader.item && panelLoader.item.bumpSnapshots) panelLoader.item.bumpSnapshots()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // A short target so a Hyprland keybinding or a notification's click action
  // reads as `omarchy-shell camguard pip Garagem`.
  IpcHandler {
    target: "camguard"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): string { root.broadcast("refresh"); return "ok" }
    function pip(camera: string): string { return root.openPip(camera) }
    function pipToggle(): string { root.togglePip(""); return "ok" }
    function pipNext(): string { return root.cyclePip() }
    function pipClose(): string { root.closePip(); return "ok" }
    function setup(): string { root.openSetup(); return "ok" }
    function status(): string { return root.statusText }

    // Useful for scripting, and the fastest way to see which camera list is in
    // play when a tile looks wrong.
    function cameras(): string {
      var out = []
      var list = service.cameras
      for (var i = 0; i < list.length; i++) {
        out.push(list[i].label + " (" + list[i].name + " → " + list[i].sub + "/" + list[i].main + ")")
      }
      return (service.configuredCameras.length > 0 ? "configured: " : "discovered: ") + out.join(", ")
        + " | spec=" + JSON.stringify(service.cameraSpec)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: service.online ? "󰞮" : "󱞚"
    foreground: root.iconColor
    // Only the overlay being up counts as "active". Tying this to recent
    // detections would leave the icon permanently lit on a busy camera; the
    // dot below carries that signal instead.
    active: root.pipOpen
    tooltipText: "CamGuard · " + root.statusText

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.togglePip("")
      else if (buttonCode === Qt.MiddleButton) root.openFrigate()
      else root.togglePanel()
    }

    // A detection inside the badge window puts a mark on the icon, so the bar
    // says "something happened" without the panel being open.
    Rectangle {
      visible: service.recentCount > 0
      width: Style.space(6)
      height: width
      radius: width / 2
      color: root.bar ? root.bar.urgent : Color.urgent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(4)
      anchors.topMargin: Style.space(4)
    }
  }
}
