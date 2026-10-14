#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 16s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [BOX_PLAYTEST_2] (2): the "Join a Luanti server" row in the menu,
# a connect to an address nothing answers at: the failure must be said in
# a dialog and OK must return to the connect screen, not the menu and not
# the desktop. Prints PASS or FAIL.
#
#   builtin/luanti/test/ext_connect_fail.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_ext_connect_fail.XXXXXX")
cd "$here/Build"
file=$BUILDAT_USER_PATH/extensions/luanti_client/settings.json
[ -f "$file" ] && cp "$file" "$tmp/settings.bak"
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"; if [ -f "$tmp/settings.bak" ]; then cp "$tmp/settings.bak" "$file"; else rm -f "$file"; fi' EXIT
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
python3 - "$tmp/cli.log" "$fifo" "$file" <<'PY'
import re, sys, time, json
log, fifo, path = sys.argv[1:4]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+) text "(.*)"')
def scan(label):
    global seen
    # A settle: what the last step changed drawn in the frames after
    write("delay 300", "event scan " + label)
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
    for e in els:
        if word.lower() in e[5].lower() and e[3] > 0:
            return e
    return None
def click(e):
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 150",
          "mouse_click left")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
# The first of the texts in the log after what it held when the step was
# sent (or anywhere in it)
def wait_for(texts, secs, anywhere=False):
    global seen
    t0 = time.time()
    while time.time() - t0 < secs:
        data = open(log, "rb").read()
        for t in texts:
            i = data.find(t.encode(), 0 if anywhere else seen)
            if i >= 0:
                seen = i + len(t)
                return t
        time.sleep(0.1)
    fail("none of %r in %d s (%s)" % (texts, secs, log))
def mark():
    global seen
    seen = len(open(log, "rb").read())
wait_for(["rows in"], 30, True)
mark()
write("text join a lua")
wait_for(['rows for "join a lua"'], 5)
els = scan("a")
if not els: fail("no menu scan")
tiles = [e for e in els if "join a luanti server" in e[5].lower() and e[3] > 0]
if not tiles: fail("no connect row; saw " + ", ".join(e[5] for e in els)[:300])
mark()
click(max(tiles, key=lambda e: e[2]))
wait_for(["Join a Luanti server: shown"], 10)
els = scan("b")
addr = [e for e in els if e[0] == "LineEdit" and ":" in e[5]] if els else None
if not addr: fail("no address field; saw " + ", ".join(e[5] for e in els or [])[:300])
click(addr[0])
write("keypress End", *(["keypress Backspace"] * 40))
write("text 127.0.0.1:1", "delay 300")
b = [e for e in els if e[5] in ("Join", "[J]oin") and e[3] > 0]
if not b: fail("no Join button")
mark()
click(b[0])
# The login to nothing times out; the dialog must say so, and OK must go
# back to the connect screen rather than the menu
ENDED = ["Session ended:", "Could not connect"]
seen_dialog = None
for i in range(2):
    # The network permission dialog of a scripted run comes first, once
    if wait_for(["Asking the user about"] + ENDED, 60) not in ENDED:
        els = scan("c%d" % i)
        a = els and find(els, "Accept")
        if not a:
            fail("no Accept on the permission dialog; saw " + ", ".join(e[5] for e in els or [])[:300])
        # The description field is the caller's ([NET_DESC]): filled in
        # before the user types anything
        desc = [e for e in els if e[0] == "LineEdit" and "Luanti server at" in e[5]]
        if not desc:
            fail("the permission dialog's description is not the caller's; saw " +
                 ", ".join("%s %r" % (e[0], e[5]) for e in els if e[0] == "LineEdit")[:200])
        print("dialog description: " + desc[0][5])
        mark()
        click(a)
        continue
    # The dialog's text runs over two lines, which the scan's one-line
    # reader does not carry; its Ok button, with no address field left,
    # is the dialog, and the reason is read off the log
    els = scan("c%d" % i)
    seen_dialog = els and find(els, "Ok") and not [e for e in els if e[0] == "LineEdit"]
    break
if not seen_dialog: fail("no failure dialog; saw " + ", ".join(e[5] for e in els or [])[:400])
reason = [l for l in open(log, "rb").read().decode("utf-8", "replace").splitlines() if "Session ended:" in l or "Could not connect" in l]
print("dialog: " + (reason[-1].split(": ", 2)[-1] if reason else "?"))
ok = find(els, "Ok")
if not ok: fail("no Ok on the dialog")
mark()
click(ok)
wait_for(["Join a Luanti server: shown"], 10)
els = scan("d")
if not (els and [e for e in els if e[0] == "LineEdit" and ":" in e[5]]):
    fail("OK did not return to the connect screen; saw " + ", ".join(e[5] for e in els or [])[:300])
print("PASS: the failure shown, back on the connect screen")
write("quit")
PY
status=$?
exec 3>&-
exit $status
