#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: broken
# broken: back to full; no back row; the same on dev
#   (local/runs/dev_baseline)
# [MENU_CONTEXT]: leaving a menu-only game for the launcher, driven -- the
# VoxeLibre row opens the world screen (a local server behind it), "< back
# to the launcher" returns to the menu with the client still up, then the
# row is opened a second time and the world screen comes again over a
# fresh connection -- to the same server, which holds no world and so
# stays for the next launch ([SERVER_REUSE], 2026-10-06). Prints PASS or
# FAIL.
#
#   builtin/luanti/test/leave_ui.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_leave_ui.XXXXXX")
cd "$here/Build"
# A server of an earlier run still shutting down would be read as this
# run's; wait for it
for i in $(seq 1 300); do check_pgrep buildat_server >/dev/null || break; sleep 0.2; done
check_pgrep buildat_server >/dev/null && { echo "FAIL: a buildat_server is running" >&2; exit 2; }
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
python3 - "$tmp/cli.log" "$fifo" <<'PY'
import re, sys, time, subprocess
log, fifo = sys.argv[1:3]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+) text "(.*)"')
# The delays a scan and a click write are the frames after a step, for
# what it did to be drawn; what a step is waited for is a log line
def size():
    return len(open(log, "rb").read())
def waitlog(text, secs, since=0):
    # A line with the text past byte <since> of the log
    t0 = time.time()
    while time.time() - t0 < secs:
        if text in open(log, "rb").read()[since:].decode("utf-8", "replace"):
            return True
        # A poll
        time.sleep(0.2)
    return False
def scan(label):
    global seen
    # A settle: the step before drawn in the frames after it
    write("delay 800", "event scan " + label)
    t0 = time.time()
    while time.time() - t0 < 40:
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
def click(e):
    # The click's frames: the hover read before the press, and what it
    # did drawn after
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 150",
          "mouse_click left", "delay 600")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
def server_up():
    return subprocess.run(["bash", "-c", "check_pgrep buildat_server"], capture_output=True).returncode == 0
def open_worlds(tag):
    write("text voxel")
    els = scan("grid" + tag)
    # The row, not the selected entry's name in the logo row (the same
    # word, higher up): the lowest match
    tiles = [e for e in els or [] if "voxelibre" in e[5].lower() and e[3] > 0]
    b = tiles and max(tiles, key=lambda e: e[2])
    if not b: fail("no VoxeLibre row (%s); saw %s" % (tag, ", ".join(e[5] for e in els or [])[:300]))
    at = size()
    click(b)
    # The game's menu says when its list of saves has come
    if not waitlog(" saves, ", 60, at):
        fail("the game's menu never listed its worlds (%s)" % tag)
    for i in range(10):
        els = scan("w%s%d" % (tag, i))
        if els and find(els, "which world?"):
            return els
    fail("the world screen did not come (%s); saw %s" % (tag, ", ".join(e[5] for e in els or [])[:300]))
if not waitlog("launch_menu: ", 30):
    fail("the menu never came up")
els = open_worlds("a")
if not server_up(): fail("no local server behind the world screen")
b = find(els, "back to the launcher")
if not b: fail("no back row")
at = size()
click(b)
if not waitlog("launch_menu: back", 20, at):
    fail("the back row never reached the menu")
els = scan("back")
if not (els and find(els, "Browse") and not find(els, "which world?")):
    fail("not back in the menu; saw " + ", ".join(e[5] for e in els or [])[:300])
def server_pids():
    return subprocess.run(["bash", "-c", "check_pgrep buildat_server"],
            capture_output=True, text=True).stdout.split()
kept = server_pids()
if not kept: fail("the world-less server did not stay ([SERVER_REUSE])")
els = open_worlds("b")
if server_pids() != kept:
    fail("the second launch did not reuse the server: %s, then %s" % (kept, server_pids()))
errors = [l for l in open(log, "rb").read().decode("utf-8", "replace").splitlines()
          if " E " in l[:40] or "Exception" in l]
if errors: fail("error lines: " + errors[0][:200])
print("PASS")
write("quit")
PY
status=$?
exec 3>&-
exit $status
