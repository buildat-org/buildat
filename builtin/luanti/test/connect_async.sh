#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 17s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# covers: src/client/app.cpp src/client/state.cpp src/impl/packet_stream.cpp src/interface/packet_stream.h
# [BOX_PLAYTEST_2] (12): the connect runs on a worker, so the frame keeps
# drawing while it waits. The client is pointed at a blackholed address
# (192.0.2.1, TEST-NET-1: the SYNs go nowhere and the connect sits for its
# five seconds); the screen's own counter must move while it does, and the
# failure must come as an error afterwards.
#
#   builtin/luanti/test/connect_async.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
out="$here/local/connect_async"; mkdir -p "$out"
if check_pgrep buildat >/dev/null; then
	echo "a client is already running" >&2; exit 2
fi
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
# **The menu by name, not by preference** (2026-09-24): this drives
# the launch menu's own screens, and a desk whose `launch_ui` is set
# to something else -- the room, the console -- booted that instead
# and the scan found no rows. `-m launch_menu` asks for the thing the
# check is about ([MENU_FALLBACK]: a launcher nobody drives is a
# launcher nobody notices breaking).
( cd "$here/Build" && exec bin/buildat -m launch_menu -w 1280x720 -l 3 -c - < "$fifo" \
	> "$out/cli.log" 2>&1 ) &
cli=$!
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" <<'PY'
import re, sys, time
log, fifo = sys.argv[1:3]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'ui\s+(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)'
                r'(?: text "(.*?)")?(?: cursor \d+)?(?: selection \S+)?(?: image "(.*?)")?(?: (hidden))?$')
n = 0
def scan():
    global seen, n
    n += 1
    label = "c%d" % n
    # A settle: what the last step changed drawn in the frames after
    write("delay 300", "event scan 8 %s" % label)
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
                                int(m.group(4)), int(m.group(5)),
                                m.group(6) or ""))
            return els
        time.sleep(0.3)
    return None
def find(els, word):
    for e in els or []:
        if word.lower() in e[5].lower() and e[3] > 0:
            return e
    return None
def click(e):
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2),
          "delay 200", "mouse_click left")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
# A line in the log after what it held when the step was sent (or
# anywhere in it)
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
    fail("no \"%s\" in %d s (%s)" % (text, secs, log))
def mark():
    global seen
    seen = len(open(log, "rb").read())
wait_for("rows in", 30, True)
mark()
write("text join a bu")
wait_for('rows for "join a bu"', 5)
els = scan()
e = find(els, "Join a Buildat server")
if not e:
    fail("no connect entry on the first screen; saw " +
         ", ".join("%r" % x[5] for x in els or [])[:300])
mark()
click(e)
wait_for("Join a Buildat server: shown", 10)
els = scan()
edits = [x for x in els if x[0] == "LineEdit" and x[3] > 0]
if len(edits) < 2:
    fail("the connect screen has %d fields" % len(edits))
# The address field by what it holds: the public servers' search is a
# field too, and comes first ([STARPORT] 4)
address = [x for x in edits if x[5] == "localhost"]
click(address[0] if address else edits[0])
write("keypress End", *(["keypress Backspace"] * 40))
write("text 192.0.2.1", "delay 200")
e = [x for x in els if x[5] == "Join" and x[3] > 0]
if not e:
    fail("no Join button")
mark()
click(e[0])
wait_for("connect_server(): to 192.0.2.1", 10)
# Two readings while the connect runs: the counter has to have moved, which
# is only true if the frame loop ran at all
def counter():
    els = scan()
    t = find(els, "Connecting to")
    return t[5] if t else None
first = counter()
# The time the counter is given to move
time.sleep(2.5)
second = counter()
print("the screen said %r and then %r" % (first, second))
if first is None or second is None:
    fail("no connecting screen: the connect blocked the frame")
def secs(text):
    m = re.search(r"(\d+) s$", text)
    return int(m.group(1)) if m else -1
moved = secs(second) > secs(first)
# And the failure arrives once the five seconds are up
wait_for("connect_server() failed", 15)
els = scan()
shown = "an error" if find(els, "Connect failed") or find(els, "failed") else None
print("after the timeout: %s" % (shown or "nothing"))
print("PASS: the counter moved while the connect ran and it failed after"
      if moved and shown else
      "FAIL: counter %r -> %r, error %r" % (first, second, shown))
write("quit")
sys.exit(0 if (moved and shown) else 1)
PY
status=$?
exec 3>&-
for i in $(seq 50); do kill -0 $cli 2>/dev/null || break; sleep 0.2; done
kill $cli 2>/dev/null
exit $status
