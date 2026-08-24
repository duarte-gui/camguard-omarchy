.pragma library

// Pure helpers for CamGuard. Nothing here touches QML types or the shell, so
// it can be exercised from plain JS while the widget is being built.

function trimSlashes(value) {
  return String(value || "").trim().replace(/\/+$/, "")
}

// Accepts a comma-separated string or a real array, because a value typed into
// shell.json by hand and one written back by the settings panel should behave
// the same.
function splitList(value) {
  if (value === undefined || value === null) return []

  var parts = []
  if (typeof value === "string") parts = value.split(",")
  else if (value.length !== undefined && typeof value !== "function") {
    for (var i = 0; i < value.length; i++) parts.push(String(value[i]))
  } else return []

  return parts
    .map(function(part) { return String(part).trim() })
    .filter(function(part) { return part.length > 0 })
}

// "Garage:den" -> "Garage · Den", for the settings list.
function zoneLabel(entry) {
  var zone = entry.label ? entry.label : titleCase(entry.zone)
  return titleCase(entry.camera) + " · " + zone
}

function zoneKey(entry) {
  return entry.camera + ":" + entry.zone
}

// "frigateName:sub[:main]|Label" -> { name, sub, main, label }
// The label is optional and defaults to the Frigate name, and a camera with a
// single stream may omit the main stream entirely.
function parseCamera(spec) {
  var text = String(spec || "").trim()
  if (text === "") return null

  var label = ""
  var pipe = text.indexOf("|")
  if (pipe >= 0) {
    label = text.slice(pipe + 1).trim()
    text = text.slice(0, pipe).trim()
  }

  var parts = text.split(":").map(function(p) { return p.trim() })
  var name = parts[0] || ""
  if (name === "") return null

  var sub = parts[1] || name
  var main = parts[2] || sub

  return {
    name: name,
    sub: sub,
    main: main,
    label: label !== "" ? label : name
  }
}

function parseCameras(spec) {
  return splitList(spec)
    .map(parseCamera)
    .filter(function(cam) { return cam !== null })
}

// Cameras discovered from /api/config, used when the setting is left empty.
// Frigate names its restreams after the ffmpeg input paths, so the best guess
// for a preview stream is the input carrying the "detect" role.
function camerasFromConfig(config) {
  var cameras = (config && config.cameras) || {}
  var out = []

  for (var name in cameras) {
    var cam = cameras[name] || {}
    var inputs = (cam.ffmpeg && cam.ffmpeg.inputs) || []
    var detect = ""
    var record = ""

    for (var i = 0; i < inputs.length; i++) {
      var roles = inputs[i].roles || []
      var stream = go2rtcStreamFromPath(inputs[i].path)
      if (stream === "") continue
      if (roles.indexOf("detect") >= 0 && detect === "") detect = stream
      if (roles.indexOf("record") >= 0 && record === "") record = stream
    }

    out.push({
      name: name,
      sub: detect || record || name,
      main: record || detect || name,
      label: name
    })
  }

  out.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return out
}

// "rtsp://127.0.0.1:8554/garage_sub" -> "garage_sub". Anything that is not a
// go2rtc restream (a camera address, a file) has no stream name to give.
function go2rtcStreamFromPath(path) {
  var text = String(path || "")
  var match = text.match(/^rtsp:\/\/[^/]*:8554\/([^/?]+)/)
  return match ? match[1] : ""
}

function snapshotUrl(base, camera, height, tick) {
  return trimSlashes(base)
    + "/api/" + encodeURIComponent(camera)
    + "/latest.jpg?h=" + Math.round(height)
    + "&cachebust=" + tick
}

function eventsUrl(base, after, limit) {
  return trimSlashes(base)
    + "/api/events?limit=" + Math.round(limit)
    + "&after=" + Math.floor(after)
}

function eventSnapshotUrl(base, eventId) {
  return trimSlashes(base) + "/api/events/" + encodeURIComponent(eventId) + "/snapshot.jpg"
}

function eventClipUrl(base, eventId) {
  return trimSlashes(base) + "/api/events/" + encodeURIComponent(eventId) + "/clip.mp4"
}

function statsUrl(base) {
  return trimSlashes(base) + "/api/stats"
}

function configUrl(base) {
  return trimSlashes(base) + "/api/config"
}

function rtspUrl(base, stream) {
  return trimSlashes(base) + "/" + encodeURIComponent(stream)
}

// "Garage:den, portao" -> [{camera: "garagem", zone: "den"}, {camera: "", zone: "gateway"}]
// An entry without a camera prefix matches that zone on any camera.
function parseZoneAllowlist(spec) {
  return splitList(spec).map(function(entry) {
    var parts = entry.split(":")
    if (parts.length >= 2) {
      return {
        camera: parts[0].trim().toLowerCase(),
        zone: parts.slice(1).join(":").trim().toLowerCase()
      }
    }
    return { camera: "", zone: parts[0].trim().toLowerCase() }
  }).filter(function(entry) { return entry.zone !== "" })
}

// The whole point of the zone filter: an event that never entered a zone is
// never worth a notification, whatever the allowlist says.
//
// `allowAll` separates "the user has never picked zones" (notify for any zone)
// from "the user deselected every zone" (notify for none). Both look like an
// empty allowlist, and they mean opposite things.
function matchesZones(allowlist, camera, zones, allowAll) {
  var list = zones || []
  if (list.length === 0) return false
  if (!allowlist || allowlist.length === 0) return allowAll !== false

  var cam = String(camera || "").toLowerCase()

  for (var i = 0; i < list.length; i++) {
    var zone = String(list[i] || "").toLowerCase()
    for (var j = 0; j < allowlist.length; j++) {
      var allowed = allowlist[j]
      if (allowed.zone !== zone) continue
      if (allowed.camera === "" || allowed.camera === cam) return true
    }
  }

  return false
}

function matchesLabel(labels, label) {
  if (!labels || labels.length === 0) return true
  var wanted = String(label || "").toLowerCase()
  for (var i = 0; i < labels.length; i++) {
    if (String(labels[i]).toLowerCase() === wanted) return true
  }
  return false
}

function parseLabels(spec) {
  return splitList(spec)
}

// Every zone Frigate knows about, as "camera:zone" pairs — the placeholder the
// settings field falls back to, and what the panel lists as available.
//
// A zone drawn in the Frigate UI gets a generated key like "zone_a6b95840" and
// a `friendly_name` holding what the user actually called it. Showing the key
// would be showing our own plumbing, so the friendly name wins wherever a zone
// is displayed. The key stays the identifier: it is what events carry and what
// the notify allowlist stores.
function zonesFromConfig(config) {
  var cameras = (config && config.cameras) || {}
  var out = []

  for (var name in cameras) {
    var zones = (cameras[name] && cameras[name].zones) || {}
    for (var zone in zones) {
      var friendly = zones[zone] && zones[zone].friendly_name
      out.push({
        camera: name,
        zone: zone,
        label: friendly ? String(friendly) : titleCase(zone)
      })
    }
  }

  return out
}

// "camera:zone" -> friendly name, for the places that only have an event.
function zoneLabelMap(zones) {
  var map = ({})
  for (var i = 0; i < (zones || []).length; i++) {
    map[zoneKey(zones[i])] = zones[i].label
  }
  return map
}

function zoneDisplay(map, camera, zone) {
  var key = String(camera || "") + ":" + String(zone || "")
  if (map && map[key]) return map[key]
  return titleCase(zone)
}

function relativeTime(epochSeconds, nowSeconds) {
  var delta = Math.max(0, Math.floor(nowSeconds - epochSeconds))
  if (delta < 10) return "now"
  if (delta < 60) return delta + "s ago"
  if (delta < 3600) return Math.floor(delta / 60) + "m ago"
  if (delta < 86400) return Math.floor(delta / 3600) + "h ago"
  return Math.floor(delta / 86400) + "d ago"
}

function titleCase(value) {
  var text = String(value || "").replace(/[_-]+/g, " ").trim()
  if (text === "") return ""
  return text.charAt(0).toUpperCase() + text.slice(1)
}

// "Person in Gate" — the notification headline.
function eventHeadline(event, zoneLabels) {
  var label = titleCase(event && event.label)
  var zones = (event && event.zones) || []
  if (zones.length === 0) return label || "Detection"
  return (label || "Detection") + " in " + zoneDisplay(zoneLabels, event.camera, zones[0])
}

function eventBody(event, cameraLabel, nowSeconds) {
  var when = relativeTime((event && event.start_time) || nowSeconds, nowSeconds)
  return String(cameraLabel || (event && event.camera) || "") + " · " + when
}

// Events Frigate returns are ordered newest first; the badge only counts the
// ones inside the window that actually entered a zone. `tick` is unused on
// purpose: it is the binding dependency that ages this count over time.
function countRecent(events, windowMinutes, tick, nowSeconds) {
  var cutoff = nowSeconds - windowMinutes * 60
  var count = 0

  for (var i = 0; i < (events || []).length; i++) {
    var event = events[i]
    if (!event) continue
    if ((event.start_time || 0) < cutoff) continue
    if (((event.zones || []).length) === 0) continue
    count++
  }

  return count
}

// Most recent zone-entering event per camera, for the tile badges.
function latestByCamera(events) {
  var map = ({})

  for (var i = 0; i < (events || []).length; i++) {
    var event = events[i]
    if (!event || !event.camera) continue
    if (((event.zones || []).length) === 0) continue

    var current = map[event.camera]
    if (!current || (event.start_time || 0) > (current.start_time || 0)) map[event.camera] = event
  }

  return map
}

function pipGeometry(screenWidth, screenHeight, widthPercent, margin) {
  var width = Math.round(screenWidth * (widthPercent / 100))
  width = Math.max(220, Math.min(width, Math.max(220, screenWidth - margin * 2)))

  var height = Math.round(width * 9 / 16)
  var maxHeight = Math.max(124, screenHeight - margin * 2)
  if (height > maxHeight) {
    height = maxHeight
    width = Math.round(height * 16 / 9)
  }

  return { width: width, height: height }
}

function shellQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}

// Backoff for a stream that will not start: quick retries first, then back off
// so a camera that is genuinely down stops hammering the restream.
function retryDelay(attempt) {
  var ladder = [2000, 5000, 10000, 30000]
  var index = Math.max(0, Math.min(attempt, ladder.length - 1))
  return ladder[index]
}

// Tile badge caption: which zone, how long ago. `tick` is the binding
// dependency that keeps the "how long ago" part moving.
function badgeText(event, tick, zoneLabels) {
  if (!event) return ""
  var zones = event.zones || []
  var when = relativeTime(event.start_time || 0, Date.now() / 1000)
  return (zones.length > 0 ? zoneDisplay(zoneLabels, event.camera, zones[0]) + " · " : "") + when
}

// Same deal: `tick` only exists so callers re-evaluate as time passes.
function isRecent(event, withinSeconds, tick) {
  if (!event) return false
  return (Date.now() / 1000 - (event.start_time || 0)) < withinSeconds
}

// Camera names exactly as Frigate spells them — the check that catches a
// configured "garagem" when Frigate calls it "Garage".
function cameraNamesFromConfig(config) {
  var out = []
  var cameras = (config && config.cameras) || {}
  for (var name in cameras) out.push(name)
  return out
}

// Two-dimensional cursor over a flat list laid out in a grid. Clamps at the
// edges instead of wrapping, so holding an arrow key parks the cursor rather
// than cycling it forever.
function gridMove(index, count, columns, dx, dy) {
  if (count <= 0) return 0

  var rows = Math.ceil(count / columns)
  var row = Math.floor(index / columns)
  var col = index % columns

  col = Math.max(0, Math.min(col + dx, columns - 1))
  row = Math.max(0, Math.min(row + dy, rows - 1))

  var next = row * columns + col
  return next < count ? next : count - 1
}
