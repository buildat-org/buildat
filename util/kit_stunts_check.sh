#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-23)
# covers: apps/workbench/templates/brimstone_stunts/** builtin/kit/types/controls.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/move.lua builtin/kit/types/path.lua util/kit_racer_drive.py builtin/kit/types/parallax.lua builtin/kit/types/part.lua
# [KIT_STUNTS] (kit_plan 4z37zzd (1)) The Brimstone Stunts template (Brimstone
# Speedway's fork in kit/controls' chase camera) on Workbench; one server,
# kitboss on a headless weston's Xwayland of the check's own:
#   1. New from it: its types local/stunt_*, the camera chase, the car's draw
#      hook; the lobby (lobby.png);
#   2. a time trial's lap (trial_laps 1) driven round the Bone Yard's centre
#      line by util/kit_racer_drive.py: checkpoints 1-3 and the lap; at each
#      body sample the camera behind the car along the way the camera
#      faces, near the chase's distance and above the car, its yaw following
#      the car's (never far off, on it once straight); screenshots round the
#      lap (lap_*.png) and the result card (trial.png).
#   3. [KIT_STUNTS] (4z37zzd (2)) The heights, from the same samples and the
#      template's own polygons (the trial scene's generator's): off each
#      tabletop jump's lip the car over 0.2 m above its floor (the floor as
#      the car finds it: the highest top edge at most 0.6 over it, the road
#      0.555), then on it again; at the figure eight's crossing (the bridge)
#      the car once on the deck (y 5.055) and once under it (0.555), nowhere
#      between, not slowed there (no wall of the other level met); the
#      camera never inside a height's prism (w:ray meets them: under the deck
#      it comes in under the roof).
#   4. [KIT_3D_GAINS_1] (4z37zzd (2), 4z38) The scenery on that lap: a boost
#      pad's surface felt (the car's draw sees its floor), a flock of birds
#      scattered by the car (their client part), the fans cheering, the
#      mountains a far parallax layer (drawn far, their colours above the
#      horizon only in lap_1_start.png: behind the world), the looks culled
#      at the far clip; the lap's frame time (event kit_looks) and Kit's tick
#      (BUILDAT_KIT_METER=1) printed; then a hammer met: the car put where
#      the first hammer's head swings low (walk_here), pushed out of its reach
#      (kit/wave on the free kit/hammer: w:circle's sliced boxes), its
#      samples there (hammer.png).
#   5. [KIT_STUNTS] (4z37zzd (3)) The loop on that lap (the line through its
#      entry lane: PATH_PTS): on it (the body's up logged) its up pointing
#      down at the top (y over 12), the camera's up turned with it (its
#      camera_frame "body"), the camera never inside one of the loop's facets
#      (w:ray keeps it out); off it level on the road again, the camera level;
#      screenshots before it, upside down at its top, after it (loop_*.png).
#      Then into it at 12 m/s (the driver's TOP): up its side, off it short of
#      the top and down on the road again.
# Screenshots, kept with KEEP_TMP=1: $t/lobby.png, $t/lap_*.png (the start,
# the bridge's ramp, its deck, the loop, the east, a jump in the air and
# landed, under the bridge, the second jump, the last straight),
# $t/loop_before.png, $t/loop_top.png, $t/loop_after.png, $t/trial.png,
# $t/hammer.png
#   util/kit_stunts_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_stunts; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build

# The trial's race and the controls' distance (the template's)
python3 -I - "$here/apps/workbench/templates/brimstone_stunts/composition.json" \
		> "$t/ids" <<'PY' || fail "the template's composition"
import json, sys
d = json.load(open(sys.argv[1]))
scene = {e["name"]: e["id"] for e in d["entities"] if e.get("kind") == "scene"}
trial = [e["id"] for e in d["entities"] if e.get("name") == "the race" and
         e.get("parent") == scene["trial"]][0]
ctl = [c["params"] for e in d["entities"] for c in e.get("components", [])
       if c["type"] == "kit/controls"][0]
assert ctl["camera"] == "chase" and ctl["chase_follow"] > 0, ctl
print("TRIAL=%d DIST=%s" % (trial, ctl["distance"]))
PY
. "$t/ids"
# The Bone Yard's line: stunt_yard's default corners (a figure eight),
# ([KIT_STUNTS] (4z37zzd (3))) 3 m left of the middle into the loop at 58,10
# (its entry lane, the yard's LOOP.lane; out of it 3 m right), then the
# middle again (the gantry's hammer swings over the left side)
export PATH_PTS="-100,10,16 30,10,60 50,13,60 60,13,60 74,10,60 100,10,20 100,68,16 0,68,14 0,-68,14 -100,-68,16"

sock=buildat-stunts-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
SL=$t/srv.log CL=$t/boss.log CLIENT=
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
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
export BUILDAT_KIT_METER=1
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate 1 || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
unset BUILDAT_KIT_METER
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
grep -aq "workbench: the template in .*brimstone_stunts" "$SL" && fail "the template refused ($SL)"
mkfifo "$t/boss.cmd"
sleep 600 > "$t/boss.cmd" &
CHECK_PIDS+=($!)
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 BUILDAT_JOIN_ADMIN="setting open_registration on" \
	timeout 400 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
	< "$t/boss.cmd" > "$CL" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/boss.cmd"
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don*"'

# 1. New from the template: its types, the chase camera, the car drawn
await "$CL" 0 30 "world_menu: the list shown"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Brimstone Stunts"'
step 120 "kit editor: edit mode on" "frames 3" 'click Button "Create"'
for re in "The template's type local/stunt_car \([0-9]+ bytes\)" "The template's type local/stunt_race " \
		"The template's type local/stunt_mine " "The template's type local/stunt_weapons " \
		"The template's type local/stunt_yard "; do
	grep -aqE "$re" "$SL" || fail "no \"$re\" in $SL"
done
step 10 "entities, 1 to undo" "event kit_edit {\"op\": \"set\", \"id\": $TRIAL, \"comp\": 0, \"param\": \"trial_laps\", \"value\": 1}"
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$CL" 0 10 "kit: controls: camera chase, pointer cursor, movement local/stunt_car, plane y 1"
await "$CL" 0 10 "stunt_car: the draw hook draws a car"
await "$CL" 0 10 'kit: ui [0-9]+ list .* shown, layer [0-9]+: "Pick your poison \| Race: The Bone Yard, by buildat \| Time trial: The Bone Yard, by buildat"'
step 10 "Wrote screenshot $t/lobby.png" "frames 10" "screenshot $t/lobby.png"
echo "ok: a game from Brimstone Stunts: its local/stunt_* types, the chase camera, the car's draw hook, the lobby"

# 2. The trial's lap in the chase view
m=$(mark "$SL")
step 10 "kit: ui full screen none" "frames 3" 'click Button "Time trial: The*"'
await "$SL" "$m" 10 "local/stunt_race $TRIAL: kitboss starts a time trial"
# (the lap's frames counted from here: kit_looks starts them over)
step 10 "kit: looks: " "event kit_looks"
mc=$(mark "$CL")
UP_SHOT=$t/loop_top.png SHOTS_IN_ORDER=1 SHOTS="-100,-10,$t/lap_1_start.png -30,10,$t/lap_2_ramp.png -3,10,$t/lap_3_deck.png 47,13,$t/loop_before.png 76,9,$t/loop_after.png 101,46,$t/lap_4_east.png 53,68,$t/lap_5_jump.png 30,68,$t/lap_6_landed.png 0,10,$t/lap_7_under.png -42,-68,$t/lap_8_jump2.png -100,-40,$t/lap_9_last.png" \
	python3 -I "$here/util/kit_racer_drive.py" "$CL" "$t/boss.cmd" 150 \
	'panel .* shown, layer [0-9]+: "The flag is down' > "$t/drive.log" 2>&1 ||
	fail "the driver: $(tail -2 "$t/drive.log")"
step 10 "Wrote screenshot $t/trial.png" "frames 10" "screenshot $t/trial.png"
python3 -I - "$SL" "$m" "$TRIAL" <<'PY' || fail "the trial's lap ($SL)"
import re, sys
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
race = "local/stunt_race %s: kitboss " % sys.argv[3]
order = [l.split(race, 1)[1] for l in s.splitlines() if race in l]
lap = [i for i, l in enumerate(order) if l.startswith("lap 1 in")]
cp = [i for i, l in enumerate(order) if l.startswith("passed checkpoint")]
assert len(lap) == 1 and len(cp) == 3 and max(cp) < lap[0], order
assert any(l.startswith("finished the trial in") for l in order), order
print("ok: the trial: %s" % "; ".join(order[1:]))
PY
# Each sample (event kit_body: the body, the camera's place and the chase's
# yaw in turn): the camera behind the body along its own yaw, near the
# distance (a wall between shortens it; smoothing and the drawn place lag
# the step's a little) and above it; the yaw following the car's (on the
# level: the loop's samples, its up logged, in 5.)
python3 -I - "$CL" "$mc" "$DIST" <<'PY' || fail "the chase camera ($CL)"
import math, re, sys
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
dist = float(sys.argv[3])
S, b, c = [], None, None
for l in s.splitlines():
    m = re.search(r"kit: body at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+),", l)
    if m:
        b, c = tuple(map(float, m.groups())), None
    if "kit: body up " in l:
        b = None
    m = re.search(r"kit: camera at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+) ", l)
    if m:
        c = tuple(map(float, m.groups()))
    m = re.search(r"kit: chase yaw (-?[0-9.]+), the body's (-?[0-9.]+)", l)
    if m and b and c:
        S.append((b, c, float(m[1]), float(m[2])))
        b = c = None
def off(a, b):
    return abs((a - b + 540) % 360 - 180)
assert len(S) > 100, len(S)
bad = []
for (bx, by, bz), (cx, cy, cz), cyaw, byaw in S:
    fx, fz = math.sin(math.radians(cyaw)), math.cos(math.radians(cyaw))
    back = -((cx - bx) * fx + (cz - bz) * fz)
    side = abs((cx - bx) * fz - (cz - bz) * fx)
    # (up to 6 m above: on the downhill ramp the camera keeps its height
    # a moment, 5.0-5.3 m over the car; at faster frames more such samples)
    if not (1 < back < dist + 3 and side < 3 and 0.5 < cy - by < 6):
        bad.append((round(back, 1), round(side, 1), round(cy - by, 1)))
assert len(bad) <= len(S) // 20, "not behind the car: %d of %d: %r" % (len(bad), len(S), bad[:10])
most = max(off(cy, by) for _, _, cy, by in S)
assert most < 45, "the camera %.0f degrees off the car" % most
yaws = [by for _, _, _, by in S]
turned = sum(off(yaws[i], yaws[i - 1]) for i in range(1, len(yaws)))
assert turned > 300, turned
backs = sorted(-((c[0] - b[0]) * math.sin(math.radians(cy)) + (c[2] - b[2]) * math.cos(math.radians(cy)))
               for b, c, cy, _ in S)
print("ok: the chase camera over %d samples: behind the car %.1f m (median; %d off), "
      "its yaw at most %.0f deg off the car's through %.0f deg of turns" %
      (len(S), backs[len(backs) // 2], len(bad), most, turned))
PY
# 3. The heights: the jumps, the bridge over and under, the camera out of them
python3 -I - "$CL" "$mc" "$here/apps/workbench/templates/brimstone_stunts/composition.json" <<'PY' ||
import json, math, re, sys
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
d = json.load(open(sys.argv[3]))
scene = {e["name"]: e["id"] for e in d["entities"] if e.get("kind") == "scene"}
gen = [e["id"] for e in d["entities"] if e.get("parent") == scene["trial"] and
       e["components"][0]["type"] == "local/stunt_yard"][0]
# The standing polygons (no pitch): their outline in the world's x, y, z0...z1
polys = []
for e in d["entities"]:
    c = e["components"][0] if e.get("parent") == gen else {}
    if c.get("type") == "kit/polygon" and not e.get("pitch"):
        x, y, z = e["pos"]
        h = c["params"]["depth"] / 2
        polys.append((e["name"], [(x + a, y + b) for a, b in c["params"]["points"]], z - h, z + h))
assert sum(1 for p in polys if p[0] == "the bridge") == 1, [p[0] for p in polys]
jumps = [p for p in polys if p[0] == "a tabletop jump"]
assert len(jumps) >= 2, [p[0] for p in polys]
def floor(x, y, z):
    """The car's floor: the highest top edge (going +x: the generator writes
    the outline clockwise) at most 0.6 over y, else the road's top"""
    best = 0.555
    for _, pts, z0, z1 in polys:
        if not z0 < z < z1:
            continue
        for (ax, ay), (bx, by) in zip(pts, pts[1:] + pts[:1]):
            if ax < bx and ax <= x <= bx:
                t = ay + (by - ay) * (x - ax) / (bx - ax)
                if t <= y + 0.6:
                    best = max(best, t)
    return best
def inside(x, y, z):
    for name, pts, z0, z1 in polys:
        if z0 < z < z1:
            c = False
            for (ax, ay), (bx, by) in zip(pts, pts[1:] + pts[:1]):
                if (ay > y) != (by > y) and x < ax + (bx - ax) * (y - ay) / (by - ay):
                    c = not c
            if c:
                return name
S, b, c = [], None, None
for l in s.splitlines():
    m = re.search(r"kit: body at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+),", l)
    if m:
        b, c = tuple(map(float, m.groups())), None
    m = re.search(r"kit: camera at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+) ", l)
    if m:
        c = tuple(map(float, m.groups()))
    m = re.search(r"kit: vehicle speed (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+),", l)
    if m and b and c:
        S.append((b, c, math.hypot(float(m[1]), float(m[3]))))
        b = c = None
assert len(S) > 100, len(S)
# The jumps: over each one's span, some sample 0.2 m over the floor, a later
# one on it (0.4 flaked: a sample some 0.15 s apart, a slower lap's lower
# flight, 0.3 at most once)
for name, pts, z0, z1 in jumps:
    xs = [p[0] for p in pts]
    on = [(bx, by - floor(bx, by, bz)) for (bx, by, bz), _, _ in S
          if min(xs) - 15 < bx < max(xs) and z0 < bz < z1]
    up = [i for i, (_, h) in enumerate(on) if h > 0.2]
    assert up and any(abs(h) < 0.05 for _, h in on[up[-1]:]), (name, xs[0], on)
    print("ok: the jump at x %.0f...%.0f: %d samples, %.2f m over the floor at most, landed" %
          (min(xs), max(xs), len(on), max(h for _, h in on)))
# The crossing: on the deck, under it
cross = [(by, v) for (bx, by, bz), _, v in S if abs(bx) < 8 and 4 < bz < 16]
over = [v for y, v in cross if abs(y - 5.055) < 0.06]
under = [v for y, v in cross if abs(y - 0.555) < 0.06]
assert over and under and len(over) + len(under) == len(cross), cross
assert min(over + under) > 8, cross
print("ok: the bridge: %d samples on its deck (y 5.055), %d under it (y 0.555), none between, "
      "at %.1f m/s at least" % (len(over), len(under), min(over + under)))
bad = [(b, c, inside(*c)) for b, c, _ in S if inside(*c)]
assert not bad, bad[:5]
cu = [c for (bx, by, bz), c, _ in S if abs(bx) < 8 and 4 < bz < 16 and by < 1]
print("ok: the camera out of every height's prism over %d samples (under the deck: at y %s)" %
      (len(S), ", ".join("%.2f" % c[1] for c in cu)))
PY
	fail "the heights ($CL)"
for f in lap_1_start lap_2_ramp lap_3_deck loop_before loop_top loop_after lap_4_east lap_5_jump lap_6_landed lap_7_under lap_8_jump2 lap_9_last; do
	[ -f "$t/$f.png" ] || fail "no screenshot $t/$f.png ($t/drive.log)"
done

# 5. The loop on the lap: upside down at its top, the camera turned with it
# and out of its facets; level after it
cat > "$t/loop.py" <<'PY'
import json, math, re, sys
def samples(path, at):
    """Each sample: the body's place, its up (None off a loop), the camera's
    place and up"""
    s = open(path, "rb").read()[at:].decode(errors="replace")
    S, b, u = [], None, None
    for l in s.splitlines():
        m = re.search(r"kit: body at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+),", l)
        if m:
            b, u = tuple(map(float, m.groups())), None
        m = re.search(r"kit: body up (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+)", l)
        if m:
            u = tuple(map(float, m.groups()))
        m = re.search(r"kit: camera at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+) turn "
                      r"(-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+)", l)
        if m and b:
            c = tuple(map(float, m.groups()[:3]))
            w, x, y, z = map(float, m.groups()[3:])
            cu = (2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x))
            S.append((b, u, c, cu))
            b = u = None
    return S
def facets(path):
    """The trial's loop facets and rails: their frame (move.lua's rotation:
    yaw, then pitch, then roll), outline and depth"""
    d = json.load(open(path))
    scene = {e["name"]: e["id"] for e in d["entities"] if e.get("kind") == "scene"}
    gen = [e["id"] for e in d["entities"] if e.get("parent") == scene["trial"] and
           e["components"][0]["type"] == "local/stunt_yard"][0]
    out = []
    for e in d["entities"]:
        if e.get("parent") == gen and e.get("name", "").startswith("the loop"):
            def rot(a, k):
                c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
                return {"y": [[c, 0, s], [0, 1, 0], [-s, 0, c]],
                        "x": [[1, 0, 0], [0, c, -s], [0, s, c]],
                        "z": [[c, -s, 0], [s, c, 0], [0, 0, 1]]}[k]
            def mul(a, b):
                return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
            R = mul(rot(e.get("yaw", 0), "y"), mul(rot(e.get("pitch", 0), "x"), rot(e.get("roll", 0), "z")))
            p = e["components"][0]["params"]
            out.append((e["pos"], R, p["points"], p.get("depth", 1)))
    return out
def in_facet(f, q):
    (px, py, pz), R, pts, dep = f
    r = (q[0] - px, q[1] - py, q[2] - pz)
    lx, ly, lz = (sum(R[i][k] * r[i] for i in range(3)) for k in range(3))
    if abs(lz) > dep / 2:
        return False
    c = False
    for (ax, ay), (bx, by) in zip(pts, pts[1:] + pts[:1]):
        if (ay > ly) != (by > ly) and lx < ax + (bx - ax) * (ly - ay) / (by - ay):
            c = not c
    return c
PY
python3 -I - "$CL" "$mc" "$here/apps/workbench/templates/brimstone_stunts/composition.json" "$t/loop.py" <<'PY' ||
import sys
exec(open(sys.argv[4]).read())
S = samples(sys.argv[1], int(sys.argv[2]))
F = facets(sys.argv[3])
assert len(F) >= 72, len(F)
on = [i for i, (_, u, _, _) in enumerate(S) if u]
assert on, "no sample on the loop"
# (the top: the body's up its lowest; the camera's up turned toward it)
top = min(on, key=lambda i: S[i][1][1])
(b, u, c, cu) = S[top]
assert u[1] < -0.8 and b[1] > 12, ("not upside down at the top", b, u)
lean = sum(a * k for a, k in zip(u, cu))
assert cu[1] < 0.3 and lean > 0.3, ("the camera not turned with the car", u, cu)
bad = [(S[i][2], S[i][0]) for i in range(len(S)) if any(in_facet(f, S[i][2]) for f in F)]
assert not bad, ("the camera inside a facet", bad[:5])
# (after it: on the road again, level, the camera level)
after = [S[i] for i in range(on[-1] + 1, len(S)) if 66 < S[i][0][0] < 95 and S[i][0][2] < 17]
assert after and all(abs(b[1] - 0.555) < 0.06 and not u for b, u, _, _ in after), after[:3]
# (its up the chase's pitch, 14 degrees, off the vertical)
assert after[-1][3][1] > 0.95, ("the camera not level after the loop", after[-1])
print("ok: the loop: %d samples on it, at its top (%.1f m) the car's up %.2f,%.2f,%.2f, the "
      "camera's %.2f,%.2f,%.2f (%.2f along it); the camera in no facet over %d samples; %d "
      "after it level on the road, the camera's up %.3f" % (len(on), b[1], u[0], u[1], u[2],
      cu[0], cu[1], cu[2], lean, len(S), len(after), after[-1][3][1]))
PY
	fail "the loop ($CL)"

# 4. The scenery on the lap; the frames' time; a hammer met
step 10 "kit: looks: " "event kit_looks"
python3 -I - "$CL" "$mc" "$SL" "$t/lap_1_start.png" <<'PY' || fail "the scenery on the lap ($CL)"
import re, sys
from PIL import Image
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
for what in ("stunt_car: effect boost_pad at", "stunt_birds: [0-9]+ birds scatter from the car",
             "stunt_fans: [0-9]+ fans cheer"):
    assert re.search(what, s), what
# (the scene's looks are made, the far ones placed and the cull set, before the lap)
whole = open(sys.argv[1], "rb").read().decode(errors="replace")
for what in ("under parallax layer [0-9]+ drawn far", "kit: looks drawn to 165 m"):
    assert re.search(what, whole), what
# The mountains' colours (the far layer's two ridges): above the horizon, next
# to none in the lower 45% (the road, the walls, the ground in front of them:
# a few of the gravel's and stone's pixels come near the darker ridge's)
im = Image.open(sys.argv[4]).convert("RGB")
w, h = im.size
far = [(0xa5, 0x9b, 0xb4), (0x85, 0x70, 0x78)]
px = im.load()
def near(p):
    return any(sum(abs(a - b) for a, b in zip(p, c)) < 18 for c in far)
up = sum(1 for y in range(0, int(h * 0.55), 2) for x in range(0, w, 2) if near(px[x, y]))
low = sum(1 for y in range(int(h * 0.55), h, 2) for x in range(0, w, 2) if near(px[x, y]))
assert up > w * h / 4 * 0.02 and low < up / 15, (up, low)
looks = re.findall(r"kit: looks: (\d+) frames, .*; frames ([0-9.]+) ms, the worst ([0-9.]+)", s)
f, mean, worst = looks[-1]
assert int(f) > 100 and float(mean) < 250, looks[-1]
srv = open(sys.argv[3], "rb").read().decode(errors="replace")
meter = re.findall(r"meter: .*Kit's tick ([0-9.]+)/([0-9.]+) ms.*?(\d+) bodies, (\d+) drives", srv)
assert meter, "no meter lines"
print("ok: on the lap a boost pad felt, birds scattered, fans cheering, the far mountains "
      "behind the world (%d px of theirs above the horizon, %d below), looks culled at 165 m; "
      "%s frames of %s ms (the worst %s); Kit's tick %.2f ms (mean) at most over %d meter "
      "lines, %s drives" % (up, low, f, mean, worst, max(float(m[0]) for m in meter),
                            len(meter), meter[-1][3]))
PY
# The trial's first hammer: the car put where its head swings low, then
# sampled while it swings by
HAM=$(python3 -I - "$here/apps/workbench/templates/brimstone_stunts/composition.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
scene = {e["name"]: e["id"] for e in d["entities"] if e.get("kind") == "scene"}
h = [e for e in d["entities"] if e.get("name") == "hammer" and e.get("parent") == scene["trial"]][0]
print("%g %g" % (h["pos"][0] * 0.8, h["pos"][2]))  # (the head 3 wide, its inside a metre in)
PY
) || fail "no hammer in the trial"
read -r HX HZ <<< "$HAM"
mh=$(mark "$SL")
cmd 'event kit_edit {"op": "mode", "on": true}' "event kit_edit {\"op\": \"walk_here\", \"pos\": [$HX, 0.555, $HZ]}"
await "$SL" "$mh" 10 "kitboss walks here"
step 10 "kit editor: edit mode off" "frames 3" 'event kit_edit {"op": "mode", "on": false}'
mb=$(mark "$CL")
for i in $(seq 20); do cmd "event kit_body" "delay 200"; done
step 10 "Wrote screenshot $t/hammer.png" "event kit_body" "screenshot $t/hammer.png"
python3 -I - "$CL" "$mb" "$HX" "$HZ" <<'PY' || fail "the hammer met ($CL)"
import math, re, sys
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
hx, hz = float(sys.argv[3]), float(sys.argv[4])
at = [tuple(map(float, m)) for m in re.findall(r"kit: body at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+),", s)]
assert len(at) > 10, at
# (the shove comes in the frames before the first sample: the car, keys up, is
# put there and found near, but over 1.5 m off it, out of the head's reach)
off = [math.hypot(x - hx, z - hz) for x, _, z in at]
assert max(off) < 8 and off[-1] > 1.5, (off, at)
print("ok: a hammer met: the car put under its head's low point, found %.1f m off it "
      "(%.2f,%.2f) over %d samples" % (off[-1], at[-1][0], at[-1][2], len(at)))
PY
# Into the loop too slow: a trial again (a finished one holds the car), the
# car put on the line short of the loop in its countdown, driven at 12 m/s
# at most along it from its GO; up the loop's side, off it, down on the road
mh=$(mark "$SL")
cmd "frames 3" 'click Button "Again"'
await "$SL" "$mh" 10 "kitboss starts a time trial"
mh=$(mark "$SL")
cmd 'event kit_edit {"op": "mode", "on": true}' 'event kit_edit {"op": "walk_here", "pos": [16, 0.555, 10]}'
await "$SL" "$mh" 10 "kitboss walks here"
step 10 "kit editor: edit mode off" "frames 3" 'event kit_edit {"op": "mode", "on": false}'
ms=$(mark "$CL")
TOP=12 python3 -I "$here/util/kit_racer_drive.py" "$CL" "$t/boss.cmd" 12 NEVER > "$t/drive_slow.log" 2>&1
python3 -I - "$CL" "$ms" "$t/loop.py" <<'PY' || fail "too slow into the loop ($CL, $t/drive_slow.log)"
import sys
exec(open(sys.argv[3]).read())
S = samples(sys.argv[1], int(sys.argv[2]))
on = [i for i, (_, u, _, _) in enumerate(S) if u]
assert on, "never on the loop"
high = max(S[i][0][1] for i in on)
low = min(S[i][1][1] for i in on)
fell = [i for i in range(on[0], len(S)) if not S[i][1] and S[i][0][1] > 3]
assert high > 4 and low > -0.95 and fell, ("not off its side", high, low)
# (down: under 1.5 m and still, on the road or the loop's foot)
down = [i for i in range(fell[0], len(S) - 1) if not S[i][1] and S[i][0][1] < 1.5 and
        abs(S[i + 1][0][1] - S[i][0][1]) < 0.05]
assert down, ("not down again", S[fell[0]:fell[0] + 10])
print("ok: into the loop at 12 m/s: up it to %.1f m (its up %.2f at the lowest), off it at %.1f m, "
      "down at %.2f,%.2f,%.2f" % (high, low, S[fell[0]][0][1], *S[down[0]][0]))
PY
cmd "quit"
echo "PASS: Brimstone Stunts from its template: its types, a time trial's lap in the chase camera behind the car, following its heading, over two jumps and the bridge and under it, round the loop upside down, its scenery on the way; a hammer met; too slow off the loop; screenshots $t/lobby.png $t/lap_*.png $t/loop_*.png $t/trial.png $t/hammer.png"
# vim: set noet ts=4 sw=4:
