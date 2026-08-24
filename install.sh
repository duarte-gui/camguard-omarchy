#!/bin/bash
#
# Install CamGuard into the running Omarchy shell.
#
#   ./install.sh              sync, validate, rescan, and enable on first run
#   ./install.sh --enable     force the bar placement even if already installed
#   ./install.sh --watch      dev loop: re-sync on every save so the shell hot-reloads
#   ./install.sh --uninstall  disable, then remove the installed copy
#   ./install.sh --force      overwrite an install that omarchy plugin add made
#
# The shell only watches real files under ~/.config/omarchy/plugins, and
# omarchy-plugin-validate rejects symlinks inside a plugin folder, so this
# copies rather than links.

set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SECTION="${CAMGUARD_SECTION:-right}"

MODE="install"
FORCE="no"
FORCE_ENABLE="no"

while (($# > 0)); do
  case "$1" in
  --watch) MODE="watch" ;;
  --uninstall) MODE="uninstall" ;;
  --enable) FORCE_ENABLE="yes" ;;
  --force) FORCE="yes" ;;
  -h | --help)
    sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "install.sh: unknown option '$1'" >&2
    exit 1
    ;;
  esac
  shift
done

die() {
  echo "install.sh: $*" >&2
  exit 1
}

for tool in jq rsync omarchy-plugin-validate omarchy-shell; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required command: $tool"
done

[[ -f $SRC/manifest.json ]] || die "no manifest.json next to this script"
ID="$(jq -r '.id // empty' "$SRC/manifest.json")"
[[ -n $ID ]] || die "manifest.json has no id"

DEST="$HOME/.config/omarchy/plugins/$ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"

[[ $SRC != "$DEST" ]] || die "already running from the plugins directory; nothing to sync"

sync_plugin() {
  mkdir -p "$DEST"
  # --delete is what makes a renamed or removed QML file actually disappear
  # from the installed copy. rsync writes a temp file then renames it, which
  # raises the inotify move event the shell's plugin watcher listens for.
  rsync -a --delete \
    --exclude '.git/' \
    --exclude '.github/' \
    --exclude '.*.swp' \
    --exclude '*~' \
    --exclude '4913' \
    "$SRC/" "$DEST/"
}

case "$MODE" in
uninstall)
  omarchy plugin disable "$ID" >/dev/null 2>&1 || true
  rm -rf "$DEST"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  echo "removed $ID"
  exit 0
  ;;

watch)
  command -v inotifywait >/dev/null 2>&1 || die "missing inotifywait (pacman -S inotify-tools)"
  sync_plugin
  echo "watching $SRC — edit and save, the shell reloads itself. Ctrl-C to stop."
  inotifywait -m -r -q -e close_write,create,delete,move \
    --exclude '(\.git/|\.swp$|~$|/4913$)' \
    --format '%w%f' "$SRC" |
    while read -r _; do
      # Editors write several files per save; coalesce the burst into one sync
      # so the shell reloads once instead of five times.
      while read -r -t 0.25 _; do :; done
      sync_plugin && echo "synced $(date +%T)"
    done
  exit 0
  ;;
esac

# An install made by `omarchy plugin add` is a git checkout; rsync --delete
# would take its working tree with it.
if [[ -d $DEST/.git && $FORCE != yes ]]; then
  die "$DEST is a git checkout from 'omarchy plugin add'.
  Update it with 'omarchy plugin update $ID', or pass --force to overwrite it."
fi

sync_plugin

# Validate rejects these anyway, but its message is easy to miss in a wall of
# rsync output, and a symlink in a trusted plugin folder is worth being loud about.
link="$(find "$DEST" -name .git -prune -o -type l -print -quit 2>/dev/null || true)"
[[ -z $link ]] || die "symlink inside the plugin folder: $link"

omarchy plugin validate "$DEST"

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

# Enabling before the shell has finished discovering the plugin fails with
# "plugin is not known", so wait for it the same way omarchy-plugin-add does.
known="no"
for _ in $(seq 1 40); do
  if omarchy-plugin-list --json 2>/dev/null | jq -e --arg id "$ID" 'any(.[]; .id == $id)' >/dev/null 2>&1; then
    known="yes"
    break
  fi
  sleep 0.05
done
[[ $known == yes ]] || die "the shell did not pick up $ID — check its log with: journalctl --user -e | grep -i quickshell"

# Re-enabling an already-placed widget appends a duplicate layout entry.
placed="no"
if [[ -f $SHELL_JSON ]] && jq -e --arg id "$ID" '[.. | objects | select(.id? == $id)] | length > 0' "$SHELL_JSON" >/dev/null 2>&1; then
  placed="yes"
fi

if [[ $placed == no || $FORCE_ENABLE == yes ]]; then
  omarchy plugin enable "$ID" --section "$SECTION"
  echo "enabled $ID in the $SECTION section"
else
  echo "$ID is already on the bar; left its position alone"
fi

cat <<EOF

CamGuard installed.

  Settings live inline in $SHELL_JSON, on the "$ID" entry.
  Move it with:  omarchy bar move $ID --section right
  Drive it with: omarchy-shell camguard toggle | pip <camera> | pipNext | pipClose

If you set "player": "mpv", load the window rules so the overlay floats and pins.
Add this to ~/.config/hypr/hyprland.lua:
  dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/$ID/hypr/camguard.lua")
EOF
