#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-20)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c src/wasm/engine.cpp apps/workbench/templates/brimstone_speedway/**
# [KIT_INTERP_BUDGETS] Kit's box in the wasm interpreter
# (BUILDAT_CHECK_WASM_INTERPRETER=1: a cold cache while the box compiles,
# a server with no compiler): Brimstone Speedway from its template on
# Workbench, kitboss alone on a headless weston's Xwayland:
#   1. the Bone Yard's corner 3 given 6 m of run-off (the template's
#      corners but {60, -34, 10, 6, 0}): local/brim_yard's build runs and
#      is kept (it ran past a build's budget there); [KIT_BUILD_SLICED]
#      across ticks (some 70 slices), no tick's gap much past a tick and a
#      slice (one call's was some 1.5 s);
#   2. the time trial: after GO kitboss drives up the first straight (the
#      check's driver, util/kit_racer_drive.py): the car goes 20 m or more
#      (its body steps ran past their budget there, and it never moved);
#      no box rebuilt, no step past its budget, and a step's allowance
#      a full batch's (8 inputs at some 25 M units).
#   util/kit_interp_budgets_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_interp_budgets; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build
TRIAL=$(python3 -I - "$here/apps/workbench/templates/brimstone_speedway/composition.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
trial = [e["id"] for e in d["entities"] if e.get("kind") == "scene" and e.get("name") == "trial"][0]
print([e["id"] for e in d["entities"] if e.get("name") == "the race" and e.get("parent") == trial][0])
PY
) || fail "the template's composition"
# The generator (entity 1048) and its corners with corner 3's run-off 6
CORNERS=$(python3 -I - "$here/apps/workbench/templates/brimstone_speedway/types/brim_yard.lua" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
d = re.search(r"default = (\{\{-100.*?\}\})\}", s, re.S)[1]
c = [list(map(float, p.split(","))) for p in re.findall(r"\{([-0-9., ]+)\}", d)]
assert c[2] == [60, -34, 10, 0, 0], c[2]
c[2][3] = 6
print(str([[int(v) for v in p] for p in c]))
PY
) || fail "local/brim_yard's corners"
export PATH_PTS="-100,-58,12 60,-58,10 60,-34,10 10,-34,9 0,-14,9 30,0,10 95,0,12 95,55,12 50,55,9 40,30,8 25,30,8 15,58,10 -40,58,12 -55,20,10 -30,5,9 -60,-10,10 -100,-20,12"

sock=buildat-interp-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
SL=$t/srv.log CL=$t/boss.log
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $BOSS 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
}
cmd() { printf '%s\n' "$@" >&3; }
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
body() # the body's x, z now, into bx, bz
{
	local m
	m=$(mark "$CL")
	step 5 "kit: body at" "event kit_body"
	read bx bz <<< "$(tail -c +$((m + 1)) "$CL" | grep -aoP 'kit: body at \K-?[0-9.]+,-?[0-9.]+,-?[0-9.]+' |
		tail -1 | sed -E 's/^(-?[0-9.]+),-?[0-9.]+,(-?[0-9.]+)$/\1 \2/')"
}
BUILDAT_CHECK_WASM_INTERPRETER=1 start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 5 \
	--sim-rate 1 || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
mkfifo "$t/boss.cmd"
sleep 600 > "$t/boss.cmd" &
CHECK_PIDS+=($!)
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 BUILDAT_JOIN_ADMIN="setting open_registration on" \
	timeout 400 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
	< "$t/boss.cmd" > "$CL" 2>&1 &
BOSS=$!
CHECK_PIDS+=($BOSS)
exec 3> "$t/boss.cmd"
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don*"'
await "$CL" 0 30 "world_menu: the list shown"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Brimstone Speedway"'
step 120 "kit editor: edit mode on" "frames 3" 'click Button "Create"'
grep -aq "The box is up (interpreter)" "$SL" || fail "not the interpreter ($SL)"
# 1. The corners edit: the build runs and is kept
m=$(mark "$SL")
step 60 "kit editor: (state: [0-9]+ entities, 1 to undo|refused)" \
	"event kit_edit {\"op\": \"set\", \"id\": 1048, \"comp\": 0, \"param\": \"corners\", \"value\": $CORNERS}"
# ([KIT_BUILD_SLICED] across ticks: the edit made, its build lands later)
await "$SL" "$m" 90 "Entity 1048's build refused: entity|set 1048's local/brim_yard corners.*built 1048 again"
seen=$(tail -c +$((m + 1)) "$SL" | grep -aE "Entity 1048's build refused: entity|set 1048's local/brim_yard corners.*built 1048 again" | head -1)
echo "$seen" | grep -q "set 1048's local/brim_yard corners.*built 1048 again" ||
	fail "the Bone Yard's corners edit did not build: ${seen:-nothing logged} ($SL)"
# (no tick much past its slice: the ticks' gap at most a tick, a slice and some)
ended=$(tail -c +$((m + 1)) "$SL" | grep -aoP "Entity 1048's build ended: \K.*" | head -1)
python3 -I - "$ended" <<'PY' || fail "the build's slices or the ticks' gap: ${ended:-none} ($SL)"
import re, sys
n, ms, sl, gap = map(float, re.match(r"(\d+) slices, (\d+) ms, spent \d+ M units, slices ([0-9.]+) ms at most, "
	r"the ticks' gap ([0-9.]+) ms at most", sys.argv[1]).groups())
assert n >= 3 and sl < 80 and gap < 250, (n, sl, gap)
PY
echo "ok: the Bone Yard's corner 3 run-off 6 built in the interpreter: $(echo "$seen" | grep -o "built 1048 again.*" | cut -c1-80) (across ticks: $ended)"
# 2. The trial: the car drives
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$CL" 0 10 "kit: ui full screen [0-9]+ up"
m=$(mark "$SL")
mc=$(mark "$CL")
step 10 "kit: ui full screen none" "frames 3" 'click Button "Time trial: The*"'
await "$SL" "$m" 10 "local/brim_race $TRIAL: kitboss starts a time trial"
await "$CL" "$mc" 30 'text .*: "GO!"'
body
x0=$bx z0=$bz
TARGET=40,-58 python3 -I "$here/util/kit_racer_drive.py" "$CL" "$t/boss.cmd" 6 NEVER > "$t/drive.log" 2>&1
body
python3 -I - "$x0" "$z0" "$bx" "$bz" <<'PY' || fail "the car did not drive: $x0,$z0 to $bx,$bz ($SL, $CL, $t/drive.log)"
import sys
x0, z0, x1, z1 = map(float, sys.argv[1:])
d = ((x1 - x0) ** 2 + (z1 - z0) ** 2) ** 0.5
assert d >= 20, d
print("ok: the car drove %.1f m in 6 s in the interpreter" % d)
PY
! grep -aE "past its budget|A new box after" "$SL" || fail "a call past its budget ($SL)"
# (one car alone may not fill a batch here: whether the old 62.5 M was
# passed in a run is luck, so the allowance itself as well, the log's)
python3 -I - "$SL" <<'PY' || fail "a body step's allowance ($SL)"
import re, sys
S = [tuple(map(int, m)) for m in re.findall(r"A S call: (\d+) ms, ok, spent (\d+) of (\d+)", open(sys.argv[1], errors="replace").read())]
assert len(S) > 50, len(S)
assert min(b for _, _, b in S) >= 200000000, min(b for _, _, b in S)
print("ok: %d body steps, at most %d M units and %d ms each, of %d M" % (len(S), max(s for _, s, _ in S) // 10 ** 6, max(t for t, _, _ in S), S[0][2] // 10 ** 6))
PY
cmd quit
echo "PASS: in the wasm interpreter the Bone Yard's corners edit builds and Brimstone's car drives"
# vim: set noet ts=4 sw=4:
