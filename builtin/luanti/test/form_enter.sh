#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# ci
# cost: 21s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [FORM_ENTER]: enter in a formspec field sends the form with key_enter and
# key_enter_field, and field_close_on_enter[q;false] keeps it open -- which
# is what a game's creative search is. The fixture's form filters four rows
# by what is typed; the client types "ap", presses Return, and the server
# says what it received.
#
#   builtin/luanti/test/form_enter.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/form_enter"
mkdir -p "$out"
save=buildat_test_form_enter
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/form_enter.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 29785 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -s localhost:29785 -w 1280x720 -l 3 -c - < "$fifo" > "$out/cli.log" 2>&1 &
cli=$!
trap 'kill $cli 2>/dev/null; kill -INT $srv 2>/dev/null' EXIT
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" "$out/srv.log" <<'PY'
import re, sys, time
log, fifo, srv = sys.argv[1:4]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+) text "(.*)"')
def scan():
    # vanilla's scan names its own lines "scan scan:" whatever the event's
    # label is
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
                                int(m.group(4)), int(m.group(5)), m.group(6)))
            return els
        time.sleep(0.3)
    return None
def rows(els):
    for e in els or []:
        if e[5].startswith("rows "):
            return e[5]
    return None
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
# The client's "form form_enter opened", after what the log held when the
# step was sent (or anywhere in it)
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
# The join, and the fixture's form three seconds after it
wait_for("form form_enter opened", 90, True)
els = scan()
before = rows(els)
if before is None:
    fail("no form on the screen; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
edits = [e for e in els if e[0] == "LineEdit" and e[3] > 0]
if not edits:
    fail("no field on the screen")
e = edits[0]
# The 200 ms are the hover and the field's focus taken in the frames after
write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 200",
      "mouse_click left", "delay 200", "text ap", "delay 200",
      "keypress Return")
# The server's answer is the form shown again
wait_for("form form_enter opened", 10)
els = scan()
after = rows(els)
got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
       if "form_enter: fields " in l]
last = got[-1].split("form_enter: fields ")[-1] if got else "nothing"
print("the server received " + last)
print("the form said %r before and %r after" % (before, after))
ok = ("key_enter=true" in last and "key_enter_field=q" in last and
      "q=ap" in last and "quit=nil" in last and
      after == "rows 2: apple apricot")
print("PASS: enter searched and the form stayed open" if ok else
      "FAIL: the enter path is not what a search needs")
write("quit")
sys.exit(0 if ok else 1)
PY
status=$?
exec 3>&-
for i in $(seq 50); do kill -0 $cli 2>/dev/null || break; sleep 0.2; done
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
exit $status
