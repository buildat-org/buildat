#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [FORMSPEC_SCROLL]: the same hypertext check as hypertext.sh, for
# extensions/luanti_client against official Luanti's server: the text with
# its tags taken out and its <action> clicked.
#
#   builtin/luanti/test/hypertext_ext.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/hypertext_ext"; mkdir -p "$out"
luanti=$LUANTI
bin=$LUANTI_SERVER_BIN
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a check's client is already running"; exit 77
fi
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/hypertext"
cat > "$work/world.mt" <<MT
gameid = mineclone2
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = hypertext
creative_mode = false
server_announce = false
MT
cp "$me/hypertext.lua" "$work/worldmods/hypertext/init.lua"
printf 'name = hypertext\n' > "$work/worldmods/hypertext/mod.conf"
{ echo "fixed_map_seed = 5"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
start_luanti_server "$work" "$out/luanti.conf" "$out/luanti_srv.log" ||
	{ kill $LUANTI_PID 2>/dev/null; echo "FAIL: the Luanti server did not come up ($out/luanti_srv.log)"; exit 1; }
srv=$LUANTI_PID port=$LUANTI_PORT
trap 'kill "$srv" 2>/dev/null' EXIT
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=drop \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 -c - \
	< "$fifo" > "$out/cli.log" 2>&1 &
cli=$!
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" "$out/luanti_srv.log" <<'PYIN'
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
    # A settle after the form's "opened" line: it drawn before the scan
    write("delay 800", "event scan a")
    t0 = time.time()
    while time.time() - t0 < 40:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan a: done" in data:
            seen = len(open(log, "rb").read())
            els = []
            for line in data.splitlines():
                m = UI.search(line)
                if m and "scan a:" in line:
                    els.append((m.group(1), int(m.group(2)), int(m.group(3)),
                                int(m.group(4)), int(m.group(5)),
                                m.group(6) or ""))
            return els
        # The log polled for the scan's end
        time.sleep(0.2)
    return None
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
# Up to <secs> for a line with <text> in <path>
def logged(path, text, secs):
    t0 = time.time()
    while time.time() - t0 < secs:
        if text in open(path, "rb").read():
            return True
        # The log polled for the line
        time.sleep(0.2)
    return False
# The world's load and the fixture's three seconds after the join: the
# client says when it opens the form
if not logged(log, b"form hypertext_check opened", 120):
    fail("the form was not opened on the client")
els = scan()
write("screenshot " + sys.argv[1].replace("cli.log", "form.png"))
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
# The click's frames: the button hovered a few frames before the press
write("mouse_pos %d %d" % (act[1] + act[3] // 2, act[2] + act[4] // 2),
      "delay 200", "mouse_click left")
logged(srv, b"hypertext: fields doc=", 10)
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
# The client out first, up to ten seconds
for i in $(seq 1 50); do kill -0 "$cli" 2>/dev/null || break; sleep 0.2; done
kill "$cli" "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
exit $status
