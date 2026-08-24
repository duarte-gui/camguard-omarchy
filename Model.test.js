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
