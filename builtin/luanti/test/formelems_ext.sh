#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [FORMSPEC_SCROLL]: the same animated_image and button_url check as
# formelems.sh, for extensions/luanti_client against official Luanti's
# server.
#
#   builtin/luanti/test/formelems_ext.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/formelems_ext"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "SKIP: a client or a Luanti server is already running"; exit 77
fi
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/formelems"
cat > "$work/world.mt" <<MT
gameid = mineclone2
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = formelems
creative_mode = false
server_announce = false
MT
cp "$me/formelems.lua" "$work/worldmods/formelems/init.lua"
printf 'name = formelems\n' > "$work/worldmods/formelems/mod.conf"
{ echo "fixed_map_seed = 5"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
( cd "$luanti" && "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
sub=$!
# Up: its line, then its port bound
for i in $(seq 1 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && port_taken $port && break
	kill -0 $sub 2>/dev/null || break
	sleep 0.2
done
srv=$(pgrep -x luanti-refshots | head -1)
[ -n "$srv" ] || { echo "the Luanti server did not come up" >&2; exit 1; }
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
    # A settle after the form's line: its elements laid out in the
    # frames after it
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
        # A poll for the scan's last line
        time.sleep(0.2)
    return None
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
# The client's line for the form, drawn in the same frame
t0 = time.time()
while time.time() - t0 < 90:
    if "form formelems_check opened" in open(log, "rb").read().decode(
            "utf-8", "replace"):
        break
    # A poll
    time.sleep(0.2)
else:
    fail("the form did not open in the client")
els = scan()
# The shot's frame drawn before the pointer moves
write("screenshot " + sys.argv[1].replace("cli.log", "form.png"), "delay 400")
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
# The click's frames: the hover read before the press
write("mouse_pos %d %d" % (b[1] + b[3] // 2, b[2] + b[4] // 2),
      "delay 200", "mouse_click left")
t0 = time.time()
while time.time() - t0 < 10:
    got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
           if "formelems: fields " in l]
    if got:
        break
    # A poll for the server's line
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
# The client gone at the end of its input, then the server
for i in $(seq 1 50); do kill -0 $cli 2>/dev/null || break; sleep 0.2; done
kill "$srv" 2>/dev/null
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
exit $status
