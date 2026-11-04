#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# needs: pixels
# cost: 20s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [MENU_KEYS]: the launch menu's keyboard. The client is started with no
# server, because the launch menu is what it shows when it has nothing to
# connect to.
#
# Two halves, and the second is why the first broke once: menu navigation
# stands down while a text field has the focus, and reading that as "the
# focus exists" turns the keyboard off everywhere, because the UI stack
# gives its own root the focus as it pushes it.
#
#   1. On the launch menu, Down moves the selection.
#   2. On Servers, a screen pushed over the menu ([SERVERS_SCREEN]), Down
#      moves the selection too.
#
# The pictures are compared by how many pixels differ, because a focused
# field blinks its caret and that is not the selection moving.
#
# **The screen is found by its text, not by a count of keystrokes**: it was
# Down-then-Return until 2026-09-22, which on the launch menu lands on
# whatever tile is under the first one -- a game, whose saves list answers
# Down by moving its selection, and the check failed on the wrong screen.
#
#   KEEP_TMP=1 builtin/luanti/test/menu_keys.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_menu_keys.XXXXXX")
# KEEP_TMP keeps the four pictures: what a failure here is about is what
# moved between two of them, and the answer is only in the pictures.
trap 'if [ -n "${KEEP_TMP:-}" ]; then echo "kept $tmp" >&2; else rm -rf "$tmp"; fi' EXIT
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a client is already running"; exit 77
fi
fifo="$tmp/cmds.fifo"; mkfifo "$fifo"
# **The menu by name, not by preference** (2026-09-24): this drives
# the launch menu's own screens, and a desk whose `launch_ui` is set
# to something else -- the room, the console -- booted that instead
# and the scan found no rows. `-m launch_menu` asks for the thing the
# check is about ([MENU_FALLBACK]: a launcher nobody drives is a
# launcher nobody notices breaking).
bin/buildat -m launch_menu -w 1280x720 -l 3 -c - < "$fifo" > "$tmp/cli.log" 2>&1 &
cli=$!
exec 3> "$fifo"
python3 - "$tmp" <<'PY'
import os, re, sys, time
from PIL import Image, ImageChops
d = sys.argv[1]
log = os.path.join(d, "cli.log")
w = open(os.path.join(d, "cmds.fifo"), "w")
seen = 0
n = 0
def write(*cmds):
	for c in cmds:
		w.write(c + "\n")
	w.flush()
UI = re.compile(r'ui\s+(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)'
		r'(?: text "(.*?)")?(?: cursor \d+)?(?: selection \S+)?(?: image "(.*?)")?(?: (hidden))?$')
def scan():
	global seen, n
	n += 1
	label = "m%d" % n
	write("event scan 8 %s" % label)
	t0 = time.time()
	while time.time() - t0 < 40:
		data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
		if "scan %s: done" % label in data:
			seen = len(open(log, "rb").read())
			els = []
			for line in data.splitlines():
				m = UI.search(line)
				if m and ("scan %s:" % label) in line and m.group(8) is None:
					els.append((m.group(1), int(m.group(2)), int(m.group(3)),
							int(m.group(4)), int(m.group(5)), m.group(6) or ""))
			return els
		time.sleep(0.3)
	return None
# Each step waits for the line that says it happened, after what the log
# held when the step was sent (or anywhere in it)
def wait_for(text, secs, anywhere=False):
	global seen
	t0 = time.time()
	while time.time() - t0 < secs:
		data = open(log, "rb").read()
		i = data.find(text.encode(), 0 if anywhere else seen)
		if i >= 0:
			seen = i + len(text)
			return
		time.sleep(0.1)
	print("FAIL: no \"%s\" in %d s (%s)" % (text, secs, log))
	write("quit"); sys.exit(1)
def shot(name):
	write("screenshot %s/%s.png" % (d, name))
	wait_for("Wrote screenshot %s/%s.png" % (d, name), 10)
def differing(one, two, right=None):
	a = Image.open(os.path.join(d, one + ".png")).convert("RGB")
	b = Image.open(os.path.join(d, two + ".png")).convert("RGB")
	if right:
		a, b = a.crop((0, 0, right, a.size[1])), b.crop((0, 0, right, b.size[1]))
	diff = ImageChops.difference(a, b)
	return sum(1 for p in diff.getdata() if p != (0, 0, 0))

# The 500 and 300 ms delays are settles: the menu, the selection and the
# connect screen's focus drawn in the frames after
wait_for("rows in", 30, True)
write("delay 500")
# 1. The menu answers the arrows
shot("a")
write("keypress DOWN", "delay 300")
shot("b")
# 2. Servers, Home's row found by its text
els = scan()
entry = None
for e in els or []:
	if e[5] == "Servers" and e[3] > 0:
		entry = e
if entry is None:
	print("FAIL: no \"Servers\" in the menu; saw " +
			", ".join("%r" % x[5] for x in els or [])[:200])
	write("quit"); sys.exit(1)
seen = len(open(log, "rb").read())
# The 300 ms is the hover taken before the press; the 1500 the screen
# laid out after its line, and the lists' fetches answered
write("mouse_pos %d %d" % (entry[1] + entry[3] // 2, entry[2] + entry[4] // 2),
		"delay 300", "mouse_click left")
wait_for("Servers: shown", 10)
write("delay 1500")
shot("c")
write("keypress DOWN", "delay 300")
shot("d")
write("quit")

CARET = 400
moved = differing("a", "b")
moved2 = differing("c", "d")
ok = True
if moved <= CARET:
	print("FAIL: Down moved nothing on the menu (%d pixels)" % moved)
	ok = False
else:
	print("ok: Down moves the selection (%d pixels)" % moved)
if moved2 <= CARET:
	print("FAIL: Down moved nothing on Servers (%d pixels)" % moved2)
	ok = False
else:
	print("ok: Down moves the selection on Servers (%d pixels)" % moved2)
print("PASS: every step above held" if ok else "FAIL: see above")
sys.exit(0 if ok else 1)
PY
status=$?
exec 3>&-
for i in $(seq 50); do kill -0 $cli 2>/dev/null || break; sleep 0.2; done
kill $cli 2>/dev/null
exit $status
