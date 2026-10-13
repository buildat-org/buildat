#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 26s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [BOX_PLAYTEST_2] (13b): the server list's filter text is kept. The
# luanti_client's "Join a Luanti server" dialog is opened, "mine" typed
# into the filter, the settings file read back, and the dialog opened again
# in a second client to see the field filled. The settings file is put back
# after. Prints PASS or FAIL.
#
#   builtin/luanti/test/ext_filter.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_ext_filter.XXXXXX")
cd "$here/Build"
file=$BUILDAT_USER_PATH/extensions/luanti_client/settings.json
[ -f "$file" ] && cp "$file" "$tmp/settings.bak"
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"; if [ -f "$tmp/settings.bak" ]; then cp "$tmp/settings.bak" "$file"; else rm -f "$file"; fi' EXIT
run() {   # $1 = which pass; drives one client through the python below
	local fifo="$tmp/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
# **The menu by name, not by preference** (2026-09-24): this drives
# the launch menu's own screens, and a desk whose `launch_ui` is set
# to something else -- the room, the console -- booted that instead
# and the scan found no rows. `-m launch_menu` asks for the thing the
# check is about ([MENU_FALLBACK]: a launcher nobody drives is a
# launcher nobody notices breaking).
	bin/buildat -m launch_menu -w 1280x720 -l 3 -c - < "$fifo" \
		> "$tmp/cli.log" 2>&1 &
	exec 3> "$fifo"
	python3 - "$tmp/cli.log" "$fifo" "$file" "$1" <<'PY'
import re, sys, time, json
log, fifo, path, pass_name = sys.argv[1:5]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+) text "(.*)"')
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
                                int(m.group(4)), int(m.group(5)), m.group(6)))
            return els
        time.sleep(0.3)
    return None
def find(els, word):
    for e in els or []:
        if word.lower() in e[5].lower() and e[3] > 0:
            return e
    return None
def click(e):
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 150",
          "mouse_click left", "delay 500")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
time.sleep(8)
write("text join a lua")
els = scan("a")
tile = find(els, "Join a Luanti server")
if not tile: fail("no Luanti row; saw " + ", ".join(e[5] for e in els or [])[:300])
click(tile)
els = scan("b")
label = find(els, "Filter")
if not label: fail("no filter row; saw " + ", ".join(e[5] for e in els or [])[:300])
# The field itself: the first LineEdit the scan lists after the label
edits = [e for e in els if e[0] == "LineEdit" and els.index(e) > els.index(label)]
if not edits: fail("no filter field")
field = edits[0]
if pass_name == "type":
    click(field)
    write("text mine", "delay 300", "keypress Return", "delay 800")
    time.sleep(1.0)
    try:
        data = json.load(open(path))
    except IOError:
        els = scan("c")
        fail("no settings file was written; the screen reads " +
             ", ".join("%s %r" % (e[0], e[5]) for e in els or [])[:300])
    if data.get("server_filter") != "mine":
        fail("the file says %r" % data.get("server_filter"))
    print("PASS: the filter is saved as %r" % data["server_filter"])
else:
    typed = [e for e in els if e[0] == "LineEdit" and e[5] == "mine"]
    if not typed:
        fail("the filter came back empty; saw " +
             ", ".join("%r" % e[5] for e in els or [])[:300])
    print("PASS: the filter is put back as %r" % typed[0][5])
write("quit")
PY
	local status=$?
	exec 3>&-
	sleep 2
	return $status
}
rm -f "$file"
run type || exit 1
run back || exit 1
