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
# removed. [HC_PAUSE_MENU] and [HC_TOUCH]: driven clients at the end.
#   apps/hillclimb/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp hillclimb; t=$CHECK_TMP
app="$here/apps/hillclimb"

g++ -std=c++11 -O1 -DHILL_TEST -x c++ "$app/main/hill.h" -o "$t/hill_test" \
	2> "$t/hill_build.log" || fail "hill.h self test did not build: $(head -3 "$t/hill_build.log")"
"$t/hill_test" || fail "hill.h self test"
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
	[parked]=12)
drive()
{
	local name=$1; shift
	# The car's own drives on a hill with no pits or rocks (the rock's
	# below sets them on again)
	# The modules compiled once (warm, below), each drive a copy
	[ -d "$t/warm/c" ] && [ "$name" != warm ] && mkdir -p "$t/$name" &&
		cp -a "$t/warm/c" "$t/$name/c"
	env BUILDAT_HILLCLIMB_FEATURES=0 "$@" timeout 150 bin/buildat_server -m "$app" -D "$t/$name/u" \
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
drive rock BUILDAT_HILLCLIMB_FEATURES=1 BUILDAT_HILLCLIMB_SEED=6 \
	BUILDAT_HILLCLIMB_START="6.21 3 0" BUILDAT_HILLCLIMB_DRIVE="0:S2 2:W2 14:Q" &
drive beside BUILDAT_HILLCLIMB_FEATURES=1 BUILDAT_HILLCLIMB_SEED=6 \
	BUILDAT_HILLCLIMB_START="2.1 3 0" BUILDAT_HILLCLIMB_DRIVE="0:S2 2:W2 14:Q" &
# [HC_OPEN_EDGES] Up the slope in second, steered right from 7 s: off the
# side, put back; a minute parked on the bottom pad, a stone thrown off
# the left edge at 1 s
drive side BUILDAT_HILLCLIMB_DRIVE="0:S2 2:W2 7:W2D 16:Q" &
drive parked BUILDAT_HILLCLIMB_DRIVE="0:S 1:SJ 60:Q" &
wait
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
# 8 cars on one hill, the same keys: the step's cost
drive cars8 BUILDAT_HILLCLIMB_CARS=8 BUILDAT_HILLCLIMB_DRIVE="0:S 1:W 12:Q" &
wait
grep -a "hillclimb: the hill" "$t/flat.log" | sed 's/.*hillclimb: /  /'
# The default hill ([HC_DEFAULTS])
grep -aq "hillclimb: the hill, seed 1, 29 degrees, 50 m long" "$t/flat.log" ||
	fail "no hill made, or not at 29 degrees by default ($t/flat.log)"
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
ends = [float(m) for m in re.findall(r"drive's car put back, the pose \S+ s "
    r"old, off the track at \S+,(\S+) m", log)]
# (the first: later the 30 m hill's end is nearer)
want(at(climb, 30.5)["y"] > 20 and ends and ends[0] > 60,
    "kept on the top, put back off its end: y %.1f m, off at z %s" % (
    at(climb, 30.5)["y"], ends[:3]))
side = open("%s/side.log" % d, errors="replace").read()
back = re.findall(r"drive's car put back, the pose (\S+) s old, off the track "
    r"at (\S+),(\S+) m, to (\S+),(\S+),(\S+) m, lifted (\d+) voxels", side)
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
    k22 = "v4/seed1/steep22/length50/sand/payload0/"
    t1, t2 = float(fins[0][0]), float(fins[1][0])
    want(fins[0][1] == k22 and fins[1][1] == k22 and 20 < t1 < 40 and t2 < t1,
        "second gear's time, then fourth's faster, under the hill's key")
    want(fins[1][2] == "0" and fins[1][3].split() == [fins[1][0], fins[0][0]],
        "the second run first in the ranking, the first beside it")
    want(fins[2][1] == "v4/seed1/steep15/length30/sand/payload0/" and
        fins[2][3].split() == [fins[2][0]], "the other hill's run under its own key")
want("hillclimb: the hill, seed 1, 15 degrees, 30 m long" in log, "the hill made again from the pick")
spin = [l for l in stall if 22 <= l["t"] <= 25]
want(max(l["z"] for l in stall) < 12 and all("1" in l["slip"] for l in spin),
    "40 degrees with 2 t stalls, its wheels slipping: z %.1f, slip %s" % (
    max(l["z"] for l in stall), [l["slip"] for l in spin]))
# The ground: the stall's spinning wheels dig a rut and throw the sand;
# a stone comes loose, rolls down and rests
slog = open("%s/stall.log" % d, errors="replace").read()
g = [int(x) for x in re.findall(r"ground=(\d+)/", slog)]
ruts = [int(x) for x in re.findall(r"rut=(\d+)", slog)]
# On 40 degrees, past sand's angle of repose, a pit refills from above as
# it is dug: a voxel deep at least (ground.h's self test digs two on the
# flat)
want(g and g[-1] >= 30 and max(ruts) >= 1,
    "spun in place, the wheels dug a rut: %d voxels dug, %d deep" % (
    g[-1] if g else 0, max(ruts) if ruts else 0))
loose = {m[0]: [float(v) for v in m[1:4]] for m in re.findall(
    r"rock (\d+) loose at (\S+),(\S+),(\S+) m", slog)}
rests = {m[0]: [float(v) for v in m[1:4]] + [int(m[4])] for m in re.findall(
    r"rock (\d+) rests at (\S+),(\S+),(\S+) m, \S+ m from where it came "
    r"loose, (\d+) voxels", slog)}
say = ["%s: y %.2f -> %.2f, %d voxels" % (k, loose[k][1], rests[k][1],
    rests[k][3]) for k in sorted(rests) if k in loose]
# Rock 1 is the one K dropped on the slope's lower third
want("1" in rests and rests["1"][1] < loose["1"][1] - 1 and rests["1"][3] > 0,
    "a stone on the slope rolled down and rested as voxels: %s" % say)
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
# the results, and the hill anew with another seed. Then a client on a
# public server is refused the hill's parameters, and a local game with
# no interval has no rounds.
# simplified: the leader's 2 s hold is the client's own few lines, not
# driven (one car runs here); an admin's params on a public server are
# the drives' H (peer 0), as above
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "PASS (no display: the clients skipped)"; exit 0; }
mp_server() # <name> "<VAR=value ...>" [server args]: in the background
{
	local name=$1 vars=$2; shift 2
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
	BUILDAT_HILLCLIMB_STEEP=22" -u launcher=1
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
seeds=$(grep -a "hillclimb: the hill, seed" "$m" | sed 's/.*seed \([0-9]*\),.*/\1/' | tr '\n' ' ')
set -- $seeds
[ $# -ge 2 ] && [ "$1" != "$2" ] || fail "the hill not made anew: seeds $seeds ($m)"
grep -aq "hillclimb: the round's results:.*$n1" "$t/mp2.log" || fail "client2 shown no results ($t/mp2.log)"
echo "  two cars: $n1 and $n2, ghosts both ways; the round: $n1's run, $n2 observing; seeds $seeds"
mp_server pub BUILDAT_HILLCLIMB_FEATURES=0
printf '%s\n' "wait_log 120000 hillclimb: the hill" "delay 1000" \
	"event hillclimb_params 1 15 30 0 60 172 14" "delay 1000" quit > "$t/mp3.cmds"
mp_client mp3 "$t/mp3.cmds"
wait $CLIENT || fail "the public client ($t/mp3.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "hillclimb: params from .* refused: not an admin" "$t/pub.log" &&
	! grep -aq "hillclimb: the hill, seed 1, 15 degrees" "$t/pub.log" &&
	grep -aq "a public server, rounds every 600 s" "$t/pub.log" ||
	fail "a non-admin's params not refused, or the public rounds not 10 min ($t/pub.log)"
mp_server loc BUILDAT_HILLCLIMB_FEATURES=0 -u launcher=1
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "a local server, rounds every 0 s" "$t/loc.log" || fail "a local game has rounds ($t/loc.log)"
echo "  a public server: a player's params refused, rounds of 10 min; a local game none"
# Escape's menu ([HC_PAUSE_MENU]): W held through it sends nothing while
# it is up; Settings... comes back to it, its Server... the way to the
# Server window ([HC_TOUCH_SERVER]: no corner button); Leave the game
# leaves (with -s there is no launcher under the game: the client
# disconnects and exits)
mp_server pause BUILDAT_HILLCLIMB_FEATURES=0 -u launcher=1
cat > "$t/pause.cmds" <<C
wait_log 120000 hillclimb: this client's car is
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
echo "  Escape: the menu, no input under it, settings and back, leave"
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
# fourth
mp_server touch "BUILDAT_HILLCLIMB_FEATURES=0 BUILDAT_HILLCLIMB_STEEP=15" -u launcher=1
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
echo "$in" | grep -q '^1 0 0 0 4 0 4[0-9]|' ||
	fail "a push past the top cut the steer ($t/touch.log)"
echo "$in" | grep -q '^1 0 0 0 3 0 0|' ||
	fail "the stick in third under the orbit's drag ($t/touch.log)"
echo "  touch: the stick's drives (gear:metres) $climbs; Start, then first gear at z ${start#*|} m"
echo "PASS: the hill, the car, the time trial and the ground that gives, cars each and rounds"
# vim: set noet ts=4 sw=4:
