# CamGuard

Frigate NVR cameras in the Omarchy bar.

A camera icon in the right-hand section opens a live grid of every camera.
Click one and it lifts into a floating, always-on-top overlay that keeps
playing while you work — it never takes keyboard focus, follows you across
workspaces, and stays above fullscreen windows. Detections notify you only for
the zones you tick.

It is a desktop port of the idea behind
[FrigateTV4Xiaomi](https://github.com/duarte-gui/FrigateTV4Xiaomi), which
solves the same problem on Android TV sticks that refuse picture-in-picture.

## Requirements

- Omarchy 4.0 or newer (the Quickshell-based shell)
- A reachable Frigate instance — tested against **Frigate 0.17**
- `qt6-multimedia-ffmpeg`, for the overlay's RTSP playback. It ships with
  Omarchy; `pacman -Q qt6-multimedia-ffmpeg` confirms it.
- `python-gobject`, for sending notifications. It also ships with Omarchy;
  `pacman -Q python-gobject` confirms it. Without it, toasts still arrive,
  but they only say "New activity on your cameras".

Frigate's go2rtc restream (port `8554`) must be reachable for the overlay.
The grid needs only the Frigate HTTP API.

## Install

```bash
omarchy plugin add https://github.com/duarte-gui/camguard-omarchy --enable
```

Or from a clone, which is also the development loop:

```bash
git clone https://github.com/duarte-gui/camguard-omarchy
cd camguard-omarchy
./install.sh
```

Then point it at your Frigate: open the panel, press the gear (or `s`), and
type its IP into **Frigate address**. Enter saves and reconnects, and the line
under the field says whether it worked, and if not why. Until Frigate has
answered once, the bar icon opens straight onto that page. A bare IP or
hostname gets Frigate's port 5000, and the overlay follows the same host on
go2rtc's 8554.

Everything is stored inline on the widget's entry in
`~/.config/omarchy/shell.json`, which is also where the rest is set by hand:

```jsonc
{
  "id": "io.github.duarte-gui.camguard",
  "frigateUrl": "192.168.1.10",
  "cameras": "street:street_sub:street_main|Street, Garage:garage_sub:garage_main|Garage"
}
```

Leave `cameras` out and CamGuard shows every enabled camera Frigate has. The
overlay needs each camera's go2rtc stream names, and those are found from
`/api/config`: an input that is a restream names its stream outright; one that
reads a camera directly is matched to the go2rtc stream reading the same
source; failing both, a stream named `<camera>`, `<camera>_sub` or
`<camera>_main` is used. The `detect` input becomes the light stream and
`record` the full one.

**Cameras in the grid**, on the settings page, picks which of them to show.
Ticking or unticking one writes the list to `cameras`. Cameras that were
already there keep the labels and streams you gave them, and the list stays in
the same order. `omarchy-shell camguard cameras` prints what got resolved.

## Using it

| | |
|---|---|
| **Left click** the bar icon | open the camera grid |
| **Right click** | throw the last camera that alerted into the overlay |
| **Middle click** | open the Frigate web UI |
| **Click a camera** | open it live in the overlay |
| **Right click a camera** | replay that camera's last detection in the overlay |
| **Click a recent alert** | replay it · **right click** the row for that camera live |
| **Click the overlay** | next camera · **middle click** closes it · drag to move |
| **Click a replay** | play / pause · drag the bar to scrub · ↻ repeats · the arrow goes back to live |

In the panel: arrows or `hjkl` move, `1`–`9` jump straight to a camera,
`Enter` opens the overlay, `s` opens the zone settings, `r` refreshes,
`p` toggles the overlay, `q` closes it, `o` opens Frigate, `Esc` closes,
`Tab` moves to the next bar panel.

### Keyboard shortcuts

Two are suggested in `hypr/camguard-bindings.lua`. `SUPER+C`, `SUPER+SHIFT+C`
and `SUPER+CTRL+C` are already taken on a stock Omarchy, so:

```lua
o.bind("SUPER + ALT + C", "Cameras", "omarchy-shell -q camguard toggle")
o.bind("SUPER + SHIFT + ALT + C", "Camera overlay", "omarchy-shell -q camguard pipToggle")
o.bind("SUPER + CTRL + ALT + C", "Replay last alert", "omarchy-shell -q camguard replay")
```

Copy those into `~/.config/hypr/bindings.lua`.

### Which zones raise an alert

The gear button in the panel — or `omarchy-shell camguard setup` — opens the
settings page, which has a picker listing every zone Frigate knows about, per camera. Tick the ones worth
interrupting you for.

Zones drawn in the Frigate UI get a generated key like `zone_a6b95840`; the
picker shows the `friendly_name` you gave them and keeps the key as a subtitle,
since the key is what ends up in `shell.json`.

**A detection that never enters a zone never notifies**, whatever else it
matches. That is the whole point of the filter: a camera pointed at a public
street sees movement constantly, and only the approach to your gate is worth a
toast. Notifications carry the event snapshot, and clicking one replays what
happened.

The same filter decides everything the widget shows — the dot on the bar icon,
the caption on each tile, and the list of recent alerts in the panel. What the
panel displays is what would have interrupted you, and nothing else.

With nothing configured, every zone alerts. Untick them all and nothing does.

A picked zone that this Frigate does not have is flagged in red under the
picker, with a button to forget it. That is what happens after pointing the
widget at another Frigate, or after renaming a zone. When none of the picked
zones exist any more, nothing can alert, and the camera page says so too.
Forgetting them then clears the setting, so every zone alerts until you pick
again.

### Replaying a detection

Clicking a notification plays Frigate's recording of that detection in the
overlay, with a scrub bar, play/pause and a repeat toggle. The arrow in the
corner drops back to the live stream of the same camera.

**The clip does not exist yet when the toast appears.** Frigate only writes it
once the object is gone, plus that camera's `post_capture`, plus however long
the recording segment takes to close — so the overlay shows the event snapshot
and waits, usually for twenty to forty seconds. It never quietly shows you the
live stream instead: that would answer a different question than the one you
asked.

If a detection's zone is not covered by `record.alerts.required_zones` or
`record.detections.required_zones` on that camera in Frigate, no clip is ever
written for it. The overlay works that out from the event's end time rather than
waiting the full `clipWaitSec`, and says so.

The clip is downloaded before it plays. Frigate serves `clip.mp4` without
`Accept-Ranges` — a byte-range request comes back as the whole file — so
ffmpeg's HTTP demuxer fails the moment it tries to seek. A local copy costs
about a second on a LAN and makes the scrub bar exact. Copies land in
`$XDG_RUNTIME_DIR/camguard` and are swept at startup.

### Command line

```bash
omarchy-shell camguard toggle          # the camera grid
omarchy-shell camguard setup           # the zone picker
omarchy-shell camguard pip Garage      # overlay for one camera
omarchy-shell camguard pipToggle       # overlay on/off
omarchy-shell camguard pipNext         # next camera in the overlay
omarchy-shell camguard pipClose
omarchy-shell camguard clip <event-id> # replay one event — what a toast click runs
omarchy-shell camguard replay          # replay whatever alerted last
omarchy-shell camguard live            # leave the replay for the live stream
omarchy-shell camguard replayStatus    # "waiting <id> 12s · waiting for the clip…"
omarchy-shell camguard status          # "4 cameras · 2 detections"
omarchy-shell camguard notifyTest      # a sample toast, to check they arrive
omarchy-shell camguard cameras         # the resolved camera list, for debugging
```

## Settings

Every key goes inline on the widget's entry in `shell.json`.

| key | default | what it does |
|---|---|---|
| `frigateUrl` | `http://frigate.local:5000` | Frigate HTTP API — an IP, a hostname, or a full URL; the gear button writes it |
| `rtspUrl` | *(unset — Frigate's host on 8554)* | go2rtc restream, for the overlay; only needed when it lives elsewhere |
| `cameras` | *(unset — ask Frigate)* | `frigateName:sub[:main]\|Label`, comma separated |
| `snapshotIntervalMs` | `1000` | grid refresh, only while the panel is open |
| `snapshotHeight` | `270` | height Frigate scales snapshots to |
| `eventPollSec` | `5` | how often detections are checked |
| `notifyEnabled` | `true` | desktop notifications |
| `notifyZones` | *(unset — every zone)* | array of `camera:zone`; the gear button writes it |
| `notifyLabels` | `person` | Frigate labels worth notifying about; empty means any |
| `notifyOpens` | `clip` | what clicking a toast does — `clip` replays the recording, `live` jumps to the camera |
| `clipWaitSec` | `180` | how long to wait for Frigate to finish writing a clip |
| `notifyCooldownSec` | `60` | minimum gap between toasts from one camera |
| `badgeWindowMin` | `10` | how far back the bar dot looks |
| `player` | `native` | `native` or `mpv` — see below |
| `pipQuality` | `sub` | `sub` is the light detect stream, `main` the full one |
| `pipCorner` | `bottom-right` | where the overlay starts |
| `pipWidthPercent` | `34` | overlay width as a share of the screen, 16:9 |
| `pipMargin` | `24` | gap from the screen edges |
| `pipAudio` | `false` | play the camera's audio track |
| `mpvArgs` | `--profile=low-latency --rtsp-transport=tcp` | only for `player: "mpv"` |

The `defaults` block in `manifest.json` is documentation. Omarchy stores a
widget's settings inline and never merges the manifest defaults into them, so
the values that actually apply are the fallbacks in `Service.qml` — keep the
two in step when changing either.

### The mpv overlay

`"player": "mpv"` swaps the built-in surface for an external mpv window, which
buys hardware decoding at the cost of being a real window. It needs the rules
in `hypr/camguard.lua` to float, pin, and not steal focus:

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.duarte-gui.camguard/hypr/camguard.lua")
```

The native player needs none of that and is the default.

## How it works

- **The grid is snapshots, not video.** Each tile pulls
  `/api/<camera>/latest.jpg` on a timer and cross-fades two images so it never
  blanks between frames. Four simultaneous RTSP decodes inside the shell
  process would cost far more than a thumbnail is worth, and a still frame
  gives "this camera is stuck" for free. Nothing is fetched while the panel is
  closed.
- **The overlay is a layer-shell surface**, not a window: `WlrLayer.Overlay`
  with `WlrKeyboardFocus.None`, and an input region masked to the card so the
  rest of the screen stays clickable. That is what lets it sit above
  fullscreen windows without ever taking your keyboard.
- **Detections are polled over HTTP.** Frigate 0.17 has a websocket and an MQTT
  feed, but `qt6-websockets` is not installed on Omarchy and MQTT would mean
  carrying broker credentials for no extra signal. Events are deduplicated by
  id, and the first poll after a restart only records what already happened —
  enabling the widget never replays history as a burst of toasts.
- **What the cameras saw stays off the command line.** Any local account can
  read a process's arguments through `/proc`. So a toast's text goes to
  `notify.py` on stdin, and that script calls `Notify` over D-Bus itself
  instead of going through `omarchy-notification-send`. Event URLs reach curl
  the same way, through `curl -K -`, and snapshots and clips are cached under
  a hash of the event id, never under the id itself, which is a timestamp.
- **One poller per machine.** Omarchy builds one widget instance per monitor,
  so only the instance on the first screen polls and owns the overlay. Without
  that, a second display would mean two of every notification.

## Development

```bash
./install.sh --watch      # re-sync on save; the shell hot-reloads
./install.sh --uninstall
node Model.test.js        # the pure logic, no shell needed
```

One caveat worth knowing before you lose an hour to it: the shell hot-reloads
`.qml` reliably, but **changes to `Model.js` need a full restart**
(`omarchy restart shell`) — imported JS libraries survive
`Qt.clearComponentCache()`, so you get the old logic against the new QML.

Errors land in the shell's log:

```bash
journalctl --user -f | grep -i camguard
```

## License

MIT
