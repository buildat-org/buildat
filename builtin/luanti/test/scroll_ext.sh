#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [FORMSPEC_SCROLL]: the same scroll check as scroll.sh, for
# extensions/luanti_client against official Luanti's server: twelve rows in
# a container three units tall, the bar paged twice, the rows read before
# and after.
#
#   builtin/luanti/test/scroll_ext.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/scroll_ext"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "a client or a Luanti server is already running" >&2; exit 2
fi
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/scroll"
cat > "$work/world.mt" <<MT
gameid = mineclone2
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = scroll
creative_mode = false
server_announce = false
MT
cp "$me/scroll.lua" "$work/worldmods/scroll/init.lua"
printf 'name = scroll\n' > "$work/worldmods/scroll/mod.conf"
{ echo "fixed_map_seed = 5"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
( cd "$luanti" && "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
sub=$!
# "Server for gameid=... listening on": up, or the server gone
for i in $(seq 1 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	kill -0 $sub 2>/dev/null || break
	sleep 0.2
done
srv=$(pgrep -x luanti-refshots | head -1)
[ -n "$srv" ] || { echo "the Luanti server did not come up" >&2; exit 1; }
trap 'kill "$srv" 2>/dev/null; kill "${cli:-}" 2>/dev/null' EXIT
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
# The scan's settle: the form drawn in the frames after what changed it
def scan():
    global seen
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
        time.sleep(0.3)
    return None
def rows(els):
    return {e[5]: e[2] for e in els or [] if e[5].startswith("row ")}
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
def sent():
    return open(srv, "rb").read().decode("utf-8", "replace").count(
            "scroll: fields bar=")
t0 = time.time()
while time.time() - t0 < 90:
    if "scroll: the form is shown" in open(srv, "rb").read().decode(
            "utf-8", "replace"):
        break
    time.sleep(0.2)
# Scanned until the client has drawn the form's rows, at most ten times
for _ in range(10):
    els = scan()
    before = rows(els)
    if len(before) >= 12:
        break
if not before:
    fail("no rows on the screen; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
if len(before) < 12:
    fail("only %d rows drawn" % len(before))
bar = None
for e in els:
    if e[0] == "BorderImage" and e[3] < 40 and e[4] > 100:
        bar = e
if not bar:
    fail("no scrollbar found")
# A cursor moved is read in the frame after (200 ms); two clicks at one
# place are 700 ms apart, a form's double click being half a second
for _ in range(2):
    write("mouse_pos %d %d" % (bar[1] + bar[3] // 2,
                               bar[2] + int(bar[4] * 0.75)),
          "delay 200", "mouse_click left", "delay 700")
# And the thumb dragged to the top of the trough, which is the third way
write("mouse_pos %d %d" % (bar[1] + bar[3] // 2, bar[2] + int(bar[4] * 0.9)),
      "delay 200", "mouse_down left", "delay 200")
# Each move read in the frame after, as above
for f in (0.6, 0.3, 0.05):
    write("mouse_pos %d %d" % (bar[1] + bar[3] // 2, bar[2] + int(bar[4] * f)),
          "delay 200")
# The release read and the form's answer drawn before the cursor moves on
write("mouse_up left", "delay 700")
# And the wheel over the container itself
boxes = [e for e in els if e[0] == "UIElement" and e[3] > 150 and e[4] > 80]
if boxes:
    b = boxes[0]
    n = sent()
    # The cursor over the container read in the frame after, then the wheel
    write("mouse_pos %d %d" % (b[1] + b[3] // 2, b[2] + b[4] // 2),
          "delay 300", "mouse_wheel -1")
    # Until the wheel's scroll has reached the server
    t0 = time.time()
    while sent() <= n and time.time() - t0 < 10:
        time.sleep(0.2)
els = scan()
after = rows(els)
print("row 1 at y=%s before, y=%s after" % (before.get("row 1"),
                                            after.get("row 1")))
got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
       if "scroll: fields bar=" in l]
print("the server received " + (", ".join(
        l.split("scroll: fields ")[-1] for l in got[-3:]) if got
        else "nothing"))
moved = (before.get("row 1") is not None and
         after.get("row 1") is not None and
         before["row 1"] - after["row 1"] > 20)
print("PASS: the container scrolled and the bar was sent"
      if moved and got else
      "FAIL: the rows moved %s and the server got %s" % (
          (before.get("row 1", 0) - after.get("row 1", 0)), bool(got)))
write("quit")
PYIN
status=$?
exec 3>&-
for i in $(seq 1 50); do kill -0 $cli 2>/dev/null || break; sleep 0.2; done
kill "$srv" 2>/dev/null
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
exit $status
