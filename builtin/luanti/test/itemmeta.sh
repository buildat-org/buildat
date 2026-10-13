#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 23s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [FORMSPEC_SCROLL]: a formspec itemmeta is drawn, opens on a click and
# sends the item that was picked. The fixture shows a form with
# itemmeta[...;alpha,beta,gamma;1]; the client finds the box by its text,
# clicks it, clicks "gamma" in the list that opens, and the server says
# what it received.
#
#   builtin/luanti/test/itemmeta.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/itemmeta"
mkdir -p "$out"
save=buildat_test_itemmeta
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/itemmeta.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 29789 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -s localhost:29789 -w 1280x720 -l 3 -c - < "$fifo" > "$out/cli.log" 2>&1 &
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
def scan():
    global seen
    write("event scan")
    t0 = time.time()
    while time.time() - t0 < 40:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan scan: done" in data:
            seen = len(open(log, "rb").read())
            return [l for l in data.splitlines() if "scan scan:" in l]
        time.sleep(0.3)
    return None
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
# A line in a log, anywhere in it
def wait_for(path, text, secs):
    t0 = time.time()
    while time.time() - t0 < secs:
        if text.encode() in open(path, "rb").read():
            return
        time.sleep(0.1)
    fail("no \"%s\" in %d s (%s)" % (text, secs, path))
# The stacks are set four seconds after the join, on the server; the
# client's world drawn, then a settle of a second for the inventory to
# reach the hotbar in the frames after
wait_for(srv, "itemmeta: the stacks are set", 90)
write("wait_log_any 60000 scene, 0 undrawn within 2", "delay 1000")
lines = scan()
# Slot 1 in hand, which is where the hand's own picture is read; the
# 800 ms are the hand swapped in the frames after the key
png = sys.argv[1].replace("cli.log", "hotbar.png")
write("keypress 1", "delay 800")
write("screenshot " + png)
wait_for(log, "Wrote screenshot " + png, 10)
hot = [l for l in lines or [] if "hotbar" in l]
print((hot[0].split("hotbar ")[-1][:120]) if hot else "no hotbar line")
write("quit")
from PIL import Image
im = Image.open(sys.argv[1].replace("cli.log", "hotbar.png")).convert("RGB")
w, h = im.size
crop = im.crop((w // 3, h - h // 8, 2 * w // 3, h))
# And the hand, which is drawn at the bottom right of the frame
hand = im.crop((int(w * 0.62), int(h * 0.55), int(w * 0.95), int(h * 0.95)))
hpx = list(hand.getdata())
hred = sum(1 for r, g, b in hpx if r > 110 and g < 80 and b < 80)
# Said, not asserted: what the hand holds is not always in the frame
print("the hand's corner is %.2f %% red" % (100.0 * hred / len(hpx)))
px = list(crop.getdata())
red = sum(1 for r, g, b in px if r > 110 and g < 80 and b < 80)
share = 100.0 * red / len(px)
print("the hotbar strip is %.2f %% red" % share)
# The overlay: slot 7 is a dirt with a stone picture over it and slot 5 is
# a plain one, so the two slots cannot read the same. The row is centred
# and eight slots wide at this window, which is what the columns are.
row = im.crop((int(w * 0.32), h - 62, int(w * 0.68), h - 8))
sw = row.size[0] // 8
def slot(i):
    return list(row.crop(((i - 1) * sw, 0, i * sw, row.size[1])).getdata())
a5, a7 = slot(5), slot(7)
diff = sum(abs(p[0] - q[0]) + abs(p[1] - q[1]) + abs(p[2] - q[2])
           for p, q in zip(a5, a7)) / (3.0 * len(a5))
print("slots 5 and 7 differ by %.1f levels" % diff)
# And the palette: slot 6 is a plain testnodes:color and slot 8 the same
# item with palette_index 200 on the stack, so the two cannot read alike
a6, a8 = slot(6), slot(8)
pdiff = sum(abs(p[0] - q[0]) + abs(p[1] - q[1]) + abs(p[2] - q[2])
            for p, q in zip(a6, a8)) / (3.0 * len(a6))
print("slots 6 and 8 differ by %.1f levels" % pdiff)
ok = share > 1.0 and diff > 5 and pdiff > 5
print("PASS: the colour, the overlay and the palette are what is drawn" if ok
      else "FAIL: red %.2f %%, overlay %.1f, palette %.1f" % (
          share, diff, pdiff))
sys.exit(0 if ok else 1)
PYIN
status=$?
exec 3>&-
for i in $(seq 50); do kill -0 $cli 2>/dev/null || break; sleep 0.2; done
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
exit $status
