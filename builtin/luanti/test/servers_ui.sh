#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 27s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [SERVER_LIST]: the two connect screens, driven -- the launch menu's
# "Join a Buildat server" shot with the used addresses on the left; then the
# luanti_client's dialog, "Official list" picked, the permission dialog
# accepted, the list read (rows with a players count) and shot. The
# addresses file is put back after. Prints PASS or FAIL; the shots are
# local/servers_ui/*.png. Needs the network.
#
#   builtin/luanti/test/servers_ui.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_servers_ui.XXXXXX")
out="$here/local/servers_ui"; mkdir -p "$out"
cd "$here/Build"
addr=$BUILDAT_USER_PATH/network_addresses.csv
[ -f "$addr" ] && cp "$addr" "$tmp/addresses.bak"
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"; if [ -f "$tmp/addresses.bak" ]; then cp "$tmp/addresses.bak" "$addr"; fi' EXIT
run() {   # module-flag... -- runs one client with the python driver on stdin
	local fifo="$tmp/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
# **The menu by name, not by preference** (2026-09-24): this drives
# the launch menu's own screens, and a desk whose `launch_ui` is set
# to something else -- the room, the console -- booted that instead
# and the scan found no rows. `-m launch_menu` asks for the thing the
# check is about ([MENU_FALLBACK]: a launcher nobody drives is a
# launcher nobody notices breaking).
	bin/buildat -m launch_menu -w 1280x720 -l 3 -c - "$@" < "$fifo" \
		> "$tmp/cli.log" 2>&1 &
	local cli=$!
	exec 3> "$fifo"
	python3 - "$tmp/cli.log" "$fifo" "$out" "$STAGE" <<'PY'
import re, sys, time
log, fifo, out, stage = sys.argv[1:5]
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
    print("FAIL (%s): %s" % (stage, why)); write("quit"); sys.exit(1)
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
# The menu up, or luanti_client's connect dialog, drawn right after its
# self-tests
wait_for(["rows in" if stage == "launch" else "world: self-test ok"], 30, True)
els = scan("a")
if not els: fail("no menu scan")
if stage == "launch":
    mark()
    write("text join a bu")
    wait_for(['rows for "join a bu"'], 5)
    els = scan("a2")
    b = els and find(els, "Join a Buildat server")
    if not b: fail("no Join a Buildat server; saw " + ", ".join(e[5] for e in els)[:300])
    mark()
    click(b)
    wait_for(["Join a Buildat server: shown"], 10)
    els = scan("b")
    if not (els and find(els, "Servers used")): fail("no used list; saw " + ", ".join(e[5] for e in els or [])[:300])
    write("screenshot " + out + "/launch_connect.png")
    wait_for(["Wrote screenshot " + out + "/launch_connect.png"], 10)
    print("PASS (launch)")
else:
    b = find(els, "Official list")
    if not b: fail("no Official list button; saw " + ", ".join(e[5] for e in els)[:300])
    mark()
    click(b)
    # The network permission asked for once a user path; the list's answer
    # is a line either way
    if wait_for(["Asking the user about", "the official list"], 10) != \
            "the official list":
        els = scan("c")
        a = els and find(els, "Accept")
        if a:
            mark()
            click(a)
        wait_for(["the official list"], 30)
    els = scan("d")
    st = els and find(els, " servers")
    if not st: fail("the list did not come; saw " + ", ".join(e[5] for e in els or [])[:400])
    rows = [e for e in els if e[0] == "Text" and re.search(r"\d+/\d+", e[5])]
    if not rows: fail("no row with a players count")
    write("screenshot " + out + "/official_list.png")
    wait_for(["Wrote screenshot " + out + "/official_list.png"], 10)
    click(rows[0])
    els = scan("e")
    addr = [e for e in els if e[0] == "LineEdit" and ":" in e[5]]
    if not addr: fail("the pick did not fill the address")
    print("PASS (luanti_client): %s, %d rows, picked %s" % (st[5], len(rows), addr[0][5]))
write("quit")
PY
	local status=$?
	exec 3>&-
	wait "$cli" 2>/dev/null
	return $status
}
STAGE=launch run || {
	echo "FAIL: the launcher's server list did not come up or could not be picked from"
	exit 1
}
STAGE=luanti_client run -m luanti_client || {
	echo "FAIL: luanti_client's server list did not come up or could not be picked from"
	exit 1
}
# **The canonical last line** ([CI_RUNS]'s contract): the stages print
# "PASS (launch)" and "PASS (luanti_client)", which run_all.sh's
# "^(PASS|FAIL|SKIP):" does not read, so the run had no verdict anybody
# could see -- the exit status alone (2026-09-25)
echo "PASS: both clients list servers and a pick fills the address"
exit 0
