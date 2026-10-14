#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# ci
# cost: 19s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [FORMSPEC_SCROLL]: a formspec formelems is drawn, opens on a click and
# sends the item that was picked. The fixture shows a form with
# formelems[...;alpha,beta,gamma;1]; the client finds the box by its text,
# clicks it, clicks "gamma" in the list that opens, and the server says
# what it received.
#
#   builtin/luanti/test/formelems.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/formelems"
mkdir -p "$out"
save=buildat_test_formelems
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/formelems.lua" \
	start_server "$out/srv.log" "Mods loaded" 60 29788 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID; cli=""
trap 'kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -s localhost:29788 -w 1280x720 -l 3 -c - < "$fifo" > "$out/cli.log" 2>&1 &
cli=$!
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
    write("event scan")
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
# The form's own line on the client (form_session.lua); the half second
# after it is its layout done in the next frames
t0 = time.time()
while time.time() - t0 < 60:
    if "form formelems_check opened" in open(log, "rb").read().decode(
            "utf-8", "replace"):
        break
    time.sleep(0.3)
else:
    fail("the form was not shown")
# The form laid out in the frames after its line
write("delay 500")
els = scan()
write("screenshot " + sys.argv[1].replace("cli.log", "form.png"))
url = [e for e in els or [] if e[5] == "https://example.org/manual"]
label = [e for e in els or [] if e[5] == "Read the manual"]
if not label:
    fail("no url button; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
if not url:
    fail("the url is not shown under the label")
# The animated image: a BorderImage of about a hundred pixels at the top
# left of the form, where the element is
anim = [e for e in els or [] if e[0] == "BorderImage" and
        40 < e[3] < 120 and 40 < e[4] < 120]
if not anim:
    fail("no animated image drawn")
b = label[0]
write("mouse_pos %d %d" % (b[1] + b[3] // 2, b[2] + b[4] // 2),
      "mouse_click left")
# The server's answer, read from its log as it comes, up to 10 s
t0 = time.time()
while True:
    got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
           if "formelems: fields " in l]
    if got or time.time() - t0 > 10:
        break
    time.sleep(0.2)
if not got:
    fail("the server received no fields")
last = got[-1].split("formelems: fields ")[-1]
print("the image is %dx%d, the url is shown" % (anim[0][3], anim[0][4]))
print("the server received " + last)
print("PASS: the url button presses like a button" if "visit=" in last
      else "FAIL: the server received " + last)
write("quit")
PYIN
status=$?
exec 3>&-
for i in $(seq 1 50); do kill -0 "$cli" 2>/dev/null || break; sleep 0.2; done
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
exit $status
