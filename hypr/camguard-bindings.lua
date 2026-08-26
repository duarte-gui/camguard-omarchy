-- CamGuard keyboard shortcuts.
--
-- Copy these two lines into ~/.config/hypr/bindings.lua, or load the whole file
-- from ~/.config/hypr/hyprland.lua with:
--
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.duarte-gui.camguard/hypr/camguard-bindings.lua")
--
-- SUPER+ALT+C is free on a stock Omarchy install; SUPER+C, SUPER+SHIFT+C and
-- SUPER+CTRL+C are not. Change them to taste — the commands are what matter.

-- Show the camera grid.
o.bind("SUPER + ALT + C", "Cameras", "omarchy-shell -q camguard toggle")

-- Throw the last camera that alerted into the floating overlay, or close it.
o.bind("SUPER + SHIFT + ALT + C", "Camera overlay", "omarchy-shell -q camguard pipToggle")

-- Replay the recording of whatever alerted last — the same thing clicking the
-- notification does, for when the toast is already gone.
o.bind("SUPER + CTRL + ALT + C", "Replay last alert", "omarchy-shell -q camguard replay")
