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

Then point it at your Frigate. Everything is stored inline on the widget's
entry in `~/.config/omarchy/shell.json`:

```jsonc
{
  "id": "io.github.duarte-gui.camguard",
  "frigateUrl": "http://frigate.local:5000",
  "rtspUrl": "rtsp://frigate.local:8554",
  "cameras": "street:street_sub:street_main|Street, Garage:garage_sub:garage_main|Garage"
}
```

Leave `cameras` out and CamGuard reads the list from `/api/config` instead.
That works, but it can only guess a camera's go2rtc stream names from the
ffmpeg input paths, so cameras whose sources are not go2rtc restreams end up
with a stream name that does not exist. Spelling the list out is worth it.

## Using it

| | |
|---|---|
| **Left click** the bar icon | open the camera grid |
| **Right click** | throw the last camera that alerted into the overlay |
| **Middle click** | open the Frigate web UI |
| **Click a camera** | open it in the overlay |
| **Right click a camera** | open that detection's clip |
| **Click the overlay** | next camera · **middle click** closes it · drag to move |

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
```

Copy those into `~/.config/hypr/bindings.lua`.

### Which zones raise an alert

The gear button in the panel — or `omarchy-shell camguard setup` — opens a
picker listing every zone Frigate knows about, per camera. Tick the ones worth
interrupting you for.

Zones drawn in the Frigate UI get a generated key like `zone_a6b95840`; the
picker shows the `friendly_name` you gave them and keeps the key as a subtitle,
since the key is what ends up in `shell.json`.

**A detection that never enters a zone never notifies**, whatever else it
matches. That is the whole point of the filter: a camera pointed at a public
street sees movement constantly, and only the approach to your gate is worth a
toast. Notifications carry the event snapshot, and clicking one opens that
camera in the overlay.

With nothing configured, every zone alerts. Untick them all and nothing does.

### Command line

```bash
omarchy-shell camguard toggle          # the camera grid
omarchy-shell camguard setup           # the zone picker
omarchy-shell camguard pip Garage      # overlay for one camera
omarchy-shell camguard pipToggle       # overlay on/off
omarchy-shell camguard pipNext         # next camera in the overlay
omarchy-shell camguard pipClose
omarchy-shell camguard status          # "4 cameras · 2 detections"
omarchy-shell camguard cameras         # the resolved camera list, for debugging
```

## Settings

Every key goes inline on the widget's entry in `shell.json`.

| key | default | what it does |
|---|---|---|
| `frigateUrl` | `http://frigate.local:5000` | Frigate HTTP API |
| `rtspUrl` | `rtsp://frigate.local:8554` | go2rtc restream, for the overlay |
| `cameras` | *(unset — ask Frigate)* | `frigateName:sub[:main]\|Label`, comma separated |
| `snapshotIntervalMs` | `1000` | grid refresh, only while the panel is open |
| `snapshotHeight` | `270` | height Frigate scales snapshots to |
| `eventPollSec` | `5` | how often detections are checked |
| `notifyEnabled` | `true` | desktop notifications |
| `notifyZones` | *(unset — every zone)* | array of `camera:zone`; the gear button writes it |
| `notifyLabels` | `person` | Frigate labels worth notifying about; empty means any |
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
