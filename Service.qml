import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything CamGuard knows: the settings as parsed values, which cameras
// exist, what has been detected lately, whether the cameras are still producing
// frames, and the notifications that come out of all that.
//
// Frigate is polled over plain HTTP with curl rather than QML networking,
// matching the other third-party bar plugins on this system. Frigate 0.17 does
// expose a websocket, but qt6-websockets is not installed, and the MQTT feed
// would mean carrying broker credentials for no extra signal.
//
// One instance lives on the bar widget, not in the panel, so polling and the
// overlay outlive the dropdown being closed.
Item {
  id: service

  // ---- injected by the bar widget
  property var settings: ({})
  property bool panelOpen: false
  // The bar builds one widget per monitor. Only the leader polls events, or a
  // second monitor would mean two of every notification.
  property bool leader: true

  // Settings are read through fallbacks rather than the manifest's `defaults`,
  // because a shell.json entry is stored inline and is never deep-merged with
  // them. The manifest block is documentation; these values are the behaviour,
  // and the two must be edited together.
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string frigateUrl: Model.trimSlashes(setting("frigateUrl", "http://frigate.local:5000"))
  readonly property string rtspBase: Model.trimSlashes(setting("rtspUrl", "rtsp://frigate.local:8554"))
  // The manifest's `defaults` block is inert — a shell.json entry is stored
  // inline and never deep-merged with it — so the real defaults are the
  // fallbacks here, and the two must be edited together.
  //
  // Empty means "ask Frigate". That works, but /api/config can only reveal a
  // camera's go2rtc stream names when its ffmpeg inputs are restream URLs, so
  // spelling the list out is worth it for anything else.
  readonly property string cameraSpec: setting("cameras", "")
  readonly property int snapshotIntervalMs: setting("snapshotIntervalMs", 1000)
  readonly property int snapshotHeight: setting("snapshotHeight", 270)
  readonly property int eventPollSec: setting("eventPollSec", 5)
  readonly property bool notifyEnabled: setting("notifyEnabled", true)
  readonly property int notifyCooldownSec: setting("notifyCooldownSec", 60)
  readonly property int badgeWindowMin: setting("badgeWindowMin", 10)
  readonly property string player: setting("player", "native") === "mpv" ? "mpv" : "native"
  readonly property string pipQuality: setting("pipQuality", "sub") === "main" ? "main" : "sub"
  readonly property string pipCorner: setting("pipCorner", "bottom-right")
  readonly property int pipWidthPercent: setting("pipWidthPercent", 34)
  readonly property int pipMargin: setting("pipMargin", 24)
  readonly property bool pipAudio: setting("pipAudio", false)
  readonly property string mpvArgs: setting("mpvArgs", "--profile=low-latency --rtsp-transport=tcp")
  // Absent means "every zone Frigate defines". An explicit empty list means the
  // user deselected them all, which means nothing notifies — the two look the
  // same in the allowlist, so the flag carries the difference.
  readonly property var notifyZonesRaw: setting("notifyZones", null)
  readonly property bool notifyZonesExplicit: {
    if (notifyZonesRaw === null || notifyZonesRaw === undefined) return false
    // A written-back empty array is explicit; an empty string is "never set".
    if (typeof notifyZonesRaw === "string") return notifyZonesRaw.trim() !== ""
    return true
  }
  readonly property var zoneAllowlist: Model.parseZoneAllowlist(notifyZonesRaw)
  readonly property bool allowAllZones: !notifyZonesExplicit
  readonly property var notifyLabels: Model.parseLabels(setting("notifyLabels", "person"))

  // ---- live state
  property var configuredCameras: []
  property var discoveredCameras: []
  property var events: []
  property var cameraFps: ({})
  property bool online: false
  property bool everConnected: false
  property string lastError: ""
  property var zonesAvailable: []
  property string pipCamera: ""

  readonly property var cameras: configuredCameras.length > 0 ? configuredCameras : discoveredCameras
  readonly property var latestEvents: Model.latestByCamera(events)

  // Bumped on a timer so anything reading "how long ago" re-evaluates while the
  // panel sits open. Bindings that must age with the clock depend on it.
  property int tick: 0
  readonly property int recentCount: Model.countRecent(events, badgeWindowMin, tick, nowSeconds())
  readonly property bool hasFreshAlert: Model.countRecent(events, 2, tick, nowSeconds()) > 0

  readonly property string statusLine: {
    if (!everConnected) return "connecting…"
    if (!online) return lastError !== "" ? lastError : "Frigate unreachable"
    var count = cameras.length
    return count + (count === 1 ? " camera" : " cameras")
  }

  // ---- internal bookkeeping
  property var notifiedIds: ({})
  property var lastNotifyAt: ({})
  property var pendingNotifications: []
  property bool seeded: false

  readonly property string cacheDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/camguard"

  onCameraSpecChanged: configuredCameras = Model.parseCameras(cameraSpec)
  onFrigateUrlChanged: reset()

  Component.onCompleted: {
    configuredCameras = Model.parseCameras(cameraSpec)
    Quickshell.execDetached(["mkdir", "-p", cacheDir])
    refresh()
  }

  function nowSeconds() {
    return Date.now() / 1000
  }

  function reset() {
    seeded = false
    notifiedIds = ({})
    lastNotifyAt = ({})
    pendingNotifications = []
    events = []
    online = false
    everConnected = false
    refresh()
  }

  function refresh() {
    if (frigateUrl === "") return
    fetchConfig()
    fetchEvents()
    fetchStats()
  }

  function cameraLabel(name) {
    var camera = cameraByName(name)
    return camera ? camera.label : name
  }

  function cameraByName(name) {
    var list = cameras
    for (var i = 0; i < list.length; i++) {
      if (list[i].name === name) return list[i]
    }
    return null
  }

  function cameraIndex(name) {
    var list = cameras
    for (var i = 0; i < list.length; i++) {
      if (list[i].name === name) return i
    }
    return -1
  }

  // A camera Frigate has stopped pulling frames from is worth showing as
  // broken, rather than leaving a frozen snapshot that looks live.
  function cameraOnline(name) {
    if (!online) return false
    if (!(name in cameraFps)) return true
    return cameraFps[name] > 0
  }

  function latestEventFor(name) {
    var map = latestEvents
    return (name in map) ? map[name] : null
  }

  function streamFor(name) {
    var camera = cameraByName(name)
    if (!camera) return ""
    return pipQuality === "main" ? camera.main : camera.sub
  }

  // ---------------------------------------------------------------- requests

  // One process per concurrent request so a slow call never starves another.
  // Frigate needs no auth on the LAN, and the URL travels as an argv entry
  // rather than through a shell, so nothing here can be quoted into a command.
  // --noproxy matters: a LAN address must never be sent to a configured proxy.
  component Request: Process {
    id: request

    property var handler: null

    stdout: StdioCollector { id: collector; waitForEnd: true }
    stderr: StdioCollector { id: errors; waitForEnd: true }

    function send(url, timeoutSec, onDone) {
      if (request.running) return false
      request.handler = onDone
      request.command = [
        "curl", "-sS", "--max-time", String(timeoutSec), "--noproxy", "*",
        "-w", "\n%{http_code}", url
      ]
      request.running = true
      return true
    }

    onExited: function(exitCode) {
      var done = request.handler
      request.handler = null
      if (!done) return

      var raw = String(collector.text || "")
      var status = 0
      var body = raw
      var cut = raw.lastIndexOf("\n")

      if (cut >= 0) {
        var tail = raw.slice(cut + 1).trim()
        if (/^\d{3}$/.test(tail)) {
          status = parseInt(tail, 10)
          body = raw.slice(0, cut)
        }
      }

      var parsed = null
      if (status >= 200 && status < 300) {
        try {
          parsed = JSON.parse(body)
        } catch (error) {
          parsed = null
        }
      }

      done(exitCode, status, parsed, String(errors.text || "").trim())
    }
  }

  Request { id: configRequest }
  Request { id: eventsRequest }
  Request { id: statsRequest }

  function fetchConfig() {
    configRequest.send(Model.configUrl(frigateUrl), 10, function(code, status, data, error) {
      if (code !== 0 || status !== 200 || !data) return

      discoveredCameras = Model.camerasFromConfig(data)
      zonesAvailable = Model.zonesFromConfig(data)

      // Camera names are case-sensitive in Frigate's URLs, and "Garage" with a
      // capital G is exactly the kind of thing that silently 404s into a tile
      // that looks offline forever.
      var known = Model.cameraNamesFromConfig(data)
      for (var i = 0; i < configuredCameras.length; i++) {
        if (known.indexOf(configuredCameras[i].name) < 0)
          console.warn("camguard: Frigate has no camera named '" + configuredCameras[i].name
            + "' (it knows: " + known.join(", ") + ")")
      }
    })
  }

  function fetchEvents() {
    // A window wider than the poll interval, so an event that only enters a
    // zone after it starts is still seen on a later pass.
    var after = nowSeconds() - Math.max(120, eventPollSec * 6)

    eventsRequest.send(Model.eventsUrl(frigateUrl, after, 50), 10, function(code, status, data, error) {
      if (code !== 0 || status !== 200 || !data) {
        online = false
        lastError = error !== "" ? error : ("Frigate unreachable (HTTP " + status + ")")
        return
      }

      online = true
      everConnected = true
      lastError = ""
      events = data

      if (!seeded) {
        // The first pass only records what already happened. Without this,
        // enabling the widget would replay every historical detection.
        for (var i = 0; i < data.length; i++) notifiedIds[data[i].id] = true
        seeded = true
        return
      }

      considerNotifications(data)
    })
  }

  function fetchStats() {
    statsRequest.send(Model.statsUrl(frigateUrl), 10, function(code, status, data, error) {
      if (code !== 0 || status !== 200 || !data) return

      var fps = ({})
      var stats = data.cameras || {}
      for (var name in stats) fps[name] = Number(stats[name].camera_fps || 0)
      cameraFps = fps
    })
  }

  // ----------------------------------------------------------- notifications

  function considerNotifications(list) {
    if (!notifyEnabled) {
      // Still mark them seen, so turning notifications back on does not fire a
      // backlog for everything that happened while they were off.
      for (var s = 0; s < list.length; s++) notifiedIds[list[s].id] = true
      return
    }

    var now = nowSeconds()
    var queued = false

    // Oldest first, so a burst notifies in the order things happened.
    for (var i = list.length - 1; i >= 0; i--) {
      var event = list[i]
      if (!event || !event.id) continue
      if (notifiedIds[event.id]) continue
      if (!Model.matchesLabel(notifyLabels, event.label)) continue

      // The zone gate. An event that never entered a zone is never a
      // notification, whatever else matches.
      if (!Model.matchesZones(zoneAllowlist, event.camera, event.zones, allowAllZones)) continue

      notifiedIds[event.id] = true

      var last = lastNotifyAt[event.camera] || 0
      if (now - last < notifyCooldownSec) continue

      lastNotifyAt[event.camera] = now
      pendingNotifications.push(event)
      queued = true
    }

    if (queued) drainNotifications()
  }

  function drainNotifications() {
    if (pendingNotifications.length === 0) return
    if (snapshotDownload.running) return

    var event = pendingNotifications.shift()
    snapshotDownload.event = event
    snapshotDownload.imagePath = cacheDir + "/" + String(event.id).replace(/[^A-Za-z0-9._-]/g, "_") + ".jpg"

    // The snapshot is fetched to a file because the notification daemon takes
    // an image path; a missing file only costs us the thumbnail.
    if (event.has_snapshot) {
      snapshotDownload.command = [
        "curl", "-sS", "--max-time", "8", "--noproxy", "*", "--create-dirs",
        "-o", snapshotDownload.imagePath,
        Model.eventSnapshotUrl(frigateUrl, event.id)
      ]
      snapshotDownload.running = true
    } else {
      sendNotification(event, "")
      Qt.callLater(drainNotifications)
    }
  }

  Process {
    id: snapshotDownload
    running: false

    property var event: null
    property string imagePath: ""

    onExited: function(exitCode) {
      service.sendNotification(event, exitCode === 0 ? imagePath : "")
      event = null
      imagePath = ""
      Qt.callLater(service.drainNotifications)
    }
  }

  // Sent detached rather than through a Process: the toast should outlive a
  // plugin hot reload, and it has nothing to report back.
  function sendNotification(event, imagePath) {
    if (!event) return

    var args = [
      "omarchy-notification-send",
      "--app-name", "CamGuard",
      "-u", "critical",
      "-g", "󰞮",
      // Clicking the toast opens that camera. The daemon runs this string in a
      // shell later, so the camera name is quoted here rather than trusted.
      "--exec", "omarchy-shell -q camguard pip " + Model.shellQuote(event.camera)
    ]

    if (imagePath !== "") args = args.concat(["--image", imagePath])

    args.push(Model.eventHeadline(event))
    args.push(Model.eventBody(event, cameraLabel(event.camera), nowSeconds()))

    Quickshell.execDetached(args)
  }

  // ------------------------------------------------------------------ timers

  Timer {
    interval: Math.max(2, service.eventPollSec) * 1000
    running: service.leader && service.frigateUrl !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: service.fetchEvents()
  }

  Timer {
    interval: 30000
    running: service.leader && service.frigateUrl !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: service.fetchStats()
  }

  // Frigate's camera list barely changes, but a zone added in the Frigate UI
  // should reach the panel without a shell restart.
  Timer {
    interval: 300000
    running: service.leader && service.frigateUrl !== ""
    repeat: true
    onTriggered: service.fetchConfig()
  }

  // Keeps relative timestamps and the badge window honest while the panel sits
  // open, without asking Frigate anything.
  Timer {
    interval: 20000
    running: true
    repeat: true
    onTriggered: service.tick++
  }
}
