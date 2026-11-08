#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1.5 min (2026-11-04)
# covers: builtin/kit/client_lua/environment.lua extensions/physical_sky/** extensions/cartoon_sky/** extensions/sky_render/** client/core/urho3d/safe_events.lua
# Kit's sky on Workbench under clouds (chunk 4, from the chunk 3 playtest).
# A fresh save, the admin Ended, the root's kit/environment at 10 o'clock,
# the editor's 3D camera looking straight at the sun:
#   1. [KIT_SUN_THROUGH_CLOUDS] the sun's disc dims with the light the
#      clouds let through (environment.lua's sun_through()), both
#      lightings: at a cover of 0.2 (all through), 0.4, 0.8 and 1 the disc
#      (the frame's middle) over the sky around it (a ring off the disc),
#      the contrast falling with the cover and gone at 1 (physical's
#      white disc at 0.4 within 15% of 0.2's). The wind 0, so
#      the clouds stand where they are between the shots.
#   2. [CLOUD_WIND_JUMP] the wind faded from 2 to 30 cells a second over
#      3 s: the dome's offset lines (physical_sky, verbose: one a step
#      whose wind changed) move the clouds by that step's wind times its
#      time and no more -- the shaders' old cElapsedTimePS * wind moved
#      them by the change times all the time elapsed.
# KEEP_TMP=1 keeps the shots; look at them.
#   util/kit_sky_clouds_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
check_user
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_sky_clouds; t=$CHECK_TMP
cd "$here/Build"
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
ep() # <param> <json value>: the environment's (entity 3)
{
	edit "{\"op\": \"set\", \"id\": 3, \"comp\": 0, \"param\": \"$1\", \"value\": $2}"
}
# At 10 o'clock the sun is toward (0.246, 0.781, -0.574)
# (environment.lua's sun_toward, at the default latitude 25 and north 30); the camera looks at it from (20, 4, 20)
shot() # <name>
{
	printf 'event kit_cam3d 20 4 20 22.46 11.81 14.26\nframes 10\ndelay 3000\nframes 3\nscreenshot @T@/%s.png\n' "$1"
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	edit '{"op": "place", "type": "kit/environment", "pos": [0, 1, 0]}'
	echo "wait_log_any 10000 kit: environment: from the root, 3,"
	ep weather_fade 0
	ep cloud_wind_speed 0
	ep time 10
	for mode in cartoon physical; do
		# cartoon set after fast_physical, the default: no line waited for
		ep lighting "\"$mode\""
		[ $mode = cartoon ] || echo "wait_log_any 10000 kit: lighting $mode"
		for c in 0.2 0.4 0.8 1; do
			ep cloud_cover $c
			printf 'wait_log_any 10000 kit: sky: %s, 10.0 o%sclock, sun 1, moon 0, stars 0.00, clouds %.2f\n' "$mode" "'" "$c"
			shot "${mode}_$c"
		done
	done
	# 2. The wind faded from 2 to 30 over 3 s
	ep cloud_cover 0.5
	ep cloud_wind_speed 2
	echo "delay 1000"
	ep weather_fade 3
	ep cloud_wind_speed 30
	echo "wait_log_any 10000 kit: sky: physical, 10.0 o'clock, sun 1, moon 0, stars 0.00, clouds 0.50 at 120, wind 30.0"
	echo "delay 1000"
	echo quit
} > "$t/boss.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
sed -i "s|@T@|$t|g" "$t/boss.cmds"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	run_client 60 "$t/boss.log" timeout 300 bin/buildat -C "$t/client_cache" \
	-D "$t/cu_boss" -s localhost:$SERVER_PORT -w 1024x700 -l 4 \
	-o lighting=game -c @"$t/boss.cmds" ||
	fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null

# 1. The disc over the sky around it: the frame's middle (a 40 px square)
# over a ring 110-150 px out, as brightness (0..255)
disc() # <png>
{
	python3 -I - "$1" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("L")
cx, cy = im.width // 2, im.height // 2
mid, ring = [], []
for y in range(cy - 150, cy + 151, 2):
	for x in range(cx - 150, cx + 151, 2):
		r = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
		if r < 20:
			mid.append(im.getpixel((x, y)))
		elif 110 < r < 150:
			ring.append(im.getpixel((x, y)))
print("%.1f" % (sum(mid) / len(mid) - sum(ring) / len(ring)))
EOF
}
for mode in cartoon physical; do
	for c in 0.2 0.4 0.8 1; do
		[ -s "$t/${mode}_$c.png" ] || fail "no shot ${mode}_$c ($t/boss.log)"
	done
	a=$(disc "$t/${mode}_0.2.png") b=$(disc "$t/${mode}_0.4.png")
	d=$(disc "$t/${mode}_0.8.png") e=$(disc "$t/${mode}_1.png")
	# 0.4 lets 0.8 through: physical's disc still white (it saturates), the
	# ring around it metered, so its contrast within 15% of 0.2's
	awk "BEGIN{exit !($a > 40 && $b < $a * 1.15 && $d < $b * 0.5 && $e < 5 && $e > -5)}" ||
		fail "$mode: the sun's disc over the sky around it at a cover of 0.2, 0.4, 0.8 and 1: $a, $b, $d, $e (it should fall with the cover and be gone at 1)"
	echo "ok: $mode: the sun's disc over the sky around it at a cover of 0.2, 0.4, 0.8 and 1: $a, $b, $d, $e"
done

# 2. Each offset line against the one before: the clouds moved by the
# step's wind times its time (the wrap to the period undone)
# (the lines after the wind's change to 30: a fade's steps, each logged)
sed -n '/command: event kit_edit .*"cloud_wind_speed", "value": 30/,$p' \
	"$t/boss.log" | grep -aoP 'sky: clouds at \K.*' > "$t/offsets.txt"
python3 -I - "$t/offsets.txt" <<'EOF' || fail "the clouds' offset through the wind's fade ($t/offsets.txt)"
import re, sys
rows = []
for l in open(sys.argv[1]):
	m = re.match(r"(\S+) (\S+), wind (\S+) (\S+), step (\S+)", l)
	rows.append([float(v) for v in m.groups()])
def wrap(d):
	return (d + 500) % 1000 - 500
winds = [abs(r[3]) for r in rows]
if len(rows) < 30 or max(winds) < 10 * max(min(winds), 1e-6):
	sys.exit("%d lines, the wind %.4f to %.4f: no fade seen" % (len(rows),
			min(winds), max(winds)))
worst = 0
for a, b in zip(rows, rows[1:]):
	moved = (wrap(b[0] - a[0]) ** 2 + wrap(b[1] - a[1]) ** 2) ** 0.5
	# a line is logged before its step moves the clouds, so the next one
	# is where a's wind took them in a's time
	step = (a[2] ** 2 + a[3] ** 2) ** 0.5 * a[4]
	if step <= 0 or moved > step * 1.01 + 1e-4:
		sys.exit("moved %.5f where a step's wind moves %.5f: %s" % (moved,
				step, a))
	worst = max(worst, moved / step if step > 0 else 0)
print("ok: the clouds through the wind's fade (%d steps, the wind %.4f to "
		"%.4f): each step moved them by its wind times its time (the most "
		"%.3f of it)" % (len(rows), min(winds), max(winds), worst))
EOF
echo "PASS: Kit's sky under clouds: the sun's disc dims with the cover, gone at 1, both lightings; a wind's fade moves the clouds by each step's wind"
# vim: set noet ts=4 sw=4:
