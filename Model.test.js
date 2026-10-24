// Tests for Model.js, runnable with plain node — no shell, no Qt.
//
//   node Model.test.js
//
// Model.js is a QML JS library, so it opens with `.pragma library`, which node
// does not understand. Strip that one line and it is ordinary JavaScript.

const fs = require("fs")
const path = require("path")

const source = fs.readFileSync(path.join(__dirname, "Model.js"), "utf8")
  .replace(/^\s*\.pragma\s+library\s*$/m, "")

eval(source)

// --- checks ---
const eq = (label, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want)
  console.log((g === w ? "ok   " : "FAIL ") + label + (g === w ? "" : `\n       got  ${g}\n       want ${w}`))
}

const spec = "street:street|Street, gate:gate_sub:gate_main|Gate, Garage:garage_sub:garage_main|Garage, yard:yard_sub:yard_main|Yard"
eq("parseCameras count", parseCameras(spec).length, 4)
eq("parseCameras street", parseCameras(spec)[0], {name:"street",sub:"street",main:"street",label:"Street"})
eq("parseCameras garage", parseCameras(spec)[2], {name:"Garage",sub:"garage_sub",main:"garage_main",label:"Garage"})
eq("parseCamera bare", parseCamera("foo"), {name:"foo",sub:"foo",main:"foo",label:"foo"})
eq("snapshotUrl caps", snapshotUrl("http://h:5000/", "Garage", 270, 7), "http://h:5000/api/Garage/latest.jpg?h=270&cachebust=7")
eq("eventsUrl", eventsUrl("http://h:5000", 100.9, 50), "http://h:5000/api/events?limit=50&after=100")
eq("rtspUrl", rtspUrl("rtsp://h:8554/", "garage_sub"), "rtsp://h:8554/garage_sub")
eq("go2rtc path", go2rtcStreamFromPath("rtsp://127.0.0.1:8554/garage_sub"), "garage_sub")
eq("go2rtc non-restream", go2rtcStreamFromPath("rtsp://*:*@127.0.0.1:37777/cam/realmonitor?channel=2"), "")

const allow = parseZoneAllowlist("Garage:den, gateway")
eq("allowlist", allow, [{camera:"garage",zone:"den"},{camera:"",zone:"gateway"}])
eq("zone match scoped", matchesZones(allow, "Garage", ["den"]), true)
eq("zone wrong camera", matchesZones(allow, "street", ["den"]), false)
eq("zone unscoped any cam", matchesZones(allow, "yard", ["gateway"]), true)
eq("zone empty event", matchesZones(allow, "Garage", []), false)
eq("zone empty allowlist + allowAll -> any zone", matchesZones([], "street", ["lawn"], true), true)
eq("zone empty allowlist, explicit none -> no match", matchesZones([], "street", ["lawn"], false), false)
eq("zone empty allowlist, no zone", matchesZones([], "street", []), false)

eq("label match", matchesLabel(["person"], "person"), true)
eq("label miss", matchesLabel(["person"], "car"), false)
eq("label empty allows", matchesLabel([], "car"), true)

const now = 1787536900
eq("countRecent", countRecent([
  {start_time: now-30, zones:["den"]},
  {start_time: now-100, zones:[]},
  {start_time: now-4000, zones:["den"]},
], 10, 0, now), 1)
eq("latestByCamera", latestByCamera([
  {camera:"Garage", start_time: now-30, zones:["den"], id:"a"},
  {camera:"Garage", start_time: now-900, zones:["den"], id:"b"},
]).Garage.id, "a")

eq("relativeTime", [relativeTime(now-5,now), relativeTime(now-90,now), relativeTime(now-7200,now)], ["now","1m ago","2h ago"])
eq("headline", eventHeadline({label:"person", zones:["den"]}), "Person in Den")

// A zone drawn in the Frigate UI has a generated key; the toast must show the
// name the user gave it, not the key.
const generated = zonesFromConfig({cameras:{street:{zones:{zone_a6b95840:{friendly_name:"Portão"}}}}})
eq("zonesFromConfig friendly_name", generated, [{camera:"street",zone:"zone_a6b95840",label:"Portão"}])
const zmap = zoneLabelMap(generated)
eq("zoneLabelMap", zmap, {"street:zone_a6b95840":"Portão"})
eq("headline uses friendly_name",
   eventHeadline({label:"person", camera:"street", zones:["zone_a6b95840"]}, zmap), "Person in Portão")
eq("headline falls back to the key",
   eventHeadline({label:"person", camera:"street", zones:["marea"]}, zmap), "Person in Marea")
eq("zoneDisplay unknown", zoneDisplay(zmap, "yard", "gateway"), "Gateway")
eq("headline no zone", eventHeadline({label:"person", zones:[]}), "Person")
eq("pipGeometry 1920", pipGeometry(1920,1080,34,24), {width:653,height:367})
eq("pipGeometry tiny", pipGeometry(400,300,80,24), {width:320,height:180})
eq("shellQuote", shellQuote("it's"), "'it'\\''s'")
eq("retryDelay", [retryDelay(0), retryDelay(9)], [2000, 30000])

const cfg = {cameras:{Garage:{ffmpeg:{inputs:[
  {roles:["record","audio"], path:"rtsp://127.0.0.1:8554/garage_main"},
  {roles:["detect"], path:"rtsp://127.0.0.1:8554/garage_sub"}]}, zones:{den:{}}}}}
eq("camerasFromConfig", camerasFromConfig(cfg), [{name:"Garage",sub:"garage_sub",main:"garage_main",label:"Garage"}])
eq("zonesFromConfig", zonesFromConfig(cfg), [{camera:"Garage",zone:"den",label:"Den"}])

// gridMove over a 2-column grid of 4 cameras
eq("gridMove right", gridMove(0, 4, 2, 1, 0), 1)
eq("gridMove clamp right", gridMove(1, 4, 2, 1, 0), 1)
eq("gridMove down", gridMove(0, 4, 2, 0, 1), 2)
eq("gridMove clamp down", gridMove(2, 4, 2, 0, 1), 2)
eq("gridMove up", gridMove(3, 4, 2, 0, -1), 1)
eq("gridMove ragged last row", gridMove(2, 3, 2, 1, 0), 2)
eq("gridMove empty", gridMove(0, 0, 2, 1, 0), 0)
eq("cameraNamesFromConfig", cameraNamesFromConfig(cfg), ["Garage"])
eq("badgeText", badgeText({zones:["den"], start_time: Date.now()/1000 - 5}, 0), "Den · now")
eq("badgeText uses friendly_name",
   badgeText({camera:"street", zones:["zone_a6b95840"], start_time: Date.now()/1000 - 5}, 0, zmap), "Portão · now")
eq("isRecent", [isRecent({start_time: Date.now()/1000 - 5}, 120, 0), isRecent({start_time: 0}, 120, 0)], [true, false])

eq("splitList array", splitList(["a"," b ",""]), ["a","b"])
eq("splitList string", splitList("a, b ,"), ["a","b"])
eq("splitList null", splitList(null), [])
eq("allowlist from array", parseZoneAllowlist(["Garage:den","gateway"]), [{camera:"garage",zone:"den"},{camera:"",zone:"gateway"}])
eq("zoneLabel", zoneLabel({camera:"gate",zone:"gateway"}), "Gate · Gateway")
eq("zoneLabel prefers friendly_name", zoneLabel({camera:"street",zone:"zone_a6b95840",label:"Portão"}), "Street · Portão")
eq("zoneKey", zoneKey({camera:"Garage",zone:"den"}), "Garage:den")

// --- clip replay ---------------------------------------------------------

eq("eventUrl", eventUrl("http://h:5000/", "1787700603.795232-hesuzw"),
   "http://h:5000/api/events/1787700603.795232-hesuzw")
eq("eventClipUrl", eventClipUrl("http://h:5000", "1787700603.795232-hesuzw"),
   "http://h:5000/api/events/1787700603.795232-hesuzw/clip.mp4")

// The notification's click action is an argv vector, never a shell string:
// omarchy-notification-send rejects a single word containing a space, and it
// hands the words to the daemon as data. A quoted argument would arrive with
// its quotes intact.
eq("notifyExecArgv clip", notifyExecArgv("clip", "1787700603.795232-hesuzw", "Garagem"),
   ["omarchy-shell","-q","camguard","clip","1787700603.795232-hesuzw"])
eq("notifyExecArgv live", notifyExecArgv("live", "1787700603.795232-hesuzw", "Garagem"),
   ["omarchy-shell","-q","camguard","pip","Garagem"])
eq("notifyExecArgv falls back to live without an id", notifyExecArgv("clip", "", "Garagem"),
   ["omarchy-shell","-q","camguard","pip","Garagem"])
eq("notifyExecArgv has no word with a space",
   notifyExecArgv("clip", "1787700603.795232-hesuzw", "Porta da Frente").some(w => /\s/.test(w)), false)

const clipNow = 1787700700
eq("clipVerdict ready", clipVerdict({has_clip:true}, clipNow, 3, 180, 45), "ready")
eq("clipVerdict still running", clipVerdict({has_clip:false, end_time:null}, clipNow, 5, 180, 45), "waiting")
eq("clipVerdict just ended", clipVerdict({has_clip:false, end_time:clipNow-10}, clipNow, 10, 180, 45), "waiting")
// Ended long ago and still no clip: required_zones does not cover this event,
// so waiting the full three minutes would only be theatre.
eq("clipVerdict never recorded", clipVerdict({has_clip:false, end_time:clipNow-90}, clipNow, 90, 180, 45), "no-clip")
eq("clipVerdict endless event", clipVerdict({has_clip:false, end_time:null}, clipNow, 200, 180, 45), "timeout")
eq("clipVerdict no event yet", clipVerdict(null, clipNow, 2, 180, 45), "waiting")
eq("clipPollDelay", [clipPollDelay(0), clipPollDelay(3), clipPollDelay(99)], [1000, 3000, 10000])

eq("clockTime", [clockTime(0), clockTime(7000), clockTime(83000), clockTime(3723000)],
   ["0:00", "0:07", "1:23", "1:02:03"])
eq("scrubLabel", scrubLabel(7000, 21000), "0:07 / 0:21")
eq("scrubLabel unknown duration", scrubLabel(0, 0), "--:--")

// --- the allowlist applies to the panel, not just the toast ---------------

const filter = {allowlist: parseZoneAllowlist("rua:frente_garagem, porta_frente:portao"),
                allowAll: false, labels: ["person"]}

eq("eventAllowed in an allowed zone",
   eventAllowed({camera:"rua", label:"person", zones:["frente_garagem"]}, filter), true)
eq("eventAllowed in a zone nobody picked",
   eventAllowed({camera:"rua", label:"person", zones:["Asfalto"]}, filter), false)
eq("eventAllowed with no zone",
   eventAllowed({camera:"rua", label:"person", zones:[]}, filter), false)
eq("eventAllowed wrong label",
   eventAllowed({camera:"rua", label:"car", zones:["frente_garagem"]}, filter), false)
eq("eventAllowed no filter keeps the old meaning",
   eventAllowed({camera:"rua", label:"car", zones:["Asfalto"]}), true)
eq("eventAllowed allowAll",
   eventAllowed({camera:"x", label:"person", zones:["anything"]}, {allowlist:[], allowAll:true}), true)

const mixed = [
  {id:"1", camera:"rua", label:"person", zones:["Asfalto"], start_time: now-10},
  {id:"2", camera:"rua", label:"person", zones:["frente_garagem"], start_time: now-40},
  {id:"3", camera:"rua", label:"person", zones:["frente_garagem"], start_time: now-4000},
]
eq("allowedEvents", allowedEvents(mixed, filter).map(e => e.id), ["2","3"])
eq("allowedEvents limit", allowedEvents(mixed, filter, 1).map(e => e.id), ["2"])
eq("countRecent honours the allowlist", countRecent(mixed, 10, 0, now, filter), 1)
eq("countRecent without a filter counts any zone", countRecent(mixed, 10, 0, now), 2)
// The tile badge must not show a zone the user deselected, even when it is the
// newest thing that camera saw.
eq("latestByCamera skips a disallowed newer event", latestByCamera(mixed, filter).rua.id, "2")
eq("latestByCamera without a filter takes the newest", latestByCamera(mixed).rua.id, "1")

// --- the toast names the zone that raised the alert, not the first one -----
//
// Frigate lists zones in entry order. Someone who crossed the street on the
// way to the garage has "Asfalto" first, but it was frente_garagem that got
// through the allowlist, and that is what the headline must say.
const crossed = {camera:"rua", label:"person", zones:["Asfalto", "marea", "frente_garagem"], start_time: Date.now()/1000 - 5}
eq("alertZone picks the allowed zone", alertZone(crossed, filter), "frente_garagem")
eq("alertZone without a filter takes the first", alertZone(crossed), "Asfalto")
eq("alertZone no match falls back to the first", alertZone({camera:"rua", zones:["Asfalto","marea"]}, filter), "Asfalto")
eq("headline names the allowed zone", eventHeadline(crossed, null, filter), "Person in Frente garagem")
eq("headline without a filter keeps the old meaning", eventHeadline(crossed), "Person in Asfalto")
eq("badgeText names the allowed zone", badgeText(crossed, 0, null, filter), "Frente garagem · now")

// The Frigate address field: an IP is the common answer, a URL the exception.
eq("normalize bare IP", normalizeFrigateUrl("192.168.1.10"), "http://192.168.1.10:5000")
eq("normalize IP with port", normalizeFrigateUrl(" 192.168.1.10:8971 "), "http://192.168.1.10:8971")
eq("normalize hostname", normalizeFrigateUrl("frigate.local"), "http://frigate.local:5000")
eq("normalize full URL keeps its port", normalizeFrigateUrl("https://nvr.home/"), "https://nvr.home")
eq("normalize URL with path", normalizeFrigateUrl("http://h:5000/frigate"), "http://h:5000/frigate")
eq("normalize rejects rtsp", normalizeFrigateUrl("rtsp://h:8554"), "")
eq("normalize rejects spaces", normalizeFrigateUrl("192.168 .1.1"), "")
eq("normalize empty", normalizeFrigateUrl(""), "")
eq("urlHost", urlHost("http://192.168.1.10:5000/x"), "192.168.1.10")
eq("rtspBaseFor follows the API host", rtspBaseFor("https://nvr.home"), "rtsp://nvr.home:8554")
eq("rtspBaseFor nothing", rtspBaseFor(""), "")
eq("address text drops the default port", frigateAddressText("http://192.168.1.10:5000"), "192.168.1.10")
eq("address text keeps anything else", frigateAddressText("http://h:8971"), "http://h:8971")

// Discovery against the shape of a real Frigate 0.17 config: two cameras on restreams, one
// reading the DVR directly while go2rtc republishes the same URL, and one whose
// only stream is named after it.
const realConfig = {
  go2rtc: { streams: {
    rua: "rtsp://*:*@192.168.20.13:554/cam/realmonitor?channel=2&subtype=0",
    porta_frente_1: "rtsp://*:*@192.168.20.11:554/cam/realmonitor?channel=1&subtype=0",
    porta_frente_2: "rtsp://*:*@192.168.20.11:554/cam/realmonitor?channel=1&subtype=1",
    frente_praia_main: "rtsp://*:*@127.0.0.1:37777/cam/realmonitor?channel=2&subtype=0",
    frente_praia_sub: ["ffmpeg:rtsp://*:*@127.0.0.1:37777/cam/realmonitor?channel=2&subtype=1#video=copy"],
    garagem_main: "rtsp://*:*@192.168.20.12:554/cam/realmonitor?channel=1&subtype=0",
    garagem_sub: "rtsp://*:*@192.168.20.12:554/cam/realmonitor?channel=1&subtype=1",
  } },
  cameras: {
    rua: { ffmpeg: { inputs: [{ path: "rtsp://*:*@192.168.20.13:554/cam/realmonitor?channel=2&subtype=0", roles: ["record", "detect"] }] } },
    porta_frente: { ffmpeg: { inputs: [
      { path: "rtsp://127.0.0.1:8554/porta_frente_1", roles: ["record", "audio"] },
      { path: "rtsp://127.0.0.1:8554/porta_frente_2", roles: ["detect"] } ] } },
    Garagem: { friendly_name: "Garage", ffmpeg: { inputs: [] } },
    frente_praia: { ffmpeg: { inputs: [
      { path: "rtsp://*:*@127.0.0.1:37777/cam/realmonitor?channel=2&subtype=1", roles: ["detect"] },
      { path: "rtsp://*:*@127.0.0.1:37777/cam/realmonitor?channel=2&subtype=0", roles: ["record"] } ] } },
    off: { enabled: false, ffmpeg: { inputs: [] } },
  },
}
const found = camerasFromConfig(realConfig)
eq("discover skips disabled cameras", found.map(c => c.name), ["frente_praia", "Garagem", "porta_frente", "rua"])
eq("discover by matching the source", found[0], {name:"frente_praia",sub:"frente_praia_sub",main:"frente_praia_main",label:"Frente praia"})
eq("discover by name, any case, friendly label", found[1], {name:"Garagem",sub:"garagem_sub",main:"garagem_main",label:"Garage"})
eq("discover from restream paths", found[2], {name:"porta_frente",sub:"porta_frente_2",main:"porta_frente_1",label:"Porta frente"})
eq("discover one stream for both roles", found[3], {name:"rua",sub:"rua",main:"rua",label:"Rua"})

eq("cameraSpec bare", cameraSpec({name:"rua",sub:"rua",main:"rua",label:"rua"}), "rua")
eq("cameraSpec full", cameraSpec({name:"Garagem",sub:"garagem_sub",main:"garagem_main",label:"Garage"}), "Garagem:garagem_sub:garagem_main|Garage")
eq("cameraSpec one stream, renamed", cameraSpec({name:"rua",sub:"rua_s",main:"rua_s",label:"Rua, front|x"}), "rua:rua_s|Rua  front x")
eq("cameraSpec round-trips", parseCamera(cameraSpec(found[0])), found[0])

const current = parseCameras("rua:rua|Street, Garagem:garagem_sub:garagem_main|Garage")
eq("pick keeps hand-written entries and order", pickCameras(current, found, ["Garagem", "rua", "frente_praia"]),
  "rua|Street, Garagem:garagem_sub:garagem_main|Garage, frente_praia:frente_praia_sub:frente_praia_main|Frente praia")
eq("pick drops an unticked one", pickCameras(current, found, ["Garagem"]), "Garagem:garagem_sub:garagem_main|Garage")

eq("failure: timeout", describeFailure(28, 0, "curl: (28) Connection timed out"), "no answer — wrong IP, or the machine is off")
eq("failure: login", describeFailure(0, 401, ""), "Frigate wants a login; use port 5000, which has none")
eq("failure: unknown curl error keeps curl's words", describeFailure(35, 0, "curl: (35) TLS handshake"), "TLS handshake")

const known = [{camera:"rua", zone:"frente_garagem"}, {camera:"porta_frente", zone:"portao"}]
eq("staleZones none", staleZones(parseZoneAllowlist("rua:frente_garagem, portao"), known), [])
eq("staleZones wrong camera", staleZones(parseZoneAllowlist("Garagem:portao, rua:FRENTE_garagem"), known), ["garagem:portao"])
eq("staleZones all, after switching Frigate", staleZones(parseZoneAllowlist("rua:frente_garagem"), []), ["rua:frente_garagem"])
eq("failure: http on the TLS port", describeFailure(0, 400, ""), "that port expects https; try port 5000 instead")
