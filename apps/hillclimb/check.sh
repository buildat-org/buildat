#!/bin/bash
# tier: full
# cost: ~80 s (2026-10-16)
# covers: apps/hillclimb/** extensions/physical_sky/init.lua extensions/sky_render/**
# hillclimb ([HILLCLIMB], doc/plan/hillclimb_plan.md's Check), no
# pixels. The generator's own self test (main/hill.h: the same seed the
# same hill, the slope's angle, the pads flat and long enough, the track
# 10 m with no banks, sand with stones, the ground outside flush with the
# edge), the client Lua parsing, and drives with
# no client (BUILDAT_HILLCLIMB_DRIVE): the car settling on its springs,
# lower with a payload, each gear's top speed, the brake, a slope
# climbed and one past the sand's grip stalled; then 2 t in fourth at 25,
# 31 and 37 degrees climbing or spinning, never stalled ([HC_POWER]); the time trial's times
# kept per hill and payload in order, and a hill picked again; the
# ground (main/ground.h's own self test too): a rut dug by wheels spun in
# place, stones loose that roll down and rest. [HC_OPEN_EDGES]: a car
# steered off the side up the slope put back to a pose 2 to 3 s old, out
# of the ground, and driving on; off the top's end the same; one parked a
# minute never put back, nor the flat's; a stone thrown off the edge
# removed; [HC_PUT_BACK_FURTHER] one steered off again and again put
# back 2 s further each time, from 1 again past a 10 m mark.
# [HC_PAUSE_MENU] and [HC_TOUCH]: driven clients at the end.
# [HC_CIRCUIT] hill.h's self test draws the loop at 0, 50 and 100%
# switchbacks for lanes of 4, 6 and 8 m into the run's directory
# (circuit_<lane>_<switchbacks>.pgm, from above); a flat circuit driven
# round by P: its turns in order, a lap, a 60 s round ranking the two
# cars by laps under the circuit's key; one cut into the middle put back,
# no lap. The drives before it on the straight hill (_MODE=straight: the
# circuit is the default).
#   apps/hillclimb/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp hillclimb; t=$CHECK_TMP
app="$here/apps/hillclimb"

g++ -std=c++11 -O1 -DHILL_TEST -x c++ "$app/main/hill.h" -o "$t/hill_test" \
	2> "$t/hill_build.log" || fail "hill.h self test did not build: $(head -3 "$t/hill_build.log")"
"$t/hill_test" "$t" || fail "hill.h self test"
g++ -std=c++11 -O1 -DGROUND_TEST -x c++ "$app/main/ground.h" -o "$t/ground_test" \
	2> "$t/ground_build.log" || fail "ground.h self test did not build: $(head -3 "$t/ground_build.log")"
"$t/ground_test" || fail "ground.h self test"

for f in "$app"/main/client_lua/*.lua "$app"/launcher/*.lua; do
	luajit -b "$f" /dev/null || fail "$f does not parse"
done
# [HC_TOUCH] the stick's mapping (touch.lua's self test, run as it
# loads) and the steering's (car.h's)
# (-e's chunk first, then the file as the script; a dofile(arg[1]) read
# stdin, arg[1] being nil)
luajit -e 'buildat = {Logger = function() end}; require = function() end' \
	"$app/main/client_lua/touch.lua" || fail "touch.lua's self test"
g++ -std=c++11 -O1 -DCAR_TEST -x c++ "$app/main/car.h" -o "$t/car_test" \
	2> "$t/car_build.log" || fail "car.h self test did not build: $(head -3 "$t/car_build.log")"
"$t/car_test" || fail "car.h self test"

cd "$here/Build"
# Three drives at once, each its own server with the hill and the car and
# no client (BUILDAT_HILLCLIMB_DRIVE, main.cpp); each ends itself
# Each drive a port of its own off one base: random ports for nine
# servers at once met ("Failed to bind socket")
port_base=$((29700 + RANDOM % 280))
declare -A PORT=([warm]=0 [flat]=1 [climb]=2 [stall]=3 [rock]=4 [beside]=5
	[over25]=6 [over31]=7 [over37]=8 [counts]=9 [cars8]=10 [side]=11
	[parked]=12 [varied]=13 [circuit]=14 [cut]=15 [scores0]=16 [scores]=17
	[series]=18 [fence]=19 [fixed]=20 [back]=21 [firm]=22 [soft]=23 [kick]=24 [keep]=25)
# [HC_SOFT_DEFAULTS] The car's drives on the firm soil they were tuned on
# (80 kPa, dig 2, 100%, 35%; a ranking key with no knob parts), not the
# game's soft default
firm_soil="BUILDAT_HILLCLIMB_BEARING=80 BUILDAT_HILLCLIMB_DIG=2
	BUILDAT_HILLCLIMB_POWER=100 BUILDAT_HILLCLIMB_STONES=35"
# The game's defaults: the variables empty
default_soil="BUILDAT_HILLCLIMB_BEARING= BUILDAT_HILLCLIMB_DIG=
	BUILDAT_HILLCLIMB_POWER= BUILDAT_HILLCLIMB_STONES="
drive()
{
	local name=$1; shift
	# The car's own drives on a hill with no pits or rocks (the rock's
	# below sets them on again), its steepness even ([HC_STEEP_NOISE]:
	# the varied one's below sets its variance)
	# The modules compiled once (warm, below), each drive a copy
	[ -d "$t/warm/c" ] && [ "$name" != warm ] && mkdir -p "$t/$name" &&
		cp -a "$t/warm/c" "$t/$name/c"
	# shellcheck disable=SC2086 # the assignments, split
	env BUILDAT_HILLCLIMB_MODE=straight BUILDAT_HILLCLIMB_FEATURES=0 \
		BUILDAT_HILLCLIMB_STEEP_VAR=0 $firm_soil "$@" timeout 150 bin/buildat_server -m "$app" -D "$t/$name/u" \
		-C "$t/$name/c" -P $((port_base + PORT[$name])) -l 3 > "$t/$name.log" 2>&1
}
drive warm BUILDAT_HILLCLIMB_DRIVE="0:Q" || fail "the first server ($t/warm.log)"
# On the flat past the hill's start, facing away: each gear's top speed,
# then the brake
drive flat BUILDAT_HILLCLIMB_START="5 -30 180" \
	BUILDAT_HILLCLIMB_DRIVE="0:4 3:W1 9:W2 15:W3 21:W4 27:S4 31:Q" &
# The time trial: 22 degrees climbed in second, the gear a car starts in
# ([HC_DEFAULTS]: no gear key before it), kept on the top by being put
# back as it goes off the end ([HC_OPEN_EDGES]); again in fourth,
# faster; then a hill of 15 degrees and 30 m
drive climb BUILDAT_HILLCLIMB_STEEP=22 BUILDAT_HILLCLIMB_DRIVE="0:S 2:W 31:S2 \
33:B 34:W4 50:S4 52:4H15/30 54:W4 66:Q" &
# 40 degrees with 2 t aboard in first: past the sand's grip, it stalls,
# its wheels spinning in place dig in and loosen stones that roll
drive stall BUILDAT_HILLCLIMB_STEEP=40 BUILDAT_HILLCLIMB_PAYLOAD=2000 \
	BUILDAT_HILLCLIMB_DRIVE="0:1 1:W1 2:KW1 26:S1 34:Q" &
# [HC_PITS_ROCKS] Seed 6 at 29 degrees has a rock at x 5.26 z 9.74 m,
# 0.74 m in radius, and nothing else below it near these lines
# ("hill_test 6 29 50"): from the bottom pad in second with the left
# wheels on its line, and on a line 3 m to its left
drive rock BUILDAT_HILLCLIMB_FEATURES=1 BUILDAT_HILLCLIMB_SEED=6 BUILDAT_HILLCLIMB_STEEP=29 \
	BUILDAT_HILLCLIMB_START="6.21 3 0" BUILDAT_HILLCLIMB_DRIVE="0:S2 2:W2 14:Q" &
drive beside BUILDAT_HILLCLIMB_FEATURES=1 BUILDAT_HILLCLIMB_SEED=6 BUILDAT_HILLCLIMB_STEEP=29 \
	BUILDAT_HILLCLIMB_START="2.1 3 0" BUILDAT_HILLCLIMB_DRIVE="0:S2 2:W2 14:Q" &
# [HC_OPEN_EDGES] Up the slope in second, steered right from 7 s: off the
# side, put back; a minute parked on the bottom pad, a stone thrown off
# the left edge at 1 s and one dropped on the pad at 2 s
drive side BUILDAT_HILLCLIMB_DRIVE="0:S2 2:W2 7:W2D 16:Q" &
# [HC_PUT_BACK_FURTHER] The same, steered right three times: off the
# side, then up past the 10 m mark and off again, then off once more
drive series BUILDAT_HILLCLIMB_DRIVE="0:S2 2:W2 7:W2D 9:W2 14:W2D 16:W2 22:W2D 24:W2 32:Q" &
drive parked BUILDAT_HILLCLIMB_DRIVE="0:S 1:SJ 2:SG 60:Q" &
# [HC_SOFT_GROUND] Up a hill of 15 degrees and 20 m in second, the knobs at
# their defaults and at the softest set; the finish names the key
soft="BUILDAT_HILLCLIMB_BEARING=20 BUILDAT_HILLCLIMB_DIG=8
	BUILDAT_HILLCLIMB_POWER=200 BUILDAT_HILLCLIMB_GRIP=40 BUILDAT_HILLCLIMB_STONES=15"
# [HC_STONE_KICK] At the default soil: a stone dropped ahead of the left
# wheels rests as its 9 voxels, then the car driven over it kicks it
# loose again, is held back by it as it pushes it, and finishes
# shellcheck disable=SC2086
# [HC_SAND_VOLUME] V before and after: the sand's volume kept, no lone
# full voxel on the pad behind the start
drive kick $default_soil BUILDAT_HILLCLIMB_STEEP=15 BUILDAT_HILLCLIMB_LENGTH=20 \
	BUILDAT_HILLCLIMB_DRIVE="0:SV 1:SE 7:W2 21:V 22:Q" &
drive firm BUILDAT_HILLCLIMB_STEEP=15 BUILDAT_HILLCLIMB_LENGTH=20 \
	BUILDAT_HILLCLIMB_DRIVE="0:S 2:W2 17:Q" &
# shellcheck disable=SC2086
drive soft $soft BUILDAT_HILLCLIMB_STEEP=15 BUILDAT_HILLCLIMB_LENGTH=20 \
	BUILDAT_HILLCLIMB_DRIVE="0:S 2:W2 17:Q" &
# [HC_CIRCUIT] A flat circuit 24 m wide and 30 long, no switchbacks: two
# cars steered round by P (the second slower), a 60 s round; and one
# turned left off the start into the middle
circuit="BUILDAT_HILLCLIMB_MODE=circuit BUILDAT_HILLCLIMB_STEEP=5
	BUILDAT_HILLCLIMB_WIDTH=24 BUILDAT_HILLCLIMB_LENGTH=30
	BUILDAT_HILLCLIMB_SWITCHBACKS=0 BUILDAT_HILLCLIMB_INTERVAL=60"
# shellcheck disable=SC2086 # the assignments, split
drive circuit $circuit BUILDAT_HILLCLIMB_CARS=2 BUILDAT_HILLCLIMB_DRIVE="0:P 64:Q" &
# shellcheck disable=SC2086
drive cut $circuit BUILDAT_HILLCLIMB_DRIVE="0:W2 2:W2A 5:W2 10:S 14:Q" &
# [HC_RESET_KEEP_GROUND] On the default soil, a lap by P, then Backspace
# (Z) mid-lap: the car at the start, the lap and the ruts kept
# shellcheck disable=SC2086
drive keep $circuit $default_soil BUILDAT_HILLCLIMB_INTERVAL=120 \
	BUILDAT_HILLCLIMB_DRIVE="0:P 52:PZ 53:P 56:Q" &
# [HC_BACKTRACK] Past turn 1, then backed round it into the lane before
# (O: where it is), then driven on to a lap; a round long enough for it
# shellcheck disable=SC2086
drive back $circuit BUILDAT_HILLCLIMB_INTERVAL=120 \
	BUILDAT_HILLCLIMB_DRIVE="0:P 7:S 8:SR 9:RWA 13:RW 17:RWO 19:S 20:P 72:Q" &
# [HC_LAP_TURNS] A 40 m circuit of switchbacks, the car started in turn
# 1's lane past it and driven up. [HC_MISSED_TURN_MARK] Turn 1 marked at
# once, the car not put back until it is past turn 2
drive fence BUILDAT_HILLCLIMB_MODE=circuit BUILDAT_HILLCLIMB_STEEP=5 \
	BUILDAT_HILLCLIMB_WIDTH=40 BUILDAT_HILLCLIMB_LENGTH=30 \
	BUILDAT_HILLCLIMB_SWITCHBACKS=100 BUILDAT_HILLCLIMB_LANE=6 \
	BUILDAT_HILLCLIMB_START="36.9 7 0" BUILDAT_HILLCLIMB_DRIVE="0:W2 8:Q" &
# ... and from there back down into turn 1: the mark cleared
drive fixed BUILDAT_HILLCLIMB_MODE=circuit BUILDAT_HILLCLIMB_STEEP=5 \
	BUILDAT_HILLCLIMB_WIDTH=40 BUILDAT_HILLCLIMB_LENGTH=30 \
	BUILDAT_HILLCLIMB_SWITCHBACKS=100 BUILDAT_HILLCLIMB_LANE=6 \
	BUILDAT_HILLCLIMB_START="36.9 7 180" BUILDAT_HILLCLIMB_DRIVE="0:W1 5:Q" &
wait
c="$t/circuit.log"
turns=$(grep -a "hillclimb: drive passed turn" "$c" | head -4 | sed 's/.*turn \([0-9]*\) of.*/\1/' | tr '\n' ' ')
[ "$turns" = "1 2 3 4 " ] && grep -aq "hillclimb: drive's lap 1 at" "$c" &&
	! grep -aq "crossed a fence" "$c" ||
	fail "the circuit: turns '$turns' in order, then a lap, no fence crossed ($c)"
res=$(grep -aA2 "hillclimb: round over:" "$c" | tail -2 | tr '\n' '|')
grep -aq "finish .* on v6/circuit/steep5/var0/length30/width24/lane7/switch0/round60/sand/payload0/, rank 0" "$c" &&
	echo "$res" | grep -Eq '^1 laps [0-9.]+ drive\|0 laps [0-9.]+ drive1\|$' ||
	fail "the circuit's round: '$res', or its key ($c)"
grep -aq "hillclimb: drive's car put back" "$t/cut.log" && ! grep -aq "'s lap" "$t/cut.log" ||
	fail "the cut into the middle: not put back, or a lap ($t/cut.log)"
# The first three of the three kinds, in this order
f=$(grep -ao "hillclimb: drive missed turn 1, past it\|hillclimb: drive past the turn after the missed 1\|hillclimb: drive's car put back" \
	"$t/fence.log" | head -3 | tr '\n' '|')
[ "$f" = "hillclimb: drive missed turn 1, past it|hillclimb: drive past the turn after the missed 1|hillclimb: drive's car put back|" ] ||
	fail "turn 1 missed: '$f', not marked, then put back past turn 2 ($t/fence.log)"
grep -aq "hillclimb: drive missed turn 1, past it" "$t/fixed.log" &&
	grep -aq "hillclimb: drive drove the missed turn 1 at" "$t/fixed.log" &&
	! grep -aq "put back" "$t/fixed.log" ||
	fail "turn 1 missed and driven back to: not cleared ($t/fixed.log)"
changed() { grep -ao 'ground=[0-9/]*' "$1" | tail -1 | tr '=/' '  ' |
	awk '{print $2 + $3 + $4}'; }
firm=$(changed "$t/firm.log") soft_n=$(changed "$t/soft.log")
grep -aq "voxels; sand 20 kPa, dig 8, power 200%, grip 0.40, stones 15%" "$t/soft.log" &&
	grep -aq "finish .* on v6/straight/steep15/var0/length20/sand/bearing20/dig8/power200/grip40/stones15/payload0/" "$t/soft.log" &&
	grep -aq "finish .* on v6/straight/steep15/var0/length20/sand/payload0/" "$t/firm.log" &&
	[ "${soft_n:-0}" -gt $(( ${firm:-0} + 100 )) ] ||
	fail "the softest set: ${soft_n:-?} voxels changed against ${firm:-?}, or its hill line or key ($t/soft.log)"
python3 -I - "$t/kick.log" <<'PY' || fail "the stone kicked ($t/kick.log)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
rest = re.search(r"rock 1 rests at (\S+),\S+,(\S+) m, \S+ m from where it came loose, 9 voxels", log)
again = [m for m in re.finditer(r"rock (\d+) loose at (\S+),\S+,(\S+) m, 9 voxels", log)
    if m.group(1) != "1" and rest and abs(float(m.group(2)) - float(rest.group(1))) < 0.2 and
    abs(float(m.group(3)) - float(rest.group(2))) < 0.2]
n = again[0].group(1) if again else "?"
kicked = re.search(r"rock %s kicked by tyre (\d), (\d+) kg, a push of (\d+) N" % n, log)
pushed = re.search(r"rock %s pushed by drive's tyre \d, \d+ kg, (\d+) N back" % n, log)
fin = re.search(r"hillclimb: finish (\S+) s on", log)
print("  a rested stone: %s; kicked loose again as rock %s: %s; held the car back by %s N; finished in %s s" % (
    "9 voxels" if rest else "none", n, kicked.group(0) if kicked else "no",
    pushed.group(1) if pushed else "no", fin.group(1) if fin else "never"))
vol = re.findall(r"hillclimb: sand (\d+) eighths; behind the start (\d+) columns", log)
print("  the sand's volume at the start and the end: %s" % vol)
sys.exit(0 if rest and kicked and pushed and int(pushed.group(1)) > 0 and fin and
    len(vol) == 2 and vol[0][0] == vol[1][0] and vol[1][1] == "0" else 1)
PY
python3 -I - "$t/keep.log" <<'PY' || fail "Backspace mid-lap ($t/keep.log)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
start = re.search(r"car t=0\.0 pos=(\S+),\S+,(\S+) ", log)
back = re.search(r"drive back to the start at (\S+),(\S+) m, the ground kept: (\d+) laps, (\d+) voxels changed", log)
ok = (start and back and abs(float(back.group(1)) - float(start.group(1))) < 0.5 and
    abs(float(back.group(2)) - float(start.group(2))) < 0.5 and back.group(3) == "1" and
    int(back.group(4)) > 0 and "the hill as it was made" not in log)
print("  Backspace mid-lap: %s" % (back.group(0) if back else "not logged"))
sys.exit(0 if ok else 1)
PY
b="$t/back.log"
grep -aq "hillclimb: drive at .*, turn 2 next, lanes 0\( 4\)\?$" "$b" &&
	! grep -aq "missed turn\|put back" "$b" && grep -aq "hillclimb: drive's lap 1 at" "$b" ||
	fail "backed past turn 1 into lane 0: not there, marked or put back, or no lap ($b)"
echo "  the circuit: turns $turns then a lap; the round: $res; a cut put back; a missed turn marked, put back past the next, cleared when driven; backing past a turn and on to a lap; a climb changed $firm voxels on the firm soil, $soft_n on the softest"
# [HC_POWER] 2 t aboard in fourth at 25, 31 and 37 degrees, from the
# bottom pad: each climbs or spins its wheels, none stalls
for a in 25 31 37; do
	drive over$a BUILDAT_HILLCLIMB_STEEP=$a BUILDAT_HILLCLIMB_PAYLOAD=2000 \
		BUILDAT_HILLCLIMB_DRIVE="0:4 1:W4 22:Q" &
done
# [HC_MULTIPLAYER] The runs ended before a run, in its entry: on a hill of
# 15 degrees and 20 m, a run reset (unfinished), one finished, one more
drive counts BUILDAT_HILLCLIMB_STEEP=15 BUILDAT_HILLCLIMB_LENGTH=20 \
	BUILDAT_HILLCLIMB_DRIVE="0:S 1:W 3:B 4:W 25:B 26:W 50:Q" &
# [HC_STEEP_NOISE] A varied hill, 18 degrees by 4, climbed in second.
# Not the default 27: a hard climb by its design (user, 2026-10-20), and
# a run of fixed keys missed its finish there now and then
drive varied BUILDAT_HILLCLIMB_STEEP=18 BUILDAT_HILLCLIMB_STEEP_VAR=4 \
	BUILDAT_HILLCLIMB_DRIVE="0:S 2:W 70:Q" &
# 8 cars on one hill, the same keys: the step's cost
drive cars8 BUILDAT_HILLCLIMB_CARS=8 BUILDAT_HILLCLIMB_DRIVE="0:S 1:W 12:Q" &
# [HC_SCORES] A save with eleven v4 times (seed 7) of the hill of 15
# degrees and 20 m; on it a run finished on seed 1 and the round of 30 s
# over; then L, the High scores page's answers
(
	drive scores0 BUILDAT_HILLCLIMB_DRIVE="0:Q"
	mkdir -p "$t/scores"; cp -a "$t/scores0/u" "$t/scores/u"
	# As a save from before: no mark of the times read
	{ echo "DELETE FROM store WHERE store = 'settings' AND key = 'scores_v6';"
	for i in $(seq 30 40); do
		echo "INSERT INTO store VALUES('times', 'v4/seed7/steep15/length20/sand/payload0/0000${i}000/$i', 'old$i	2026-10-01	0	0');"
	done; } | sqlite3 "$t/scores/u/apps/hillclimb/saves/ranking/save.sqlite"
	drive scores BUILDAT_HILLCLIMB_STEEP=15 BUILDAT_HILLCLIMB_LENGTH=20 \
		BUILDAT_HILLCLIMB_INTERVAL=30 BUILDAT_HILLCLIMB_DRIVE="0:S 1:W 35:S 44:L 45:Q"
) &
wait
python3 -I - "$t/scores.log" <<'PY' || fail "the high scores ($t/scores.log)"
import json, re, sys
log = open(sys.argv[1], errors="replace").read()
def after(what):
    m = re.search(re.escape(what) + r" (\{.*\})", log)
    return json.loads(m.group(1)) if m else {}
sets, one = after("hillclimb: scores sets").get("sets", []), after("hillclimb: scores set").get("set", {})
new = "v6/straight/steep15/var0/length20/sand/payload0/"
by = {s["key"]: s for s in sets}
ok = ("11 times with a seed read into v6" in log and
    re.search(r"round over:", log) and
    re.search(r"round over:[\s\S]*the hill as it was made, seed 1", log) and
    not re.search(r"the hill, seed (?!1,)", log) and
    sets and sets[0]["key"] == new and sets[0]["current"] and by[new]["count"] == 12 and
    by.get("v4/seed7/steep15/length20/sand/payload0/", {}).get("count") == 11 and
    not by["v4/seed7/steep15/length20/sand/payload0/"]["drivable"] and
    one.get("key") == new and len(one.get("entries", [])) == 12 and
    one["entries"][0]["seed"] == 1 and one["entries"][-1]["seed"] == 7)
print("  the high scores: %s; the set %s, %d entries, seeds %s" % (
    ["%s (%d)" % (s["name"], s["count"]) for s in sets], one.get("key"),
    len(one.get("entries", [])), sorted({e["seed"] for e in one.get("entries", [])})))
sys.exit(0 if ok else 1)
PY
grep -a "hillclimb: the hill" "$t/flat.log" | sed 's/.*hillclimb: /  /'
# The default hill ([HC_DEFAULTS])
grep -aq "hillclimb: the hill, seed 1, 27 degrees +-0, 50 m long" "$t/flat.log" ||
	fail "no hill made, or not at 27 degrees by default ($t/flat.log)"
python3 -I - "$t" <<'PY' || fail "the car (logs in $t)"
import re, sys
d = sys.argv[1]
def lines(name):
    out = []
    for l in open("%s/%s.log" % (d, name), errors="replace"):
        m = re.search(r"hillclimb: car t=(\S+) pos=(\S+),(\S+),(\S+) v=(\S+) "
                r"shaft=(\S+) springs=(\S+),(\S+),(\S+),(\S+) slip=(\d+)", l)
        if m:
            g = m.groups()
            out.append(dict(t=float(g[0]), x=float(g[1]), y=float(g[2]), z=float(g[3]),
                v=float(g[4]), shaft=float(g[5]),
                springs=[float(x) for x in g[6:10]], slip=g[10]))
    if not out:
        print("%s: no car lines" % name); sys.exit(1)
    return out
def at(ls, t):
    return min(ls, key=lambda l: abs(l["t"] - t))
bad = []
def want(ok, what):
    print("  %s %s" % ("ok  " if ok else "FAIL", what))
    if not ok: bad.append(what)
flat, climb, stall = lines("flat"), lines("climb"), lines("stall")
# [HC_POWER] Overloaded in fourth: never the shaft stopped with the
# pedal down (from 3 s, the pedal ramped up) while the car stands; and
# empty in first on the flat, no wheel spins at the start
# simplified: on the way up, to the highest point; slid back down, a car
# stood in its own dug hole at the bottom (the ground's flushes follow
# the ticks, so where it digs varies run to run)
for a in (25, 31, 37):
    over = [l for l in lines("over%d" % a) if 3 <= l["t"] <= 21]
    over = over[:max(range(len(over)), key=lambda i: over[i]["z"]) + 1]
    stood = [l for l in over if abs(l["shaft"]) < 0.02 and l["v"] < 0.05]
    top = max(l["z"] for l in over)
    spun = sum(1 for l in over if "1" in l["slip"])
    want(not stood, "2 t in 4th at %d degrees climbs or spins: up to z %.1f, "
        "%d of %d lines slipping, %d stalled" % (a, top, spun, len(over), len(stood)))
clog = open("%s/counts.log" % d, errors="replace").read()
counts = re.findall(r"hillclimb: drive finished in \S+ s after (\d+) runs \((\d+) finished\)", clog)
want(counts == [("1", "0"), ("2", "1")], "the runs before each finish: %s "
    "(1 reset, then after 1 and 1)" % counts)
c8 = lines("cars8")
c8us = [int(m) for m in re.findall(r"tick_us=(\d+) .*cars=8",
    open("%s/cars8.log" % d, errors="replace").read())]
want(len(c8us) > 3, "8 cars stepped: the physics per 30 Hz tick, mean %d us, "
    "worst %d us" % (sum(c8us) / max(1, len(c8us)), max(c8us or [0])))
start = [l for l in flat if 3 <= l["t"] <= 6]
want(all(l["slip"] == "0000" for l in start),
    "empty in 1st on the flat, no wheel spins at the start: %s" % sorted(set(l["slip"] for l in start)))
# [HC_PITS_ROCKS] The rock at z 9.7 stops the car or turns it aside;
# beside it the car goes on straight past it
# (the line beside is clear only so far: further up it meets a pit)
rock, beside = lines("rock"), lines("beside")
r_top = max(l["z"] for l in rock)
b_top = max(l["z"] for l in beside)
r_dx = max(abs(l["x"] - rock[0]["x"]) for l in rock)
# On the way up only: past the pit it slides back, turned ([HC_POWER]'s
# car climbs further before it)
up = beside[:max(range(len(beside)), key=lambda i: beside[i]["z"]) + 1]
b_dx = max(abs(l["x"] - beside[0]["x"]) for l in up if l["z"] <= 13)
print("  into the rock: up to z %.1f, x off by %.2f; beside it: up to z %.1f, "
        "x off by %.2f by z 13" % (r_top, r_dx, b_top, b_dx))
want(r_top < 11 or r_dx > 0.5, "a rock stops the car or turns it aside")
want(b_top > 13 and b_dx < 0.5, "beside the rock the car goes on past it")
# Settled on its springs, still: the sag is the weight over the spring
# (2000 kg / 4 at 60 kN/m is 82 mm), and a second later the same
s1, s2 = at(flat, 1.5)["springs"], at(flat, 2.5)["springs"]
want(all(abs(x - 0.0818) < 0.004 for x in s2), "empty, each spring 82 mm down: %s" % s2)
want(all(abs(a - b) < 0.002 for a, b in zip(s1, s2)), "settled without oscillating: %s then %s" % (s1, s2))
heavy = at(stall, 1.5)["springs"]
want(all(h > x + 0.06 for h, x in zip(heavy, s2)), "2 t aboard sits it lower: %s" % heavy)
for gear, t, top in ((1, 8.5, 0.5), (2, 14.5, 0.9), (3, 20.5, 1.4), (4, 26.5, 2.0)):
    s = at(flat, t)["shaft"]
    want(abs(s - top) < 0.03 * top, "gear %d at %.1f rev/s: %.3f" % (gear, top, s))
end = at(flat, 30.5)
want(end["v"] < 0.05 and end["shaft"] == 0, "braked to a stop from 5 m/s: v %.2f" % end["v"])
top = max(l["z"] for l in climb if l["t"] < 31)
want(top > 56, "22 degrees climbed to the top pad (z 56 m): %.1f" % top)
log = open("%s/climb.log" % d, errors="replace").read()
# [HC_OPEN_EDGES] Off the top's end (the area 62 m long), put back onto it
ends = [float(m) for m in re.findall(r"drive's car put back \(\d+ in a row\), "
    r"the pose \S+ s before the first, off the track at \S+,(\S+) m", log)]
# (the first: later the 30 m hill's end is nearer)
want(at(climb, 30.5)["y"] > 20 and ends and ends[0] > 60,
    "kept on the top, put back off its end: y %.1f m, off at z %s" % (
    at(climb, 30.5)["y"], ends[:3]))
side = open("%s/side.log" % d, errors="replace").read()
back = re.findall(r"drive's car put back \(\d+ in a row\), the pose (\S+) s "
    r"before the first, off the track at (\S+),(\S+) m, to (\S+),(\S+),(\S+) m, lifted (\d+) voxels", side)
sl = lines("side")
if back:
    age, ox, oz, tx, ty, tz, lifted = [float(x) for x in back[0]]
    after = [l for l in sl if l["t"] > 0]
    moved = max(abs(l["x"] - tx) + abs(l["z"] - tz) for l in sl[-3:])
    want(2 <= age <= 3 and ox > 8 and 0 < tx < 10 and moved > 1,
        "off the side at x %.2f, z %.1f m: put back to a pose %.1f s old at "
        "x %.2f, z %.1f, lifted %d voxels, and driven on %.1f m" % (
        ox, oz, age, tx, tz, lifted, moved))
else:
    want(False, "off the side: never put back")
# [HC_PUT_BACK_FURTHER] Put back k in a row: the pose 2k to 2k + 1 s
# before the first, or with none that old the oldest; a 10 m mark passed
# between starts the count again (1, the mark, 1, 2)
ser = re.findall(r"drive passed \d+ m|drive's car put back \((\d+) in a "
    r"row\), the pose (\S+) s before", open("%s/series.log" % d,
    errors="replace").read())
backs = [(int(k), float(a)) for k, a in ser if k]
oldest = max([a for k, a in backs] or [0])
# A pose a second apart, but none kept while a tyre is over the edge: the
# k-th one up to 2 s older than 2k (7.6 s for the third once)
want(len(backs) >= 3 and max(k for k, a in backs) >= 2 and all(2 * k <= a <= 2 * k + 2.05 or
    (a == oldest and a < 2 * k) for k, a in backs),
    "put back in a row, 2 s further each, then the oldest: %s" % ser)
want(all(int(k) == (int(p[0]) + 1 if p[0] else 1) for p, (k, a) in zip(
    [("", "")] + ser, ser) if k) and any(not k for k, a in ser[1:-1]),
    "the count from 1 after a mark: %s" % ser)
want("put back" not in open("%s/parked.log" % d, errors="replace").read() and
    "put back" not in open("%s/flat.log" % d, errors="replace").read(),
    "a car parked a minute, and the flat's off the area's end, never put back")
want(re.search(r"rock 1 left the area at -?\S+,\S+ m, removed",
    open("%s/parked.log" % d, errors="replace").read()) is not None,
    "a stone thrown off the edge removed")
fins = re.findall(r"hillclimb: finish (\S+) s on (\S+), rank (\S+); the ranking:(.*)", log)
for f in fins:
    print("    finish %s s on %s rank %s; ranking%s" % f)
want(len(fins) == 3, "three runs timed: %d" % len(fins))
if len(fins) == 3:
    k22 = "v6/straight/steep22/var0/length50/sand/payload0/"
    t1, t2 = float(fins[0][0]), float(fins[1][0])
    want(fins[0][1] == k22 and fins[1][1] == k22 and 20 < t1 < 40 and t2 < t1,
        "second gear's time, then fourth's faster, under the hill's key")
    want(fins[1][2] == "0" and fins[1][3].split() == [fins[1][0], fins[0][0]],
        "the second run first in the ranking, the first beside it")
    want(fins[2][1] == "v6/straight/steep15/var0/length30/sand/payload0/" and
        fins[2][3].split() == [fins[2][0]], "the other hill's run under its own key")
want("hillclimb: the hill, seed 1, 15 degrees +-0, 30 m long" in log, "the hill made again from the pick")
vfin = re.findall(r"hillclimb: finish (\S+) s on (\S+),", open("%s/varied.log" % d, errors="replace").read())
want(vfin and vfin[0][1] == "v6/straight/steep18/var4/length50/sand/payload0/",
    "18 degrees varied by 4 climbed in second: %s" % (vfin[:1] or "no finish"))
# Its wheels slip at times: on loose sand at 40 degrees they catch now and
# then, and a run stalled with them gripping for most of 22-25 s
spin = [l for l in stall if 10 <= l["t"] <= 25]
want(max(l["z"] for l in stall) < 12 and any("1" in l["slip"] for l in spin),
    "40 degrees with 2 t stalls, its wheels slipping: z %.1f, %d of %d s slipping" % (
    max(l["z"] for l in stall), sum("1" in l["slip"] for l in spin), len(spin)))
# The ground: the stall's spinning wheels dig a rut and throw the sand;
# a stone comes loose, rolls down and rests
slog = open("%s/stall.log" % d, errors="replace").read()
g = [int(x) for x in re.findall(r"ground=(\d+)/", slog)]
ruts = [int(x) for x in re.findall(r"rut=(\d+)", slog)]
# On 40 degrees, past sand's angle of repose, a pit refills from above as
# it is dug: a voxel deep at least (ground.h's self test digs two on the
# flat)
want(g and g[-1] >= 30 * 8 and max(ruts) >= 1,
    "spun in place, the wheels dug a rut: %d eighths dug, %d deep" % (
    g[-1] if g else 0, max(ruts) if ruts else 0))
loose = {m[0]: [float(v) for v in m[1:4]] for m in re.findall(
    r"rock (\d+) loose at (\S+),(\S+),(\S+) m", slog)}
rests = {m[0]: [float(v) for v in m[1:4]] + [int(m[4])] for m in re.findall(
    r"rock (\d+) rests at (\S+),(\S+),(\S+) m, \S+ m from where it came "
    r"loose, (\d+) voxels", slog)}
say = ["%s: y %.2f -> %.2f, %d voxels" % (k, loose[k][1], rests[k][1],
    rests[k][3]) for k in sorted(rests) if k in loose]
# Rock 1 is the one K dropped on the slope's lower third: down the
# slope, resting lower or gone off the bottom's end (its way is chaotic:
# dropped at 10 s rather than 2 it went off the side, before
# [HC_CIRCUIT] too); a stone at rest made voxels again
left = {m.group(1): (float(m.group(2)), float(m.group(3))) for m in re.finditer(
    r"rock (\d+) left the area at (\S+),(\S+) m", slog)}
want(("1" in rests and rests["1"][1] < loose["1"][1] - 1) or
    ("1" in left and left["1"][1] < 0),
    "the stone dropped on the slope rolled down: %s; left %s" % (say, left))
# The one G dropped on the parked drive's flat bottom pad, which cannot
# roll off it: the stall's own came to rest only now and then, most off
# the 10 m hill's sides
prest = re.search(r"rock 2 rests at \S+ m, \S+ m from where it came loose, (\d+) voxels",
    open("%s/parked.log" % d, errors="replace").read())
want(prest is not None and int(prest.group(1)) > 0,
    "a stone came to rest as voxels: %s" % (prest.group(0) if prest else "none"))
want(len(loose) >= 2, "the spinning tyres loosened stones: %d" % (len(loose) - 1))
us = [int(m) for m in re.findall(r"tick_us=(\d+)",
    open("%s/climb.log" % d, errors="replace").read())]
print("  the physics per 30 Hz tick on the climb: mean %d us, worst %d us" % (
    sum(us) / len(us), max(us)))
commits = [int(m) for m in re.findall(r"commits=(\d+)", slog)]
want(max(commits) <= 6, "the ground's commits (each remeshes what it touched) "
    "at most five a second: worst %d, %d in all" % (max(commits), sum(commits)))
sys.exit(1 if bad else 0)
PY
# [HC_MULTIPLAYER] Two clients in a local game (-u launcher=1), the rounds
# at 20 s (BUILDAT_HILLCLIMB_INTERVAL): each has its car and draws the
# other's as a ghost with its name; no round clock before client1's W;
# client1 drives through client2's car standing at the start (the cars do
# not touch) and is still driving at 20 s, when client2, not driving,
# observes it; client1 never observes; client1's finish ends the round:
# the results, and the hill anew as it was made, seed 1 kept
# ([HC_SCORES]). Then a client on a public server is refused the hill's
# parameters, and a local game's rounds are 10 minutes too.
# simplified: the leader's 2 s hold is the client's own few lines, not
# driven (one car runs here); an admin's params on a public server are
# the drives' H (peer 0), as above
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "PASS: (no display: the clients skipped)"; exit 0; }
mp_server() # <name> "<VAR=value ...>" [server args]: in the background
{
	local name=$1 vars="BUILDAT_HILLCLIMB_MODE=straight $firm_soil $2"; shift 2
	mkdir -p "$t/$name"; cp -a "$t/warm/c" "$t/$name/c"
	# shellcheck disable=SC2086 # the assignments, split
	start_server "$t/$name.log" "STATUS Listening" 300 auto env $vars \
		bin/buildat_server -m "$app" -D "$t/$name/u" -C "$t/$name/c" -l 3 "$@" ||
		fail "the server ($t/$name.log)"
	CHECK_PIDS+=($SERVER_PID)
}
mp_client() # <name> <cmds>, in the background: its PID in $CLIENT
{
	timeout 300 bin/buildat -C "$t/c_$1" -D "$t/u_$1" -w 800x500 -l 3 \
		-o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$2" > "$t/$1.log" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
}
mp_server mp "BUILDAT_HILLCLIMB_INTERVAL=20 BUILDAT_HILLCLIMB_FEATURES=0
	BUILDAT_HILLCLIMB_STEEP=22 BUILDAT_HILLCLIMB_STEEP_VAR=0" -u launcher=1
cat > "$t/mp1.cmds" <<C
wait_log 120000 hillclimb: this client's car is
wait_log 120000 car drawn as a ghost
delay 2000
keydown W
wait_log 120000 hillclimb: the round's results
keyup W
delay 2000
quit
C
cat > "$t/mp2.cmds" <<C
wait_log 120000 car drawn as a ghost
wait_log 120000 hillclimb: observing
wait_log 120000 hillclimb: the round's results
delay 8000
quit
C
mp_client mp1 "$t/mp1.cmds"; c1=$CLIENT
wait_for_log "$t/mp.log" "hillclimb: client.*'s car \\(1\\)" 120 || fail "client1 has no car ($t/mp.log)"
mp_client mp2 "$t/mp2.cmds"; c2=$CLIENT
wait $c1 || fail "client1's drive ($t/mp1.log)"
wait $c2 || fail "client2's drive ($t/mp2.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
m="$t/mp.log"
n1=$(grep -a "'s car (1)," "$m" | head -1 | sed "s/.*hillclimb: \(.*\)'s car (1).*/\1/")
n2=$(grep -a "'s car (2)," "$m" | head -1 | sed "s/.*hillclimb: \(.*\)'s car (2).*/\1/")
grep -aq "hillclimb: $n2's car drawn as a ghost" "$t/mp1.log" &&
	grep -aq "hillclimb: $n1's car drawn as a ghost" "$t/mp2.log" ||
	fail "the ghosts: $n1 and $n2 ($t/mp1.log, $t/mp2.log)"
clock=$(grep -an "round: $n1's drive starts the clock" "$m" | head -1 | cut -d: -f1)
extra=$(grep -an "round: the extra time" "$m" | head -1 | cut -d: -f1)
over=$(grep -an "round over:" "$m" | head -1 | cut -d: -f1)
[ -n "$clock" ] && [ -n "$extra" ] && [ -n "$over" ] && [ "$clock" -lt "$extra" ] &&
	[ "$extra" -lt "$over" ] || fail "the round's order: clock $clock, extra $extra, over $over ($m)"
grep -aq "hillclimb: $n1 finished in" "$m" &&
	grep -aA1 "round over:" "$m" | grep -aq "$n1" ||
	fail "client1 did not finish through client2's car, or not in the results ($m)"
# client1 observes only once the extra time is over (everyone not
# driving does then); before the results it drives
grep -aq "hillclimb: observing $n1" "$t/mp2.log" &&
	! sed -n "/hillclimb: the round's results/q;p" "$t/mp1.log" | grep -av " __app   : " | grep -aq "hillclimb: observing" ||
	fail "client2 not observing client1, or client1 observing before the results ($t/mp1.log, $t/mp2.log)"
# [HC_SCORES] The hill made anew after the round: as it was, seed 1 kept
seeds=$(grep -a "hillclimb: the hill, seed\|hillclimb: the hill as it was made, seed" "$m" |
	sed 's/.*seed \([0-9]*\).*/\1/' | tr '\n' ' ')
grep -aq "hillclimb: the hill as it was made, seed 1" "$m" && [ "$seeds" = "1 1 " ] ||
	fail "the hill not made anew with its seed: seeds $seeds ($m)"
grep -aq "hillclimb: the round's results:.*$n1" "$t/mp2.log" || fail "client2 shown no results ($t/mp2.log)"
echo "  two cars: $n1 and $n2, ghosts both ways; the round: $n1's run, $n2 observing; seeds $seeds"
# [HC_STARPORT] Its Starport a dead local port: the admin's IDs turned on
# announce to nothing real
mp_server pub "BUILDAT_HILLCLIMB_FEATURES=0 BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9"
# [HC_GUEST_PLAY] The player in by "Play as a guest": guest1 with a car;
# a registration as guest7 refused
printf '%s\n' "wait_log 120000 accounts: the login page shown" \
	'click Button "Play as a guest"' \
	"wait_log 120000 hillclimb: this client's car is" \
	"event hillclimb_params 1 15 30 0 60 172 14" "delay 1000" quit > "$t/mp3.cmds"
mp_client mp3 "$t/mp3.cmds"; c3=$CLIENT
printf '%s\n' "wait_log 120000 Login refused:" quit > "$t/mp4.cmds"
BUILDAT_JOIN_NAME=guest7 BUILDAT_JOIN_PASSWORD=guest7pass BUILDAT_JOIN_CREATE=1 \
	mp_client mp4 "$t/mp4.cmds"
wait $c3 || fail "the public client ($t/mp3.log)"
wait $CLIENT || fail "the guest7 client ($t/mp4.log)"
# [HC_STARPORT] An admin (the setup code's) turns Starport IDs on from
# the Server window's setting: the hello then says they are taken
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/pub.log" | head -1)
printf '%s\n' "wait_log_any 60000 admin script: done" \
	"wait_log_any 20000 hello: Starport IDs taken" quit > "$t/mp5.cmds"
BUILDAT_JOIN_NAME=adm BUILDAT_JOIN_PASSWORD=admpass123 BUILDAT_JOIN_CREATE=1 \
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_ADMIN="setting starport_ids anyone" \
	mp_client mp5 "$t/mp5.cmds"
wait $CLIENT || fail "the admin's Starport IDs ($t/mp5.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "hillclimb: params from .* refused: not an admin" "$t/pub.log" &&
	! grep -aq "hillclimb: the hill, seed 1, 15 degrees" "$t/pub.log" &&
	grep -aq "a public server, rounds every 600 s" "$t/pub.log" ||
	fail "a non-admin's params not refused, or the public rounds not 10 min ($t/pub.log)"
grep -aq "joined as a guest, guest1" "$t/pub.log" &&
	grep -aq "hillclimb: guest1's car (1)" "$t/pub.log" &&
	grep -aq "accounts: logged in as guest1 by guest" "$t/mp3.log" ||
	fail "no guest1 with a car ($t/pub.log, $t/mp3.log)"
grep -aq 'Login refused: "guest7" is kept' "$t/mp4.log" ||
	fail "guest7 registered ($t/mp4.log)"
echo "  a guest: guest1 by one press, with a car; guest7 refused to registration"
grep -aq "hello: Starport IDs not taken" "$t/mp5.log" &&
	grep -aq "admin result: Announced, unlisted, to https://127.0.0.1:9" "$t/mp5.log" ||
	fail "Starport IDs not turned on by the admin ($t/mp5.log)"
echo "  Starport: IDs off at first, an admin turns them on (starport_announce loaded)"
mp_server loc BUILDAT_HILLCLIMB_FEATURES=0 -u launcher=1
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "a local server, rounds every 600 s" "$t/loc.log" || fail "a local game's rounds not 10 min ($t/loc.log)"
echo "  a public server: a player's params refused; rounds of 10 min, a local game's too"
# Escape's menu ([HC_PAUSE_MENU]): W held through it sends nothing while
# it is up; Settings... comes back to it, its Server... the way to the
# Server window ([HC_TOUCH_SERVER]: no corner button); Leave the game
# leaves (with -s there is no launcher under the game: the client
# disconnects and exits)
mp_server pause BUILDAT_HILLCLIMB_FEATURES=0 -u launcher=1
cat > "$t/pause.cmds" <<C
wait_log 120000 hillclimb: this client's car is
delay 3000
keypress Tab
wait_log 5000 hillclimb: the hill menu shown
delay 500
keypress Down
delay 200
keypress Return
delay 500
keypress Down
delay 200
keypress Return
wait_log 3000 hillclimb: the hill menu: steep
delay 300
$(for i in 1 2 3 4 5 6 7 8 9; do echo keypress Down; echo delay 150; done)
screenshot $t/hill_menu.png
keypress Return
wait_log 5000 hillclimb: the hill menu sends params
delay 3000
keydown W
delay 1500
keypress Escape
wait_log 5000 pause: the menu shown
delay 1000
screenshot $t/pause.png
click Button "Settings..."
wait_log 5000 pause: settings shown
delay 1000
click Button "Server..."
delay 1500
keypress Escape
wait_log 5000 server window: closed
delay 1000
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
keypress Escape
wait_log 5000 pause: the menu closed
delay 1000
keyup W
delay 500
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Leave the game"
wait_log 5000 pause: leave
delay 2000
quit
C
mp_client pause "$t/pause.cmds"
wait $CLIENT
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
seq=$(grep -a " hillclim: \(pause: \|hillclimb: input \)" "$t/pause.log" |
	sed 's/.* hillclim: //; s/hillclimb: input \(.\) .*/W\1/' | tr '\n' '|')
want="W1|pause: the menu shown|W0|pause: the menu closed|pause: settings shown|pause: settings closed|pause: the menu shown|pause: the menu closed|W1|W0|pause: the menu shown|pause: leave|"
[ "${seq#W0|}" = "$want" ] && grep -aq "leave: no launcher" "$t/pause.log" ||
	fail "the pause menu: $seq ($t/pause.log)"
# [HC_HILL_MENU] Tab's window by its keys: Down to Steepness, its next
# choice, Down to Make it: the params sent with that steepness
steep=$(grep -a "hillclimb: the hill menu: steep " "$t/pause.log" | sed 's/.*steep //')
sent=$(grep -a "hillclimb: the hill menu sends params " "$t/pause.log" | sed 's/.*params //')
[ -n "$steep" ] && [ "$(echo "$sent" | awk '{print $2}')" = "$steep" ] ||
	fail "the hill menu: steepness ${steep:-none}, sent ${sent:-none} ($t/pause.log)"
echo "  Escape: the menu, no input under it, settings and back, leave"
# [HC_SOFT_GROUND] The hill menu's second page: the sand's firmness a step
# up, made; the server's hill line has it. [HC_SOFT_DEFAULTS] On the
# game's default soil
mp_server ground_srv "BUILDAT_HILLCLIMB_FEATURES=0 $default_soil" -u launcher=1
cat > "$t/ground.cmds" <<C
wait_log 120000 hillclimb: this client's car is
delay 2000
keypress Tab
wait_log 5000 hillclimb: the hill menu shown
delay 500
click Button "Ground and car..."
wait_log 5000 hillclimb: the hill menu shown (the ground and the car)
delay 500
keypress Down
delay 200
keypress Return
delay 500
keypress Down
delay 200
keypress Return
wait_log 3000 hillclimb: the hill menu: bearing 40
delay 300
$(for i in 1 2 3 4 5; do echo keypress Down; echo delay 150; done)
screenshot $t/ground_menu.png
keypress Return
wait_log 5000 hillclimb: the hill menu sends params
delay 3000
quit
C
mp_client ground "$t/ground.cmds"
wait $CLIENT || fail "the ground page's drive ($t/ground.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "hillclimb: the hill, seed .* voxels; sand 30 kPa, dig 6, power 150%, grip 0.60, stones 20%" \
	"$t/ground_srv.log" || fail "not the default soil ($t/ground_srv.log)"
grep -aq "hillclimb: the hill as it was made, seed .*; sand 40 kPa, dig 6, power 150%, grip 0.60, stones 20%" \
	"$t/ground_srv.log" || fail "the ground page's firmness not made ($t/ground_srv.log)"
echo "  the default soil 30 kPa; the hill menu's ground page: the sand's firmness made 40 kPa"
# [HC_HUD_LAYOUT] The accelerator bound to Up in the key store: the start
# prompt names it, centred across at 75% down; driving, with turn 1
# missed (a circuit's car started past it), the prompt says that alone
mp_server hud_srv "BUILDAT_HILLCLIMB_MODE=circuit BUILDAT_HILLCLIMB_FEATURES=0
	BUILDAT_HILLCLIMB_STEEP=5 BUILDAT_HILLCLIMB_WIDTH=40 BUILDAT_HILLCLIMB_LENGTH=30
	BUILDAT_HILLCLIMB_SWITCHBACKS=100 BUILDAT_HILLCLIMB_LANE=6
	BUILDAT_HILLCLIMB_START=36.9,7,180" -u launcher=1
mkdir -p "$t/u_hud"
printf 'shared\tmove.forward\tUp\n' > "$t/u_hud/keys.txt"
cat > "$t/hud.cmds" <<C
wait_log 120000 hillclimb: this client's car is
wait_log 20000 hillclimb: the prompt centred at
delay 1000
screenshot $t/hud_start.png
keydown Up
wait_log 10000 Missed turn 1
delay 500
screenshot $t/hud_driving.png
keyup Up
quit
C
mp_client hud "$t/hud.cmds"
wait $CLIENT || fail "the HUD's drive ($t/hud.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
python3 -I - "$t/hud.log" <<'PY' || fail "the HUD's prompt ($t/hud.log)"
import re, sys
said = re.findall(r"hillclimb: the prompt centred at (-?\d+),(-?\d+) of (\d+)x(\d+): (.*)",
    open(sys.argv[1], errors="replace").read())
start = [s for s in said if s[4].startswith("Up starts your laps")]
ok = bool(start) and all(abs(int(x) - int(w) / 2) <= 1 and
    abs(int(y) - 0.75 * int(h)) <= 1 for x, y, w, h, _ in start)
ok = ok and any(s[4] == "Missed turn 1" for s in said[said.index(start[0]):])
print("  the HUD: %s" % " / ".join(s[4] for s in said))
sys.exit(0 if ok else 1)
PY
# [HC_TOUCH] BUILDAT_TOUCH=1 at 800x500 (a UI scale of 1.25: the ring's
# 65 pixels are 81): a stick pushed full up on the left drives up the
# slope in fourth, the same on the right half, full down backs it; Start
# (the column's top) resets with no stick, the car at the start again (a
# quarter up and a half across: first gear, steer 44); Menu opens the
# pause menu. [HC_TOUCH_ORBIT] a drag in the top third (100 pixels, 80
# HUD ones) turns the yaw 24 degrees, a pinch there from 80 to 160
# pixels apart halves the distance, and the stick (third gear) with a
# drag back at once does both. [HC_STICK_AXES] up is twice the travel
# (2R, 162 pixels): a push 3R up and R/2 across keeps its steer, 0.44 in
# fourth. [HC_HILL_MENU] Menu, The hill..., Steepness's dropdown tapped,
# a choice, Make it: the params sent with it
mp_server touch "BUILDAT_HILLCLIMB_FEATURES=0 BUILDAT_HILLCLIMB_STEEP=15
	BUILDAT_HILLCLIMB_STEEP_VAR=0" -u launcher=1
cat > "$t/touch.cmds" <<C
wait_log 120000 hillclimb: this client's car is
delay 3000
finger_down 1 200 300
finger_move 1 200 100
delay 4000
finger_up 1
delay 2000
finger_down 2 600 300
finger_move 2 600 100
delay 3000
finger_up 2
delay 1500
finger_down 1 200 200
finger_move 1 200 450
delay 3000
finger_up 1
delay 1000
finger_down 3 300 80
finger_move 3 400 80
delay 300
finger_up 3
wait_log 3000 hillclimb: camera yaw 224 pitch 20 dist 12.0 m
finger_down 3 300 80
finger_down 4 380 80
delay 200
finger_move 4 460 80
delay 300
finger_up 4
finger_up 3
wait_log 3000 hillclimb: camera yaw 224 pitch 20 dist 6.0 m
finger_down 1 200 300
finger_move 1 200 180
finger_down 3 300 80
finger_move 3 200 80
delay 2000
finger_up 3
wait_log 3000 hillclimb: camera yaw 200 pitch 20 dist 6.0 m
finger_up 1
delay 1000
finger_down 1 200 400
finger_move 1 241 156
delay 1000
finger_up 1
delay 1000
tap 724 50
delay 3000
finger_down 1 200 300
finger_move 1 200 260
delay 200
finger_move 1 240 260
delay 300
screenshot $t/touch.png
finger_up 1
delay 500
tap 724 190
wait_log 5000 pause: the menu shown
delay 500
click Button "The hill..."
wait_log 5000 hillclimb: the hill menu shown
delay 1000
tap 455 116
delay 1000
tap 430 241
wait_log 3000 hillclimb: the hill menu: steep
delay 500
tap 400 430
wait_log 5000 hillclimb: the hill menu sends params
delay 500
quit
C
BUILDAT_TOUCH=1 mp_client touch "$t/touch.cmds"
wait $CLIENT || fail "the touch drive ($t/touch.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
# "msg z" each input line, and the climbs: a pushed stick's line and the
# next one's z
in=$(grep -a " hillclim: hillclimb: input " "$t/touch.log" |
	sed 's/.*input \(.*\) at z \([-0-9.]*\) m/\1|\2/')
climbs=$(echo "$in" | awk -F'|' 'p != "" { print p, $2 - z; p = "" }
	$1 == "1 0 0 0 4 0 0" || $1 == "1 0 0 0 0 0 0" { p = $1; z = $2 }' |
	awk '{ printf "%s:%.1f ", $5, $8 }')
set -- $climbs
[ $# -eq 3 ] && [ "${1%%:*}" = 4 ] && [ "${2%%:*}" = 4 ] && [ "${3%%:*}" = 0 ] &&
	awk -v a="${1#*:}" -v b="${2#*:}" -v c="${3#*:}" 'BEGIN { exit !(a > 5 && b > 5 && c < -1) }' ||
	fail "the stick's drives (gear:metres) $climbs ($t/touch.log)"
start=$(echo "$in" | sed -n '/^0 0 0 0 [0-9] 1 0|/,$p' | grep '^1 0 0 0 1 0 4[0-9]|' | head -1)
grep -aq "touch: Start" "$t/touch.log" && [ -n "$start" ] &&
	awk -v z="${start#*|}" 'BEGIN { exit !(z < 5) }' &&
	grep -aq "touch: Menu" "$t/touch.log" && grep -aq "pause: the menu shown" "$t/touch.log" ||
	fail "Start (no stick, the car at the start: ${start:-none}) or Menu ($t/touch.log)"
steep=$(grep -a "hillclimb: the hill menu: steep " "$t/touch.log" | sed 's/.*steep //')
sent=$(grep -a "hillclimb: the hill menu sends params " "$t/touch.log" | sed 's/.*params //')
[ -n "$steep" ] && [ "$steep" != 15 ] && [ "$(echo "$sent" | awk '{print $2}')" = "$steep" ] ||
	fail "the hill menu by touch: steepness ${steep:-none}, sent ${sent:-none} ($t/touch.log)"
echo "$in" | grep -q '^1 0 0 0 4 0 4[0-9]|' ||
	fail "a push past the top cut the steer ($t/touch.log)"
echo "$in" | grep -q '^1 0 0 0 3 0 0|' ||
	fail "the stick in third under the orbit's drag ($t/touch.log)"
echo "  touch: the stick's drives (gear:metres) $climbs; Start, then first gear at z ${start#*|} m"
echo "PASS: the hill, the car, the time trial and the ground that gives, cars each and rounds"
# vim: set noet ts=4 sw=4:
