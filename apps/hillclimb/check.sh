#!/bin/bash
# tier: full
# cost: ~80 s (2026-10-16)
# covers: apps/hillclimb/** extensions/physical_sky/init.lua extensions/sky_render/**
# hillclimb ([HILLCLIMB], doc/plan/hillclimb_plan.md's Check), no
# pixels. The generator's own self test (main/hill.h: the same seed the
# same hill, the slope's angle, the pads flat and long enough, the track
# 8 m, sand with stones), the client Lua parsing, and three drives with
# no client (BUILDAT_HILLCLIMB_DRIVE): the car settling on its springs,
# lower with a payload, each gear's top speed, the brake, a slope
# climbed and one past the sand's grip stalled; the time trial's times
# kept per hill and payload in order, and a hill picked again; the
# ground (main/ground.h's own self test too): a rut dug by wheels spun in
# place, stones loose that roll down and rest.
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

cd "$here/Build"
# Three drives at once, each its own server with the hill and the car and
# no client (BUILDAT_HILLCLIMB_DRIVE, main.cpp); each ends itself
drive()
{
	local name=$1; shift
	# The car's own drives on a hill with no pits or rocks (the rock's
	# below sets them on again)
	env BUILDAT_HILLCLIMB_FEATURES=0 "$@" timeout 150 bin/buildat_server -m "$app" -D "$t/$name/u" \
		-C "$t/$name/c" -P $((29700 + RANDOM % 300)) -l 3 > "$t/$name.log" 2>&1
}
# On the flat past the hill's start, facing away: each gear's top speed,
# then the brake
drive flat BUILDAT_HILLCLIMB_START="5 -30 180" \
	BUILDAT_HILLCLIMB_DRIVE="0:4 3:W1 9:W2 15:W3 21:W4 27:S4 31:Q" &
# The time trial: 22 degrees climbed in second, the gear a car starts in
# ([HC_DEFAULTS]: no gear key before it), held at the top by the end's
# bank; again in fourth, faster; then a hill of 15 degrees and 30 m
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
# [HC_PITS_ROCKS] The rock at z 9.7 stops the car or turns it aside;
# beside it the car goes on straight past it
# (the line beside is clear only so far: further up it meets a pit)
rock, beside = lines("rock"), lines("beside")
r_top = max(l["z"] for l in rock)
b_top = max(l["z"] for l in beside)
r_dx = max(abs(l["x"] - rock[0]["x"]) for l in rock)
b_dx = max(abs(l["x"] - beside[0]["x"]) for l in beside if l["z"] <= 13)
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
want(at(climb, 30.5)["y"] > 20, "held on the top by the end's bank: y %.1f m" % at(climb, 30.5)["y"])
log = open("%s/climb.log" % d, errors="replace").read()
fins = re.findall(r"hillclimb: finish (\S+) s on (\S+), rank (\S+); the ranking:(.*)", log)
for f in fins:
    print("    finish %s s on %s rank %s; ranking%s" % f)
want(len(fins) == 3, "three runs timed: %d" % len(fins))
if len(fins) == 3:
    k22 = "v2/seed1/steep22/length50/sand/payload0/"
    t1, t2 = float(fins[0][0]), float(fins[1][0])
    want(fins[0][1] == k22 and fins[1][1] == k22 and 20 < t1 < 40 and t2 < t1,
        "second gear's time, then fourth's faster, under the hill's key")
    want(fins[1][2] == "0" and fins[1][3].split() == [fins[1][0], fins[0][0]],
        "the second run first in the ranking, the first beside it")
    want(fins[2][1] == "v2/seed1/steep15/length30/sand/payload0/" and
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
echo "PASS: the hill, the car, the time trial and the ground that gives"
# vim: set noet ts=4 sw=4:
