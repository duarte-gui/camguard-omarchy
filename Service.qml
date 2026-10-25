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

  // A bare IP is accepted here too, so a hand-edited "192.168.1.10" in
  // shell.json works the same as one typed into the panel.
  readonly property string frigateUrl: Model.normalizeFrigateUrl(setting("frigateUrl", "http://frigate.local:5000"))
  // Empty follows the Frigate address: go2rtc runs inside the Frigate
  // container, so the restream is the same host on 8554. Only a restream
  // published somewhere else needs spelling out.
  readonly property string rtspUrlSetting: Model.trimSlashes(setting("rtspUrl", ""))
  readonly property string rtspBase: rtspUrlSetting !== "" ? rtspUrlSetting : Model.rtspBaseFor(frigateUrl)
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
  // What clicking the toast does. The clip is the default because the toast is
  // about something that already happened; "live" is there for anyone who would
  // rather see the camera now than a recording of a moment ago.
  readonly property string notifyOpens: setting("notifyOpens", "clip") === "live" ? "live" : "clip"
  readonly property int clipWaitSec: setting("clipWaitSec", 180)
  // Not a setting: a fact about Frigate. An event that ended this long ago and
  // still has no clip is never getting one.
  readonly property int clipGraceSec: 45

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

  // ---- the replay of one event's clip
  //
  // A replay is a layer on top of the live overlay rather than a mode that
  // replaces it: pipCamera always points at the event's camera, so "live" is
  // just clearing replayEventId and letting the stream binding take over.
  property string replayEventId: ""
  property var replayEvent: null
  // idle | waiting | fetching | ready | no-clip | timeout | missing | error
  property string replayState: "idle"
  property string replayFile: ""
  property string replayMessage: ""
  property int replayAttempt: 0
  property int replayWaitedSec: 0
  property int replayLoadFailures: 0
  // Bumped once per request. Clicking a second toast while the first is still
  // waiting changes no URL, so this is what tells the overlay to drop the
  // transient state it built up for the previous one.
  property int replaySeq: 0

  readonly property bool replayActive: replayEventId !== ""
  readonly property bool replayPending: replayActive && replayState !== "ready"
  // The local copy, never the Frigate URL. Frigate serves clip.mp4 without
  // Accept-Ranges — a byte-range request comes back as the whole file — so
  // ffmpeg's http demuxer fails the moment it tries to seek. Downloading first
  // costs about a second on a LAN and makes the scrub bar exact.
  readonly property string replayClipUrl:
    (replayState === "ready" && replayFile !== "") ? "file://" + replayFile : ""

  readonly property var cameras: configuredCameras.length > 0 ? configuredCameras : discoveredCameras
  readonly property var zoneLabels: Model.zoneLabelMap(zonesAvailable)

  // Allowlist entries naming a zone this Frigate does not have — what is left
  // over after pointing the widget at another Frigate, or after a zone was
  // renamed. Only judged once the config is in, or every entry looks stale
  // for the first few seconds after startup.
  readonly property var staleZoneEntries: configLoaded && notifyZonesExplicit
    ? Model.staleZones(zoneAllowlist, zonesAvailable)
    : []
  // Every picked zone is gone, so nothing can alert. The panel says so rather
  // than letting the alarm go quiet without a word.
  readonly property bool alertsOrphaned: zoneAllowlist.length > 0
    && staleZoneEntries.length === zoneAllowlist.length

  // The zone allowlist and the label filter are what decide whether something
  // is worth interrupting you for, so they decide what the badge, the tile
  // captions and the panel list show too. Anything else means the bar lights up
  // for zones the user deliberately unticked.
  readonly property var eventFilter: ({
    allowlist: zoneAllowlist,
    allowAll: allowAllZones,
    labels: notifyLabels
  })
  readonly property var alertEvents: Model.allowedEvents(events, eventFilter, 0)
  readonly property var latestEvents: Model.latestByCamera(events, eventFilter)

  // Bumped on a timer so anything reading "how long ago" re-evaluates while the
  // panel sits open. Bindings that must age with the clock depend on it.
  property int tick: 0
  readonly property int recentCount: Model.countRecent(events, badgeWindowMin, tick, nowSeconds(), eventFilter)

  readonly property string statusLine: {
    // Before the first answer the error is the news: "connecting…" forever
    // tells you nothing about a mistyped IP.
    if (!online && lastError !== "") return lastError
    if (!everConnected) return "connecting…"
    if (!online) return "Frigate unreachable"
    var count = cameras.length
    return count + (count === 1 ? " camera" : " cameras")
  }

  // ---- internal bookkeeping
  property var notifiedIds: ({})
  property var lastNotifyAt: ({})
  property var pendingNotifications: []
  property bool seeded: false
  // The events poll only keeps the last two minutes, which is the right window
  // for deciding what to notify about and the wrong one for "replay whatever
  // just alerted" — by the time you reach for that, the event is long gone from
  // the list. This is the one that outlives it.
  property var lastAlert: null
  // What each toast's click stands for, by serial; the click itself carries
  // only the number (see Model.notifyExecArgv).
  property var alertTargets: ({})
  property int alertSerial: 0

  readonly property string cacheDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/camguard"

  onCameraSpecChanged: configuredCameras = Model.parseCameras(cameraSpec)
  onFrigateUrlChanged: reset()

  Component.onCompleted: {
    configuredCameras = Model.parseCameras(cameraSpec)
    Quickshell.execDetached(["mkdir", "-p", cacheDir])
    // One snapshot per notification and one mp4 per replay accumulate here for
    // as long as the session lasts. The directory is on tmpfs, so this is about
    // a busy day rather than about forever, but a few hundred megabytes of
    // clips is still worth sweeping.
    Quickshell.execDetached(["find", cacheDir, "-maxdepth", "1", "-type", "f",
      "-mmin", "+120", "-delete"])
    // No refresh() here. Every poll timer below is triggeredOnStart, so calling
    // it would fire each request twice in the same tick — and send() kills the
    // one already in flight, which lands the killed process's empty output on
    // the new handler and marks Frigate unreachable. At a 5-second interval the
    // next tick hides it; at 120 the widget sits on "connecting…" for two
    // minutes.
  }

  function nowSeconds() {
    return Date.now() / 1000
  }

  function reset() {
    endReplay()
    configLoaded = false
    seeded = false
    notifiedIds = ({})
    lastNotifyAt = ({})
    pendingNotifications = []
    events = []
    // What the old Frigate said about cameras and zones is not true of the new
    // one, and keeping it would light up the zone warning with the old names.
    discoveredCameras = []
    zonesAvailable = []
    online = false
    everConnected = false
    // The old address's error would otherwise sit under the new one until the
    // first poll answers.
    lastError = ""
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

  // Anything a person might reasonably type: the Frigate name, the label shown
  // in the panel, either in any case. Returns the canonical Frigate name, or ""
  // when nothing matches. Typing "Garage" for a camera Frigate calls "Garagem"
  // should not be a silent no-op from a keybinding.
  function resolveCamera(text) {
    var wanted = String(text || "").trim()
    if (wanted === "") return ""

    var list = cameras
    var i
    for (i = 0; i < list.length; i++) {
      if (list[i].name === wanted) return list[i].name
    }

    var lower = wanted.toLowerCase()
    for (i = 0; i < list.length; i++) {
      if (String(list[i].name).toLowerCase() === lower) return list[i].name
      if (String(list[i].label).toLowerCase() === lower) return list[i].name
    }

    return ""
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
  // Frigate needs no auth on the LAN. The URL goes to curl on stdin (-K -),
  // never through a shell and never in argv: an event URL carries the event
  // id, which is when something was seen, and argv is readable by every local
  // account. --noproxy matters: a LAN address must never be sent to a
  // configured proxy.
  component Request: Process {
    id: request

    property var handler: null
    property var pending: null
    property string config: ""

    stdout: StdioCollector { id: collector; waitForEnd: true }
    stderr: StdioCollector { id: errors; waitForEnd: true }

    // A GET already in flight is always the stale one — the caller only asks
    // again when something it depends on changed, such as the Frigate URL
    // arriving after construction. Dropping the new request instead would leave
    // the widget stuck on whatever the old URL returned, or on nothing at all
    // when the old URL is a hostname that does not resolve.
    //
    // The replacement is queued rather than started here. Killing a process and
    // starting another in the same tick delivers the killed one's exit — code
    // 15, empty body — to the handler that was just installed, which reads as
    // "Frigate unreachable" and then waits a whole poll interval before trying
    // again. At five seconds that is invisible; at a hundred and twenty the
    // widget sits on "connecting…" for two minutes at every startup.
    function send(url, timeoutSec, onDone) {
      request.pending = { url: url, timeout: timeoutSec, done: onDone }

      if (request.running) {
        // Its result is stale, and its exit is what starts the queued one.
        request.handler = null
        request.running = false
        return true
      }

      request.startPending()
      return true
    }

    function startPending() {
      var next = request.pending
      request.pending = null
      if (!next) return

      request.handler = next.done
      request.config = Model.curlConfig({ url: next.url })
      request.command = [
        "curl", "-sS", "--max-time", String(next.timeout), "--noproxy", "*",
        "-w", "\n%{http_code}", "-K", "-"
      ]
      request.stdinEnabled = true
      request.running = true
    }

    // Disabling stdin is what closes it; curl reads its config to EOF.
    onStarted: {
      request.write(request.config)
      request.config = ""
      request.stdinEnabled = false
    }

    onExited: function(exitCode) {
      var done = request.handler
      request.handler = null

      if (!done) {
        // A cancelled request. Whatever replaced it goes now.
        request.startPending()
        return
      }

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

      // A caller that asked again while this one was finishing.
      request.startPending()
    }
  }

  Request { id: configRequest }
  Request { id: eventsRequest }
  Request { id: statsRequest }
  // Its own instance: send() drops whatever that Request already has in flight,
  // so sharing one with the 5-second events poll would mean the two cancelling
  // each other for as long as a replay is waiting.
  Request { id: clipRequest }

  property bool configLoaded: false

  function fetchConfig() {
    configRequest.send(Model.configUrl(frigateUrl), 10, function(code, status, data, error) {
      if (code !== 0 || status !== 200 || !data) return

      discoveredCameras = Model.camerasFromConfig(data)
      zonesAvailable = Model.zonesFromConfig(data)
      // After the zones, so the stale-zone check never sees the flag without
      // the list it is about.
      configLoaded = true

      // Camera names are case-sensitive in Frigate's URLs, and "Garage" with a
      // capital G is exactly the kind of thing that silently 404s into a tile
      // that looks offline forever.
      var known = Model.cameraNamesFromConfig(data)
      for (var i = 0; i < configuredCameras.length; i++) {
        if (known.indexOf(configuredCameras[i].name) < 0)
          console.warn("camguard: Frigate has no camera named '" + configuredCameras[i].name
            + "' (it knows: " + known.join(", ") + ")")
      }

      // The other half of the same mistake: a stream name go2rtc does not
      // publish is an overlay that never starts.
      var streams = Model.go2rtcStreamsFromConfig(data)
      if (Object.keys(streams).length === 0) return
      for (var j = 0; j < configuredCameras.length; j++) {
        var cam = configuredCameras[j]
        var missing = [cam.sub, cam.main].filter(function(name) { return !(name in streams) })
        if (missing.length > 0)
          console.warn("camguard: go2rtc has no stream named '" + missing.join("', '") + "' for camera '"
            + cam.name + "'")
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
        lastError = Model.describeFailure(code, status, error)
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

  // ------------------------------------------------------------------ replay

  // The clip of an event does not exist while the event is happening. Frigate
  // writes it once the object is gone, plus the camera's post_capture, plus
  // however long the recording segment takes to close — so at the moment the
  // toast goes out, asking for the mp4 is a 404. Clicking the toast therefore
  // starts a wait, not a download, and the overlay says so.
  function requestReplay(eventId, cameraHint) {
    var id = String(eventId || "").trim()
    if (id === "") return "no event"
    if (frigateUrl === "") return "no Frigate URL"

    replaySeq++
    replayEventId = id
    replayEvent = null
    replayFile = ""
    replayState = "waiting"
    replayMessage = "waiting for the clip…"
    replayAttempt = 0
    replayWaitedSec = 0
    replayLoadFailures = 0
    clipDownload.running = false

    // Seed from the poll we already have. A toast clicked while it is fresh is
    // still inside the event window, which gives the waiting card a camera name
    // and a headline before the first request comes back — and an old event
    // that already has its clip starts playing without a round trip.
    var seed = eventById(id)
    if (seed) adoptReplayEvent(seed)

    var hinted = resolveCamera(String(cameraHint || ""))
    if (hinted !== "") pipCamera = hinted

    if (replayState === "waiting") pollClip()
    return "ok"
  }

  function eventById(id) {
    var list = events || []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].id === id) return list[i]
    }
    return null
  }

  // Pointing pipCamera at the event's camera is what makes the overlay's "live"
  // button possible: it has somewhere to fall back to.
  function adoptReplayEvent(data) {
    if (!data) return
    replayEvent = data

    var camera = resolveCamera(String(data.camera || ""))
    if (camera !== "" && camera !== pipCamera) pipCamera = camera

    applyVerdict()
  }

  function pollClip() {
    if (!replayActive) return

    clipRequest.send(Model.eventUrl(frigateUrl, replayEventId), 8,
      function(code, status, data, error) {
        if (!replayActive) return

        if (status === 404) {
          failReplay("missing", "Frigate no longer has this event")
          return
        }

        // A curl failure or a 5xx is a blip, not an answer. Staying in the wait
        // and letting the deadline decide beats declaring a missing clip
        // because one request timed out.
        if (code === 0 && status === 200 && data) adoptReplayEvent(data)
        else applyVerdict()
      })
  }

  function applyVerdict() {
    if (!replayActive) return

    var verdict = Model.clipVerdict(replayEvent, nowSeconds(), replayWaitedSec,
      clipWaitSec, clipGraceSec)

    if (verdict === "ready") {
      clipTimer.stop()
      fetchClip()
      return
    }

    if (verdict === "no-clip") {
      // The honest diagnosis, and the one the user can act on: Frigate kept no
      // recording for this event because the zone it entered is not in that
      // camera's record.alerts/detections required_zones.
      failReplay("no-clip", "Frigate kept no recording of this event")
      return
    }

    if (verdict === "timeout") {
      failReplay("timeout", "the clip is still not ready")
      return
    }

    replayState = "waiting"
    replayAttempt++
    clipTimer.interval = Model.clipPollDelay(replayAttempt)
    clipTimer.restart()
  }

  // has_clip can turn true a beat before the mp4 is actually servable, and
  // Frigate's own 404 is the only signal for that gap. The overlay reports the
  // load failure here rather than falling into the live stream's reconnect
  // ladder, which would hammer the clip forever.
  function clipLoadFailed(reason) {
    if (!replayActive) return

    replayLoadFailures++
    if (replayLoadFailures > 4) {
      failReplay("error", reason !== "" ? reason : "the clip would not open")
      return
    }

    replayState = "waiting"
    replayMessage = "waiting for the clip…"
    replayAttempt++
    clipTimer.interval = Model.clipPollDelay(replayAttempt)
    clipTimer.restart()
  }

  // curl -f turns a 404 into exit 22 and writes nothing, which is what makes
  // this the real readiness test: has_clip can flip true a moment before the
  // mp4 is servable, and a partial file handed to the player is worse than one
  // more second of waiting.
  function fetchClip() {
    if (!replayActive) return
    if (replayState === "fetching" || replayState === "ready") return

    replayState = "fetching"
    replayMessage = "fetching the clip…"
    clipDownload.path = cacheFile(replayEventId, ".mp4")
    clipDownload.config = Model.curlConfig({
      url: Model.eventClipUrl(frigateUrl, replayEventId),
      output: clipDownload.path
    })
    clipDownload.command = [
      "curl", "-fsS", "--max-time", "60", "--noproxy", "*", "--create-dirs", "-K", "-"
    ]
    clipDownload.stdinEnabled = true
    clipDownload.running = true
  }

  Process {
    id: clipDownload
    running: false

    property string path: ""
    property string config: ""

    onStarted: {
      write(config)
      config = ""
      stdinEnabled = false
    }

    onExited: function(exitCode) {
      if (!service.replayActive) return

      if (exitCode === 0) {
        service.replayFile = path
        service.replayMessage = ""
        service.replayState = "ready"
        return
      }

      // 22 is curl's "the server said 4xx": the clip was announced but is not
      // being served yet. Anything else is a transfer that broke.
      if (exitCode === 22) {
        service.replayState = "waiting"
        service.replayMessage = "waiting for the clip…"
        service.replayAttempt++
        clipTimer.interval = Model.clipPollDelay(service.replayAttempt)
        clipTimer.restart()
        return
      }

      service.failReplay("error", "the clip could not be downloaded")
    }
  }

  function retryReplay() {
    if (replayEventId !== "") requestReplay(replayEventId, pipCamera)
  }

  function failReplay(state, message) {
    clipTimer.stop()
    replayState = state
    replayMessage = message
  }

  function endReplay() {
    clipTimer.stop()
    clipDownload.running = false
    replayEventId = ""
    replayEvent = null
    replayFile = ""
    replayState = "idle"
    replayMessage = ""
    replayAttempt = 0
    replayWaitedSec = 0
    replayLoadFailures = 0
  }

  Timer {
    id: clipTimer
    repeat: false
    onTriggered: service.pollClip()
  }

  // Ages the wait: it is both the deadline in clipVerdict and the seconds the
  // waiting card shows. Runs only while something is actually waiting.
  Timer {
    interval: 1000
    running: service.replayState === "waiting"
    repeat: true
    onTriggered: {
      service.replayWaitedSec++
      // Time out even if every poll is hanging rather than answering.
      if (service.replayWaitedSec >= service.clipWaitSec) service.applyVerdict()
    }
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
      lastAlert = event
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
    snapshotDownload.imagePath = cacheFile(event.id, ".jpg")

    // The snapshot is fetched to a file because the notification daemon takes
    // an image path; a missing file only costs us the thumbnail.
    if (event.has_snapshot) {
      snapshotDownload.config = Model.curlConfig({
        url: Model.eventSnapshotUrl(frigateUrl, event.id),
        output: snapshotDownload.imagePath
      })
      snapshotDownload.command = [
        "curl", "-sS", "--max-time", "8", "--noproxy", "*", "--create-dirs", "-K", "-"
      ]
      snapshotDownload.stdinEnabled = true
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
    property string config: ""

    onStarted: {
      write(config)
      config = ""
      stdinEnabled = false
    }

    onExited: function(exitCode) {
      service.sendNotification(event, exitCode === 0 ? imagePath : "")
      event = null
      imagePath = ""
      Qt.callLater(service.drainNotifications)
    }
  }

  function sendNotification(event, imagePath) {
    if (!event) return

    alertSerial++
    alertTargets = Model.rememberAlert(alertTargets, alertSerial, event, 50)

    toast({
      summary: Model.eventHeadline(event, zoneLabels, eventFilter),
      body: Model.eventBody(event, cameraLabel(event.camera), nowSeconds()),
      urgency: "critical",
      image: imagePath,
      // The click command's words, run by the daemon as data and never
      // re-parsed — which is why nothing here goes through shellQuote.
      exec: Model.notifyExecArgv(alertSerial)
    })
  }

  // Every CamGuard toast goes through notify.py, which reads it as one JSON line
  // on stdin and calls Notify over D-Bus itself. omarchy-notification-send
  // would put "Person in Gate · Garage · 12s ago" into its own argv and then
  // busctl's, and any local account can read a process's arguments through
  // /proc — what the cameras saw is not theirs to read.
  property var toastQueue: []
  readonly property string notifyScript:
    decodeURIComponent(String(Qt.resolvedUrl("notify.py")).replace(/^file:\/\//, ""))

  function toast(note) {
    var next = toastQueue.slice()
    next.push({
      app: "CamGuard",
      glyph: "󰞮",
      summary: String(note.summary || "CamGuard"),
      body: String(note.body || ""),
      urgency: note.urgency || "normal",
      image: note.image || "",
      exec: note.exec || []
    })
    toastQueue = next
    if (!toastProcess.running) sendNextToast()
  }

  function sendNextToast() {
    if (toastQueue.length === 0) return
    toastProcess.note = toastQueue[0]
    toastQueue = toastQueue.slice(1)
    toastProcess.stdinEnabled = true
    toastProcess.running = true
  }

  Process {
    id: toastProcess
    running: false
    command: ["python3", "-I", service.notifyScript]

    property var note: null

    onStarted: {
      write(JSON.stringify(note) + "\n")
      stdinEnabled = false
    }

    onExited: function(exitCode) {
      // python-gobject missing, or no notification daemon answering. A toast
      // that says nothing is still worth more than none at all, and it is
      // the only kind that may travel as arguments. Its click replays the
      // newest alert rather than naming this one, for the same reason.
      if (exitCode !== 0) {
        console.warn("camguard: notify.py failed (" + exitCode + "), sending a generic toast")
        Quickshell.execDetached([
          "omarchy-notification-send", "--app-name", "CamGuard",
          "-u", note && note.urgency === "critical" ? "critical" : "normal",
          "-g", "󰞮", "CamGuard", "New activity on your cameras",
          "--exec", "omarchy-shell", "-q", "camguard", "replay"
        ])
      }
      note = null
      Qt.callLater(service.sendNextToast)
    }
  }

  // A file name for an event's snapshot or clip. The event id is its start
  // time, and the path reaches the notification and, in mpv mode, the
  // player's argv; a hash says nothing about when.
  function cacheFile(eventId, extension) {
    return cacheDir + "/" + Qt.md5("camguard:" + String(eventId)) + extension
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

  // Frigate's camera list barely changes, so this is a slow poll once it has
  // landed — but until then it retries quickly, because the zone picker and the
  // discovered camera list are empty without it.
  Timer {
    interval: service.configLoaded ? 300000 : 10000
    running: service.leader && service.frigateUrl !== ""
    repeat: true
    triggeredOnStart: true
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
