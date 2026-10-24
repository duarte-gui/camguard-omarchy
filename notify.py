#!/usr/bin/env python3
"""Send one CamGuard desktop notification, described as JSON on stdin.

What a camera saw is private: "Person in Gate, Garage camera, 12s ago" says
who is at the door and when. Any process argument is readable by every local
account through /proc/<pid>/cmdline, and omarchy-notification-send forwards its
arguments to busctl as arguments again. So the toast travels as one line on
stdin and goes straight to org.freedesktop.Notifications.Notify from here; the
only argv this process ever has is its own path.

The hints are the ones omarchy-notification-send sets, so the toast looks and
clicks exactly the same:

    {"app": "CamGuard", "summary": "...", "body": "...", "urgency": "critical",
     "glyph": "...", "image": "/path.jpg", "exec": ["omarchy-shell", ...]}
"""

import json
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

URGENCY = {"low": 0, "normal": 1, "critical": 2}


def text(note, key):
    value = note.get(key)
    return value if isinstance(value, str) else ""


def main():
    note = json.loads(sys.stdin.readline())

    hints = {"urgency": GLib.Variant("y", URGENCY.get(text(note, "urgency"), 1))}
    if text(note, "glyph"):
        hints["omarchy-glyph"] = GLib.Variant("s", note["glyph"])
    if text(note, "image"):
        hints["image-path"] = GLib.Variant("s", note["image"])

    # The click command, as the JSON array of words the Omarchy daemon expects
    # in omarchy-exec-argv. It is run as-is and never re-parsed.
    argv = note.get("exec")
    if isinstance(argv, list) and argv and all(isinstance(word, str) for word in argv):
        hints["omarchy-exec-argv"] = GLib.Variant("s", json.dumps(argv, separators=(",", ":")))

    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    bus.call_sync(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
        GLib.Variant(
            "(susssasa{sv}i)",
            (text(note, "app"), 0, "", text(note, "summary"), text(note, "body"), [], hints, -1),
        ),
        GLib.VariantType("(u)"),
        Gio.DBusCallFlags.NONE,
        5000,
        None,
    )


if __name__ == "__main__":
    main()
