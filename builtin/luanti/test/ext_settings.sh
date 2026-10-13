#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 21s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [EXT_SETTINGS]: the "Luanti client settings" row, driven -- the render
# mode changed in its dropdown and the file read back, the key editor's forward
# row rebound to Y and read back and put back, then Back to the menu. The
# settings file is put back after. Prints PASS or FAIL.
#
#   builtin/luanti/test/ext_settings.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_ext_settings.XXXXXX")
cd "$here/Build"
file=$BUILDAT_USER_PATH/extensions/luanti_client/settings.json
keys=$BUILDAT_USER_PATH/keys.txt
[ -f "$file" ] && cp "$file" "$tmp/settings.bak"
[ -f "$keys" ] && cp "$keys" "$tmp/keys.bak"
trap 'if [ -f "$tmp/settings.bak" ]; then cp "$tmp/settings.bak" "$file"; else rm -f "$file"; fi; if [ -f "$tmp/keys.bak" ]; then cp "$tmp/keys.bak" "$keys"; else rm -f "$keys"; fi; [ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"' EXIT
fifo="$tmp/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
# **The menu by name, not by preference** (2026-09-24): this drives
# the launch menu's own screens, and a desk whose `launch_ui` is set
# to something else -- the room, the console -- booted that instead
# and the scan found no rows. `-m launch_menu` asks for the thing the
# check is about ([MENU_FALLBACK]: a launcher nobody drives is a
# launcher nobody notices breaking).
bin/buildat -m launch_menu -w 1280x720 -l 3 -c - < "$fifo" \
	> "$tmp/cli.log" 2>&1 &
cli=$!
exec 3> "$fifo"
python3 - "$tmp/cli.log" "$fifo" "$file" "$keys" <<'PY'
import re, sys, time, json
log, fifo, path = sys.argv[1:4]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)(?: text "(.*)")?')
def scan(label):
    global seen
    write("delay 800", "event scan " + label)
    t0 = time.time()
    while time.time() - t0 < 30:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan %s: done" % label in data:
            seen = len(open(log, "rb").read())
            els = []
            for line in data.splitlines():
                m = UI.search(line)
                if m and ("scan %s:" % label) in line:
                    els.append((m.group(1), int(m.group(2)), int(m.group(3)),
                                int(m.group(4)), int(m.group(5)), m.group(6) or ""))
            return els
        time.sleep(0.3)
    return None
def find(els, word):
    for e in els:
        if word.lower() in e[5].lower() and e[3] > 0:
            return e
    return None
def click(e):
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 150",
          "mouse_click left", "delay 500")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
time.sleep(8)
write("text luanti client")
els = scan("a")
if not els: fail("no menu scan")
tiles = [e for e in els if "luanti client settings" in e[5].lower() and e[3] > 0]
if not tiles: fail("no settings row; saw " + ", ".join(e[5] for e in els)[:300])
click(max(tiles, key=lambda e: e[2]))
els = scan("b")
row = els and find(els, "Render mode")
if not row: fail("no render mode row; saw " + ", ".join(e[5] for e in els or [])[:300])
# A dropdown since [UI_DROPDOWN]: opened by a click, the next mode picked
# by the keys
drops = [e for e in els[els.index(row):] if e[0] == "DropDownList"]
if not drops: fail("no render mode dropdown")
try:
    before = json.load(open(path)).get("mode")
except IOError:
    before = None
click(drops[0])
write("keypress Down", "delay 300", "keypress Return", "delay 800")
time.sleep(1.5)
data = json.load(open(path))
if data.get("mode") == before or data.get("mode") not in ("unlit", "shadows", "pbr"):
    fail("the mode did not change: %r -> %r" % (before, data.get("mode")))
els = scan("c")
# The key editor: the forward row rebound to Y, read back, and the
# default put back with Backspace
click(find(els, "Key bindings"))
els = scan("e")
row = els and find(els, "Walk forward")
if not row: fail("no key editor; saw " + ", ".join(e[5] for e in els or [])[:300])
click(row)
write("keypress Y", "delay 300")
els = scan("f")
row = els and find(els, "Walk forward")
if not row or not row[5].startswith("Y"): fail("the forward key did not rebind: %r" % (row and row[5]))
time.sleep(0.5)
# The key store's, since 939799cf6: one override line per rebound key
import os
store = sys.argv[4]
try:
    keys = open(store).read()
except IOError:
    keys = ""
if "override\tluanti_client\tforward\tY\n" not in keys + "\n":
    fail("the key store does not say forward is Y: %r" % keys[-300:])
click(row)
write("keypress Backspace", "delay 300")
els = scan("g")
row = els and find(els, "Walk forward")
if not row or not row[5].startswith("W"): fail("the default did not come back: %r" % (row and row[5]))
# Escape is Back on both screens ([BOX_PLAYTEST_2] 6, 7): out of the
# editor to the settings screen, out of that to the menu
write("keypress Escape", "delay 300")
els = scan("h")
if not (els and find(els, "Render mode")): fail("Escape did not leave the editor for the settings screen")
write("keypress Escape", "delay 300")
els = scan("d")
if not (els and find(els, "Settings") and not find(els, "Render mode (next")):
    fail("not back in the menu")
print("PASS: mode %s in %s; forward rebound to Y and back" % (data["mode"], path))
write("quit")
PY
status=$?
exec 3>&-
exit $status
