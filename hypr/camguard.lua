-- CamGuard picture-in-picture window rules, for the mpv player mode.
--
-- Only needed when the widget's `player` setting is "mpv". The native player
-- draws inside the shell as a layer-shell surface and needs no window rules at
-- all.
--
-- Load it from ~/.config/hypr/hyprland.lua with:
--
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.duarte-gui.camguard/hypr/camguard.lua")
--
-- The dedicated wayland app id is what keeps this out of mpv's generic centered
-- floating rules, so the camera appears directly at its corner instead of
-- sliding there. Same approach as Omarchy's own webcam overlay.

o.window({ class = "^camguard-pip$", title = "^CamGuardPiP$" }, {
  tag = "-default-opacity",
  float = true,
  pin = true,
  -- The overlay must never take focus: you open it to keep working, not to
  -- switch to it. This is the mpv-mode equivalent of the layer-shell surface's
  -- WlrKeyboardFocus.None.
  no_initial_focus = true,
  no_dim = true,
  no_blur = true,
  border_size = 0,
  keep_aspect_ratio = true,
  opacity = "1 1",
  -- 34% of the monitor width at 16:9, 24px off the bottom-right corner, to
  -- match the widget's own defaults. Expressed against monitor_w so it holds
  -- on any display.
  size = { "(monitor_w*17/50)", "(monitor_w*17/50*9/16)" },
  move = { "(monitor_w-monitor_w*17/50-24)", "(monitor_h-monitor_w*17/50*9/16-24)" },
})
