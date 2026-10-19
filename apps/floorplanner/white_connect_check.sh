#!/bin/bash
# tier: full
# cost: ~8 min (2026-10-19)
# covers: apps/floorplanner/main/client_lua/editor.lua apps/floorplanner/main/client_lua/daylight.lua apps/floorplanner/main/client_data/fp_frame.xml
# [FP_WHITE_CONNECT]: the 3D view lit on every connect. A server with the
# large plan (apps/floorplanner/test/large_plan.fpplan) imported by a
# user, then 20 connects of that user in a row through util/netsim.py
# (80 ms, 2000 kbit/s), one client directory for all: the first picks 3D
# (F2), the rest come back to it as the view saved (editor.lua's
# restore_view), under the lighting with the drawn probes ("pbr_cube" in
# the client's storage, as the user's was). That was white on every
# connect: the move timing's M.probe_ready (a function) over the probes'
# table of that name raised in the tick before the frame's white was made,
# and a 3D frame drawn without fp_frame.xml's textures lost them for good.
# A shot 3 and 10 s after each entry. Asserted: no "Could not find
# resource generated/" and no Lua error in a client's log, and each
# settled shot's mean within 12 of the connects' median (a white one
# read 200 and over).
#   apps/floorplanner/white_connect_check.sh [connects]
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
n=${1:-20}
check_tmp fp_white; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"
start_server "$t/srv.log" "STATUS Listening" 90 auto bin/buildat_server -m ../apps/floorplanner \
	-D "$t/srv" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | tail -1 | awk '{print $3}')
for i in $(seq 50); do
	np=$((29700 + RANDOM % 300))
	port_taken $np || break
done
python3 "$here/util/netsim.py" --listen $np --to localhost:$SERVER_PORT --delay 80 --rate 2000 \
	> "$t/netsim.log" 2>&1 &
CHECK_PIDS+=($!)
# client <name> <password> <dir> <cmds> <log> [env...]
client() {
	local name=$1 pw=$2 dir=$3 cmds=$4 log=$5; shift 5
	env BUILDAT_FP_NAME=$name BUILDAT_FP_PASSWORD=$pw "$@" timeout 150 bin/buildat \
		-o launch_ui=launch_menu -s localhost:$np -D "$dir" -w 1100x800 -l 3 \
		-o sound_mute=1 -c @"$cmds" > "$log" 2>&1
}
printf '%s\n' "wait_log_any 20000 admin script: done" quit > "$t/adm.cmds"
client adm adminpass12 "$t/adm" "$t/adm.cmds" "$t/adm.log" BUILDAT_FP_CODE=$code \
	BUILDAT_FP_CREATE=1 "BUILDAT_FP_ADMIN=add pl plpass1234" || fail "the admin ($t/adm.log)"
mkdir -p "$t/pl/exports"
cp "$here/apps/floorplanner/test/large_plan.fpplan" "$t/pl/exports/"
cat > "$t/imp.cmds" <<C
wait_log 60000 Plans:
delay 1500
click Button "Import a plan..."
delay 500
click Button "Choose a file..."
wait_log 5000 The file picker at
delay 500
click Button "large_plan.fpplan"
delay 1000
click Button "Import"
wait_log 60000 Entered the plan
delay 1000
mouse_pos 800 600
delay 200
mouse_down left
delay 100
mouse_up left
delay 200
keydown F2
delay 150
keyup F2
delay 3000
quit
C
client pl plpass1234 "$t/pl" "$t/imp.cmds" "$t/imp.log" || fail "the import ($t/imp.log)"
printf pbr_cube > "$t/pl/servers/localhost_$np/lighting"
for i in $(seq $n); do
	cat > "$t/c$i.cmds" <<C
wait_log 90000 Entered the plan
delay 3000
screenshot $t/c${i}_a.png
delay 7000
screenshot $t/c${i}_b.png
quit
C
	client pl plpass1234 "$t/pl" "$t/c$i.cmds" "$t/c$i.log" BUILDAT_FP_PLAN=large_plan ||
		fail "connect $i ($t/c$i.log)"
done
python3 -I - "$t" $n <<'PY' || fail "a connect not lit as the others ($t)"
import sys, statistics
from PIL import Image, ImageStat
t, n = sys.argv[1], int(sys.argv[2])
def mean(p):
    return sum(ImageStat.Stat(Image.open(p).convert("RGB")).mean) / 3
rows = []
for i in range(1, n + 1):
    log = open("%s/c%d.log" % (t, i), errors="replace").read()
    assert "The view of large_plan put back: 3d" in log, ("not back in 3D", i)
    rows.append((mean("%s/c%d_a.png" % (t, i)), mean("%s/c%d_b.png" % (t, i)),
            "Could not find resource generated/" in log or "Runtime error" in log))
for i, (a, b, missing) in enumerate(rows, 1):
    print("connect %d: mean %.0f, settled %.0f%s" % (i, a, b, ", a texture missing or a Lua error" if missing else ""))
med = statistics.median(b for _, b, _ in rows)
bad = [i for i, (_, b, m) in enumerate(rows, 1) if m or abs(b - med) > 12]
assert not bad, ("median %.0f" % med, bad)
PY
echo "PASS: $n connects through netsim, each lit as the others"
