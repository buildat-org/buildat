#!/bin/bash
# tier: long
# cost: ~4 min (2026-10-21)
# covers: src/impl/thread_pool.cpp src/impl/mesh.cpp src/lua_bindings/mesh.cpp builtin/voxelworld/client_lua/module.lua src/client/app.cpp
# [WEB_MAIN_THREAD]: the web client's hitches no worse than the native
# client's. hillclimb driven ~60 s (W held), natively and in Firefox
# (util/web_drive.sh, the web client from web/), both with the frame split
# (BUILDAT_FRAME_SPLIT, ?frame_split=1): a line every 10 s of frames with
# their mean and 95th percentile. The first two windows after the car
# shows are the load and are left out; of the rest, the web's median
# p95/mean is to be no more than the native's median plus the native
# windows' own spread (at least 0.1). Both ratios and means are printed:
# the before and after of [WEB_MAIN_THREAD] were read off them.
#   util/web_frame_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp web_frame; t=$CHECK_TMP
trap check_cleanup EXIT
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9

# Native
start_server "$t/s.log" "STATUS Listening" 300 auto "$here/Build/bin/buildat_server" \
	-m "$here/apps/hillclimb" -D "$t/s" -C "$t/s.cache" -l 3 -u launcher=1 ||
	fail "the server ($t/s.log)"
CHECK_PIDS+=($SERVER_PID)
{
	echo "wait_log 120000 hillclimb: this client's car is"
	echo "keydown W"
	for i in 1 2 3 4 5 6 7; do echo "wait_log 20000 frames in 1"; done
	echo "keyup W"
	echo "quit"
} > "$t/seq"
BUILDAT_FRAME_SPLIT=1 run_client 60 "$t/c.log" timeout 240 \
	"$here/Build/bin/buildat" -s 127.0.0.1:$SERVER_PORT -D "$t/c" \
	-C "$t/c.cache" -w 1200x800 -l 3 -o sound_mute=1 -c @"$t/seq" ||
	fail "the native client ($t/c.log)"
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null
wait_quiet || fail "the native run did not end"

# Web: web_join's login and car, then the drive
python3 - "$here/util/web_join.json" "$t/web.json" <<'PY'
import json, sys
steps = json.load(open(sys.argv[1]))
steps[0] = ["nav", "${URL}?frame_split=1"]
steps = steps[:steps.index(["holdkey", "w", 10000])]
steps += [["holdkey", "w", 60000], ["waitlog", "frames in 1", 20]]
json.dump(steps, open(sys.argv[2], "w"), indent=1)
PY
bash "$here/util/web_drive.sh" firefox hillclimb "$t/web.json" "$t/web" \
	> "$t/web.log" 2>&1 || fail "the web drive ($t/web.log)"

python3 - "$t/c.log" "$t/web/page.log" <<'PY'
import re, statistics, sys
def windows(path):
	lines = open(path, errors="replace").read().splitlines()
	car = next(i for i, l in enumerate(lines) if "this client's car is" in l)
	w = [re.search(r"frames in [\d.]+ s, mean ([\d.]+) ms, p95 ([\d.]+)", l)
			for l in lines[car:]]
	w = [(float(m.group(1)), float(m.group(2))) for m in w if m][2:]
	if len(w) < 3:
		sys.exit("FAIL: %d windows driving in %s" % (len(w), path))
	return w
nat, web = windows(sys.argv[1]), windows(sys.argv[2])
rn = [p / m for m, p in nat]
rw = [p / m for m, p in web]
margin = max(0.1, max(rn) - min(rn))
bound = statistics.median(rn) + margin
say = lambda name, w, r: "%s mean %s ms, p95/mean %s" % (name,
		" ".join("%.1f" % m for m, _ in w), " ".join("%.2f" % x for x in r))
print(say("native", nat, rn))
print(say("web", web, rw))
if statistics.median(rw) > bound:
	sys.exit("FAIL: the web's median p95/mean %.2f is over the native's"
			" %.2f plus %.2f" % (statistics.median(rw), statistics.median(rn),
			margin))
print("PASS: the web's median p95/mean %.2f, the native's %.2f (bound %.2f);"
		" web mean %.1f ms" % (statistics.median(rw), statistics.median(rn),
		bound, statistics.median(m for m, _ in web)))
PY
