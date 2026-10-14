#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# ci
# cost: 21s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [FORMSPEC_SCROLL]: a formspec dropdown is drawn, opens on a click and
# sends the item that was picked. The fixture shows a form with
# dropdown[...;alpha,beta,gamma;1]; the client finds the box by its text,
# clicks it, clicks "gamma" in the list that opens, and the server says
# what it received.
#
#   builtin/luanti/test/dropdown.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/dropdown"
mkdir -p "$out"
save=buildat_test_dropdown
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/dropdown.lua" \
	start_server "$out/srv.log" "Mods loaded" 60 29785 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID; cli=""
trap 'kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -s localhost:29785 -w 1280x720 -l 3 -c - < "$fifo" > "$out/cli.log" 2>&1 &
cli=$!
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" "$out/srv.log" "$here/util" <<'PY'
import sys, time
log, fifo, srv = sys.argv[1:4]
sys.path.insert(0, sys.argv[4])
import uidrive
d = uidrive.Drive(log, fifo)
def size():
    return len(open(log, "rb").read())
# Until the client logs <text> after byte <since>, up to <secs>
def until(text, since, secs=10):
    t0 = time.time()
    while time.time() - t0 < secs:
        if text in open(log, "rb").read()[since:].decode("utf-8", "replace"):
            return
        time.sleep(0.2)
    d.fail("no %r in %d s" % (text, secs))
# A scan right after a step's settle, not uidrive's own delay
def scan():
    d.write("event scan")
    lines = d.block("scan", 40)
    return None if lines is None else uidrive.parse_ui(lines)
# The form's own line for a click on it (form_session.lua); the half
# second after it is the form drawn again in the next frames
def click(e):
    p = size()
    d.write("mouse_pos %d %d" % uidrive.centre(e), "mouse_click left")
    until("form: a left click", p)
    d.write("delay 500")
# The form comes up three seconds after the join; its own line on the
# client, and its layout in the half second after
until("form dropdown_check opened", 0, 60)
d.write("delay 500")
els = scan()
box = uidrive.find(els, "alpha")
if not box:
    d.fail("no dropdown on the screen; saw " + uidrive.texts(els))
click(box)
els = scan()
item = uidrive.find(els, "gamma")
if not item:
    d.fail("the list did not open; saw " + uidrive.texts(els))
click(item)
# The server's answer, read from its log as it comes, up to 10 s
t0 = time.time()
while True:
    got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
           if "dropdown: fields pick=" in l]
    if got or time.time() - t0 > 10:
        break
    time.sleep(0.2)
if not got:
    d.fail("the server received no fields")
last = got[-1].split("dropdown: fields ")[-1]
if last != "pick=gamma":
    d.fail("the server received " + last)
print("PASS: the picked item is what was sent")
d.write("quit")
PY
status=$?
exec 3>&-
for i in $(seq 1 50); do kill -0 "$cli" 2>/dev/null || break; sleep 0.2; done
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
exit $status
