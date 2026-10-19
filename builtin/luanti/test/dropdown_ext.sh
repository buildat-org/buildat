#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [FORMSPEC_SCROLL]: the same dropdown check as dropdown.sh, for
# extensions/luanti_client against official Luanti's server. The worldmod
# shows dropdown[...;alpha,beta,gamma;1]; the client finds the box by its
# text, opens it, picks "gamma", and the server says what it received.
#
#   builtin/luanti/test/dropdown_ext.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/dropdown_ext"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "SKIP: a client or a Luanti server is already running"; exit 77
fi
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/dropdown"
cat > "$work/world.mt" <<MT
gameid = mineclone2
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = dropdown
creative_mode = false
server_announce = false
MT
cp "$me/dropdown.lua" "$work/worldmods/dropdown/init.lua"
printf 'name = dropdown\n' > "$work/worldmods/dropdown/mod.conf"
{ echo "fixed_map_seed = 5"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
( cd "$luanti" && exec "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
srv=$!; cli=""
trap 'kill "$cli" "$srv" 2>/dev/null' EXIT
# "Server for gameid ... listening" is the server taking connections
for i in $(seq 1 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	kill -0 "$srv" 2>/dev/null || break
	sleep 0.2
done
grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null ||
	{ echo "the Luanti server did not come up" >&2; exit 1; }
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=drop \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 -c - \
	< "$fifo" > "$out/cli.log" 2>&1 &
cli=$!
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" "$out/luanti_srv.log" <<'PY'
import re, sys, time
log, fifo, srv = sys.argv[1:4]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+) text "(.*)"')
# The settle before a scan: the form drawn in the frames after the line
# waited for (its opening, the dropdown's)
def scan(label, settle="delay 800"):
    global seen
    write(settle, "event scan " + label)
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
def find(els, text):
    for e in els or []:
        if e[5] == text and e[3] > 0:
            return e
    return None
# The cursor moved is read in the frame after (200 ms), then the click
def click(e, *then):
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 200",
          "mouse_click left", *then)
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
def waitfor(path, text, secs):
    t0 = time.time()
    while time.time() - t0 < secs:
        if text in open(path, "rb").read().decode("utf-8", "replace"):
            return True
        time.sleep(0.3)
    return False
# The client says when it has the form up (a VoxeLibre join, and the
# fixture's three seconds after it)
if not waitfor(log, "form dropdown_check opened", 120):
    fail("the form never opened on the client; see " + log)
els = scan("a")
box = find(els, "alpha")
if not box:
    fail("no dropdown on the screen; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
click(box, 'wait_log 5000 form: dropdown "')
els = scan("b", "delay 300")
item = find(els, "gamma")
if not item:
    fail("the list did not open; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
click(item)
waitfor(srv, "dropdown: fields pick=", 10)
got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
       if "dropdown: fields pick=" in l]
if not got:
    fail("the server received no fields")
last = got[-1].split("dropdown: fields ")[-1]
print("the server received " + last)
print("PASS: the picked item is what was sent" if last == "pick=gamma"
      else "FAIL: the server received " + last)
write("quit")
PY
status=$?
exec 3>&-
# The client ends at the quit and the closed fifo
for i in $(seq 1 50); do kill -0 "$cli" 2>/dev/null || break; sleep 0.2; done
kill "$srv" 2>/dev/null
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
exit $status
