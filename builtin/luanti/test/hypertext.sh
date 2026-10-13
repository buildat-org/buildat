#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 20s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [FORMSPEC_SCROLL]: a formspec hypertext is drawn, opens on a click and
# sends the item that was picked. The fixture shows a form with
# hypertext[...;alpha,beta,gamma;1]; the client finds the box by its text,
# clicks it, clicks "gamma" in the list that opens, and the server says
# what it received.
#
#   builtin/luanti/test/hypertext.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/hypertext"
mkdir -p "$out"
save=buildat_test_hypertext
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/hypertext.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 29787 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -s localhost:29787 -w 1280x720 -l 3 -c - < "$fifo" > "$out/cli.log" 2>&1 &
cli=$!
trap 'kill $cli 2>/dev/null; kill -INT $srv 2>/dev/null' EXIT
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" "$out/srv.log" <<'PYIN'
import re, sys, time
log, fifo, srv = sys.argv[1:4]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)(?: text "(.*)")?')
def scan():
    global seen
    # A settle: the form drawn in the frames after its line
    write("delay 300", "event scan")
    t0 = time.time()
    while time.time() - t0 < 40:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan scan: done" in data:
            seen = len(open(log, "rb").read())
            els = []
            for line in data.splitlines():
                m = UI.search(line)
                if m and "scan scan:" in line:
                    els.append((m.group(1), int(m.group(2)), int(m.group(3)),
                                int(m.group(4)), int(m.group(5)),
                                m.group(6) or ""))
            return els
        time.sleep(0.3)
    return None
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
# A line in a log, after what it held when the step was sent (or anywhere)
def wait_for(path, text, secs, anywhere=False):
    global seen
    t0 = time.time()
    while time.time() - t0 < secs:
        data = open(path, "rb").read()
        i = data.find(text.encode(), 0 if anywhere or path != log else seen)
        if i >= 0:
            if path == log:
                seen = i + len(text)
            return
        time.sleep(0.1)
    fail("no \"%s\" in %d s (%s)" % (text, secs, path))
# The join, and the fixture's form three seconds after it
wait_for(log, "form hypertext_check opened", 90, True)
els = scan()
write("screenshot " + sys.argv[1].replace("cli.log", "form.png"), "delay 400")
body = [e for e in els or [] if "Some words in it" in e[5]]
if not body:
    fail("the hypertext is not on the screen; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
if "<" in body[0][5]:
    fail("the tags are still in the text: %r" % body[0][5])
act = None
for e in els or []:
    if e[5] == "press here":
        act = e
if not act:
    fail("no action button; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
# The 200 ms is the hover taken before the press
write("mouse_pos %d %d" % (act[1] + act[3] // 2, act[2] + act[4] // 2),
      "delay 200", "mouse_click left")
wait_for(srv, "hypertext: fields doc=", 10, True)
got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
       if "hypertext: fields doc=" in l]
if not got:
    fail("the server received no fields")
last = got[-1].split("hypertext: fields ")[-1]
print("the text reads %r" % body[0][5][:60])
print("the server received " + last)
print("PASS: the action says which one it was" if last == "doc=action:here"
      else "FAIL: the server received " + last)
write("quit")
sys.exit(0 if last == "doc=action:here" else 1)
PYIN
status=$?
exec 3>&-
for i in $(seq 50); do kill -0 $cli 2>/dev/null || break; sleep 0.2; done
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
exit $status
