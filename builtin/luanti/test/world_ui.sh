#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: broken
# broken: back to full; no save buildat_test_sprites; the same on dev
#   (local/runs/dev_baseline)
# [WORLD_LIST]: the world screen, driven -- the launcher's VoxeLibre row,
# the row SAVE (buildat_test_sprites unless given; a test save of this
# tree's own, a VoxeLibre one) picked, its
# glance in the panel, "Creative mode" ticked and the save's world.mt
# read, then unticked. Read through the UI scan, as menu_drive.py reads
# screens. Prints PASS or FAIL; the shot is local/world_ui/world.png.
#
#   builtin/luanti/test/world_ui.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_world_ui.XXXXXX")
out="$here/local/world_ui"; mkdir -p "$out"
cd "$here/Build"
SAVE="${SAVE:-buildat_test_sprites}"
save=$BUILDAT_USER_PATH/apps/vanilla/saves/$SAVE
[ -d "$save" ] || { echo "FAIL: no save $SAVE; a drive or fixture run makes one" >&2; exit 1; }
fifo="$tmp/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
cli=""
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"; exec 3>&- 2>/dev/null; kill "$cli" 2>/dev/null; check_pkill -INT buildat_server 2>/dev/null' EXIT
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
python3 - "$tmp/cli.log" "$fifo" "$save/luanti/world.mt" "$out/world.png" "$SAVE" "$cli" <<'PY'
import os, re, sys, time
log, fifo, world_mt, shot, SAVE = sys.argv[1:6]
cli = int(sys.argv[6])
out = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        out.write(c + "\n")
    out.flush()
# A stdin drive has no wait_log of its own (-c -): this is it, a regex
# on the client's lines after the last one it matched, polled at 0.2 s
# while the client lives
cursor = 0
def wait(pattern, secs):
    global cursor
    rx = re.compile(pattern)
    for _ in range(int(secs / 0.2)):
        data = open(log, "rb").read()
        at = cursor
        for line in data[cursor:].split(b"\n"):
            at += len(line) + 1
            text = line.decode("utf-8", "replace")
            if "command: " not in text and rx.search(text):
                cursor = at
                return
        try:
            os.kill(cli, 0)
        except OSError:
            fail("the client exited waiting for /%s/" % pattern)
        # the poll
        time.sleep(0.2)
    fail("no /%s/ in %d s" % (pattern, secs))
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+) text "(.*)"')
def scan(label):
    global seen
    # A settle: each scan follows a wait, and the screen it says was
    # drawn is laid out in the frames after the line
    write("delay 800", "event scan " + label)
    t0 = time.time()
    while time.time() - t0 < 10:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan %s: done" % label in data:
            seen = len(open(log, "rb").read())
            els = []
            for line in data.splitlines():
                m = UI.search(line)
                if m and ("scan %s:" % label) in line:
                    els.append((m.group(1), int(m.group(2)), int(m.group(3)),
                                int(m.group(4)), int(m.group(5)), m.group(6)))
            return els
        # A poll for the scan's last line
        time.sleep(0.2)
    return None
def find(els, word):
    for e in els:
        if word.lower() in e[5].lower() and e[3] > 0:
            return e
    return None
# The 150 ms is the cursor read in a frame before the click
def click(e):
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 150",
          "mouse_click left")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
def flag(key):
    try:
        for line in open(world_mt):
            if line.split("=")[0].strip() == key:
                return line.split("=", 1)[1].strip()
    except IOError:
        pass
    return None
wait(r"launch_menu: \d+ rows", 30)
write("text voxel")
wait(r'launch_menu: \d+ rows for "voxel"', 10)
els = scan("a")
if not els: fail("no menu scan")
b = find(els, "VoxeLibre")
if not b: fail("no VoxeLibre row; saw " + ", ".join(e[5] for e in els)[:300])
click(b)
wait(r"menu: \d+ saves, ", 60)
els = scan("b")
edit = els and [e for e in els if e[0] == "LineEdit" and e[3] > 0]
if not edit: fail("no filter field")
click(edit[0])
# Enter would also reach the menu's keyboard walk once the screen is redrawn
# under it; a click on the title ends the edit the same way (TextFinished).
# The 200 ms puts the text and the Return in frames of their own.
write("text " + SAVE, "delay 200", "keypress Return")
wait('menu: filtered by "' + re.escape(SAVE) + '"', 10)
els = scan("b2")
# The row, not the filter field that now says the same
# The row's text is below the filter field, which now says the same
fy = edit[0][2]
row = els and [e for e in els if e[0] == "Text" and e[5] == SAVE and e[2] > fy + 20]
row = row and row[0]
if not row: fail("no row " + SAVE + "; saw " + ", ".join(e[5] for e in els or [])[:400])
click(row)
wait("menu: the world " + re.escape(SAVE) + " shown", 10)
els = scan("c")
if not (els and find(els, "explored")): fail("no glance in the panel; saw " + ", ".join(e[5] for e in els or [])[:400])
write("screenshot " + shot)
wait("Wrote screenshot", 20)
before = flag("creative_mode")
c = find(els, "Creative mode")
if not c: fail("no Creative mode row")
click(c)
# The server writes world.mt and then sends the panel again
wait("menu: the world " + re.escape(SAVE) + " shown", 10)
els = scan("d")
c = els and find(els, "Creative mode")
if not c or not c[5].startswith("[x]"): fail("the tick did not show: " + str(c and c[5]))
now = flag("creative_mode")
if now != "true": fail("world.mt says creative_mode %r after the tick" % now)
click(c)
wait("menu: the world " + re.escape(SAVE) + " shown", 10)
els = scan("e")
c = els and find(els, "Creative mode")
if not c or not c[5].startswith("[ ]"): fail("the untick did not show: " + str(c and c[5]))
if flag("creative_mode") != "false": fail("world.mt not put back")
# Escape on the world screen is Back to the menu ([BOX_PLAYTEST_2] 6)
write("keypress Escape")
wait(r"launch_menu: \d+ rows", 10)
els = scan("esc")
if not (els and find(els, "Browse") and not find(els, "Creative mode")):
    fail("Escape did not leave the world screen for the menu; saw " + ", ".join(e[5] for e in els or [])[:200])
print("PASS (creative_mode was %s before; false now; Escape back to the menu)" % before)
write("quit")
PY
status=$?
exec 3>&-
exit $status
