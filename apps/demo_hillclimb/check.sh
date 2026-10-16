#!/bin/bash
# tier: full
# cost: ~45 s (2026-10-16)
# covers: apps/demo_hillclimb/** extensions/physical_sky/init.lua
# demo_hillclimb ([HILLCLIMB], doc/plan/hillclimb_plan.md's Check), no
# pixels. The generator's own self test (main/hill.h: the same seed the
# same hill, the slope's angle, the pads flat and long enough, the track
# 8 m, sand with stones), the client Lua parsing, and three drives with
# no client (BUILDAT_HILLCLIMB_DRIVE): the car settling on its springs,
# lower with a payload, each gear's top speed, the brake, a slope
# climbed and one past the sand's grip stalled. Later stages add the
# time trial and the ground.
#   apps/demo_hillclimb/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp hillclimb; t=$CHECK_TMP
app="$here/apps/demo_hillclimb"

g++ -std=c++11 -O1 -DHILL_TEST -x c++ "$app/main/hill.h" -o "$t/hill_test" \
	2> "$t/hill_build.log" || fail "hill.h self test did not build: $(head -3 "$t/hill_build.log")"
"$t/hill_test" || fail "hill.h self test"

for f in "$app"/main/client_lua/*.lua "$app"/launcher/*.lua; do
	luajit -b "$f" /dev/null || fail "$f does not parse"
done

cd "$here/Build"
# Three drives at once, each its own server with the hill and the car and
# no client (BUILDAT_HILLCLIMB_DRIVE, main.cpp); each ends itself
drive()
{
	local name=$1; shift
	env "$@" timeout 150 bin/buildat_server -m "$app" -D "$t/$name/u" \
		-C "$t/$name/c" -P $((29700 + RANDOM % 300)) -l 3 > "$t/$name.log" 2>&1
}
# On the flat past the hill's start, facing away: each gear's top speed,
# then the brake
drive flat BUILDAT_HILLCLIMB_START="5 -30 180" \
	BUILDAT_HILLCLIMB_DRIVE="0:4 3:W1 9:W2 15:W3 21:W4 27:S4 31:Q" &
# 22 degrees in second, climbed
drive climb BUILDAT_HILLCLIMB_DRIVE="0:2 2:W2 33:Q" &
# 40 degrees with 2 t aboard in first: past the sand's grip, it stalls
drive stall BUILDAT_HILLCLIMB_STEEP=40 BUILDAT_HILLCLIMB_PAYLOAD=2000 \
	BUILDAT_HILLCLIMB_DRIVE="0:1 2:W1 20:Q" &
wait
grep -a "hillclimb: the hill" "$t/flat.log" | sed 's/.*hillclimb: /  /'
grep -aq "hillclimb: the hill, seed 1, 22 degrees, 50 m long" "$t/flat.log" ||
	fail "no hill made ($t/flat.log)"
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
            out.append(dict(t=float(g[0]), y=float(g[2]), z=float(g[3]),
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
top = max(l["z"] for l in climb)
want(top > 56, "22 degrees climbed to the top pad (z 56 m): %.1f" % top)
last = stall[-3:]
want(max(l["z"] for l in stall) < 12 and all(l["slip"] == "1111" for l in last),
    "40 degrees with 2 t stalls, its wheels slipping: z %.1f, slip %s" % (
    max(l["z"] for l in stall), [l["slip"] for l in last]))
us = [int(m) for m in re.findall(r"tick_us=(\d+)",
    open("%s/climb.log" % d, errors="replace").read())]
print("  the physics per 30 Hz tick on the climb: mean %d us, worst %d us" % (
    sum(us) / len(us), max(us)))
sys.exit(1 if bad else 0)
PY
echo "PASS: the hill's generator, the server's module and the car on rigid ground"
# vim: set noet ts=4 sw=4:
