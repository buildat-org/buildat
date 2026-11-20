#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-20)
# covers: builtin/kit/kit.cpp builtin/kit/types/walker.lua
# [KIT_CROWD_CHECK] (kit_plan 4z37o, 4z37m's G8) One Workbench server
# holding a crowd of walking players: for each count in CROWD_COUNTS (20 by
# default; CROWD_COUNTS="20 35 50" for the curve), CROWD_CLIENTS real
# clients (2) and the rest bots, a project of the check's own:
#   - the bots: workbench/crowd, a check type (below), each a bot whose
#     body Kit steps with the players' kit/walker as a player's
#     ([KIT_BOT_DRIVE]), round a circle about the spawn, a jump now and
#     then; a scripted headless client is some 400 MB and 1.8 cores on
#     llvmpipe, so 50 of them do not fit a desk;
#   - client 1 (the admin) stands at the spawn, its frame time measured;
#     client 2 walks to and fro and jumps (W, S, Space): a player's body
#     the server steps and its node every peer is sent;
# all on a headless weston's Xwayland of the check's own, no sound.
# simplified: a bot is not a player throughout. Kit's tick reads some
# 0.8 ms a bot and 1.2 a real player (4 clients, no bots: 5.1 ms; 2: 2.7);
# a bot's keys reach each client as kit:track (1.1 kB/s), a player's
# node by replicate (some 1 kB/s walking). CROWD_CLIENTS more clients for
# the real thing, as far as the memory goes.
# Measured over 10 s once the clients are in (Kit's BUILDAT_KIT_METER
# lines, the server's /health, each client's socket by ss):
#   - Kit's tick: the gap between two (mean/worst), Kit's own time in one,
#     and the box's meter spent of a tick's budget (mean/worst);
#   - /health's tick gap over the last minute (the network's tick);
#   - bytes a second each client received;
#   - client 1's frame time (two "event kit_looks" and the frames between);
#   - the server's and client 1's RSS.
# A count is run only while free memory stays 2 GB over what it needs
# (the PASS line says what fit). Limits by the count, from the desk's
# numbers with margin for a loaded machine: LIMITS below.
#   util/kit_crowd_check.sh
#   CROWD_COUNTS="20 35 50" util/kit_crowd_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
command -v ss > /dev/null || skip "no ss"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
COUNTS=${CROWD_COUNTS:-20}
C=${CROWD_CLIENTS:-2}
[ "$C" -ge 1 ] || fail "CROWD_CLIENTS is at least 1"
check_tmp kit_crowd; t=$CHECK_TMP
cd "$here/Build"
check_build
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1 SDL_AUDIODRIVER=dummy
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
# The crowd: c:drive's f and r are the world's +z and +x (kit.cpp's
# bot_drive gives the walker yaw 0); a circle of a radius by its id about
# the origin (4 to 26 m, Workbench's stone floor is 64 x 64), every other
# one the other way round, a jump each 10 s; entity 10 logs where it is
# every 2.5 s (that they walk)
cat > "$BUILDAT_WORKBENCH_TYPES/crowd.lua" <<'EOF'
return {
	version = 1,
	about = {what = "A check's crowd: a bot walking round a circle."},
	component = true,
	creature = true,
	bot = true,
	params = {
		name = {type = "string", default = "Crowd"},
		drive = {type = "bool", default = true},
	},
	state = {n = {default = 0}},
	on_start = function(c)
		c:after(0.25)
	end,
	on_timer = function(c)
		local b = c.body
		c.state.n = c.state.n + 1
		if b and b.pos then
			local x, z = b.pos[1], b.pos[3]
			local d = math.sqrt(x * x + z * z) + 1e-6
			local R = 4 + (c.id % 12) * 2
			local s = c.id % 2 == 0 and 1 or -1
			local k = math.max(-1, math.min(1, (R - d) / 2))
			c:drive({r = -z / d * s + k * x / d, f = x / d * s + k * z / d,
				fire = (c.state.n + c.id) % 40 == 0})
			if c.id == 10 and c.state.n % 10 == 0 then
				c:log(string.format("crowd at %.1f %.1f", x, z))
			end
		end
		c:after(0.25)
	end,
}
EOF

# The save, made by a first start; each count's rows written into it
start_server "$t/srv0.log" "Hosted: |Not hosted: " 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv0.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
db=$t/user/apps/workbench/saves/world/save.sqlite
[ -f "$db" ] || fail "no save ($t/user)"
rows() # <bots>
{
	python3 -I - "$db" "$1" <<'PY'
import json, math, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
n = int(sys.argv[2])
ents = [{"id": 2, "parent": 1, "name": "world", "kind": "scene"},
	{"id": 3, "parent": 2, "name": "start", "pos": [0, 1, 0],
		"components": [{"type": "kit/spawner", "params": {"players": True}}]}]
for i in range(n):
	e = 10 + i
	r = 4 + (e % 12) * 2
	ents.append({"id": e, "parent": 2, "name": "crowd %d" % i,
		"pos": [round(r * math.cos(i * 2.4), 2), 1, round(r * math.sin(i * 2.4), 2)],
		"components": [{"type": "kit/creature_walker"},
			{"type": "workbench/crowd", "params": {"name": "c%d" % i}}]})
def put(k, v):
	db.execute("insert or replace into store (store, key, value) values (?, ?, ?)",
		("kit", k, json.dumps(v).encode()))
put("authored", {"kit": 1, "api": 1, "next_id": 10 + n, "entities": ents})
put("session", {"by": "", "restore": [], "round": [], "running": True})
db.execute("delete from store where store = ? and key = ?", ("kit", "runtime"))
db.commit()
PY
}
# "<pid> <bytes received>" of each client's socket to the server
rx()
{
	ss -Htinp state established "( dport = :$SERVER_PORT )" 2>/dev/null |
		python3 -I -c 'import re, sys
for m in re.finditer(r"pid=(\d+).*?bytes_received:(\d+)", sys.stdin.read(), re.S):
	print(m.group(1), m.group(2))'
}
lines() { grep -ac "$2" "$1" 2>/dev/null; }
# Until <log> has <n> lines matching <regex>, up to <seconds>
await_n() # <log> <regex> <n> <seconds>
{
	local i
	for i in $(seq $(($4 * 5))); do
		[ "$(lines "$1" "$2")" -ge "$3" ] && return 0
		kill -0 "$SERVER_PID" 2>/dev/null || fail "the server is gone ($1)"
		sleep 0.2
	done
	fail "no $3 lines \"$2\" in $1 in $4 s"
}

sock=bcrowd-$$
XDG_RUNTIME_DIR=/run/user/$(id -u) weston --backend=headless --renderer=pixman \
	--xwayland --socket=$sock --width=1100 --height=800 --idle-time=0 \
	> "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
d=
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"

: > "$t/table"
fitted=
for N in $COUNTS; do
	B=$((N - C))
	[ "$B" -ge 0 ] || fail "a count under CROWD_CLIENTS ($N)"
	# [CHECK_MEMORY] 2 GB over the server's ~300 MB and ~450 MB a client
	need=$((2048 + 300 + C * 450))
	avail=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
	if [ "$avail" -lt "$need" ]; then
		echo "stopped before $N players: $avail MB free, $need MB wanted"
		break
	fi
	u=$t/n$N
	mkdir -p "$u"
	rows "$B" || fail "the rows ($db)"
	SL=$u/srv.log
	BUILDAT_KIT_METER=1 start_server "$SL" "Hosted: |Not hosted: " 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
		fail "the server did not come up ($SL)"
	SRV=$SERVER_PID
	grep -aq "Not hosted: " "$SL" && fail "not hosted ($SL)"
	code=
	if [ ! -e "$t/admin_made" ]; then
		wait_for_log "$SL" "setup code [A-Z0-9]+" 30
		code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
		[ -n "$code" ] || fail "no setup code ($SL)"
	fi
	cpids=()
	for c in $(seq "$C"); do
		mkfifo "$u/c$c.cmd"
		sleep 900 > "$u/c$c.cmd" &
		CHECK_PIDS+=($!)
		cpids+=($!)
		extra=()
		# (an admin's way in: the setup code, registration opened)
		[ "$c" = 1 ] && [ ! -e "$t/admin_made" ] &&
			extra=(BUILDAT_JOIN_CODE="$code" "BUILDAT_JOIN_ADMIN=setting open_registration on")
		env DISPLAY="$d" WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=crowd$c \
			"${extra[@]}" bin/buildat -C "$t/cc$c" -D "$t/cu$c" \
			-s localhost:$SERVER_PORT -w 640x400 -l 3 -o sound_mute=1 -c - \
			< "$u/c$c.cmd" > "$u/c$c.log" 2>&1 &
		CHECK_PIDS+=($!)
		cpids+=($!)
		[ "$c" = 1 ] && CL1=$!
		wait_for_log "$u/c$c.log" "Joined as crowd$c" 120 ||
			fail "client $c did not join ($u/c$c.log, $SL)"
		if [ "$c" = 1 ] && [ ! -e "$t/admin_made" ]; then
			wait_for_log "$u/c1.log" "admin script: done" 30 ||
				fail "client 1's admin script ($u/c1.log)"
			touch "$t/admin_made"
		fi
	done
	# (the admin's first join: a dialog over the view)
	[ -n "$code" ] && echo 'wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don*"' > "$u/c1.cmd"
	# The others walk: forward and back 1.5 s each, a jump between
	for c in $(seq 2 "$C"); do
		wait_for_log "$u/c$c.log" "player physics enabled" 60 ||
			fail "client $c has no body ($u/c$c.log)"
		for i in $(seq 150); do
			printf 'keydown w\ndelay 1500\nkeyup w\nkeypress Space\nkeydown s\ndelay 1500\nkeyup s\n'
		done > "$u/c$c.cmd" &
		CHECK_PIDS+=($!)
		cpids+=($!)
	done
	# Settled: two meter lines after the last join, then 10 s (two more)
	m0=$(lines "$SL" "kit *: meter:")
	await_n "$SL" "kit *: meter:" $((m0 + 2)) 30
	echo "event kit_looks" > "$u/c1.cmd"
	rx > "$u/rx0"
	s0=$(date +%s%N)
	await_n "$SL" "kit *: meter:" $((m0 + 4)) 30
	echo "event kit_looks" > "$u/c1.cmd"
	rx > "$u/rx1"
	s1=$(date +%s%N)
	await_n "$u/c1.log" "kit: looks:" 2 10
	echo "screenshot $u/crowd.png" > "$u/c1.cmd"
	curl -s "http://127.0.0.1:$SERVER_PORT/health" > "$u/health.json"
	ps -o pid=,rss= -p "$SRV,$CL1" > "$u/rss"
	python3 -I - "$u" "$N" "$B" "$SRV" "$CL1" "$s0" "$s1" "$C" \
			<<'PY' >> "$t/table" || fail "the measures ($u)"
import json, re, sys
from datetime import datetime
u, n, b, srv, cl1, s0, s1, nc = sys.argv[1:]
srv_log = open(u + "/srv.log", errors="replace").read()
m = re.findall(r"meter: \d+ ticks in [0-9.]+ s, gap ([0-9.]+)/([0-9.]+) ms, "
	r"Kit's tick ([0-9.]+)/([0-9.]+) ms, the box ([0-9.]+)/([0-9.]+) %", srv_log)
w = [[float(x) for x in r] for r in m[-2:]]
avg = lambda k: sum(r[k] for r in w) / len(w)
top = lambda k: max(r[k] for r in w)
h = json.load(open(u + "/health.json"))
dt = (int(s1) - int(s0)) / 1e9
a = dict(l.split() for l in open(u + "/rx0"))
z = dict(l.split() for l in open(u + "/rx1"))
rates = [(int(z[p]) - int(a[p])) / dt for p in z if p in a]
rss = dict(l.split() for l in open(u + "/rss"))
looks = [l for l in open(u + "/c1.log", errors="replace") if "kit: looks:" in l]
def stamp(l):
	return datetime.strptime(l.split()[2], "%H:%M:%S.%f")
frames = int(re.search(r"looks: (\d+) frames", looks[1]).group(1))
frame = (stamp(looks[1]) - stamp(looks[0])).total_seconds() * 1000 / max(1, frames)
walks = re.findall(r"crowd at ([-0-9.]+) ([-0-9.]+)", srv_log)
moved = len(set(walks[-4:])) > 1 if int(b) else True
print("%s %s %.1f %.1f %.1f %.1f %.1f %.1f %.1f %.1f %.0f %.0f %.1f %d %d %d %s" % (
	n, b, avg(0), top(1), avg(2), top(3), avg(4), top(5),
	h["tick_gap_ms_avg"], h["tick_gap_ms_max"], min(rates), max(rates), frame,
	int(rss[srv]) // 1024, int(rss[cl1]) // 1024, len(rates), "walked" if moved else "STILL"))
PY
	for p in "${cpids[@]}"; do kill "$p" 2>/dev/null; done
	kill -INT "$SRV" 2>/dev/null
	wait "$SRV" 2>/dev/null
	for p in "${cpids[@]}"; do wait "$p" 2>/dev/null; done
	fitted="$fitted $N"
done
[ -s "$t/table" ] || fail "no count fitted"

# The table, then the limits
python3 -I - "$t/table" <<'PY'
import sys
print("players bots | Kit gap mean/worst ms | Kit's tick mean/worst ms | box mean/worst % | "
	"/health gap mean/worst ms | bytes/s a client min/max | frame ms | RSS server/client MB")
for l in open(sys.argv[1]):
	f = l.split()
	print("%7s %4s | %6s/%-6s | %6s/%-6s | %5s/%-5s | %5s/%-6s | %6s/%-6s | %5s | %s/%s %s" %
		tuple(f[:15] + [f[16]]))
PY
check_slow
python3 -I - "$t/table" "$CHECK_SLOW" <<'PY'
import sys
slow = float(sys.argv[2])
# LIMITS (n players), from the desk's at 20/35/50 (2026-11-20, CHECK_SLOW
# 1.4 beside other work): Kit's tick 17/33/43 ms, the box 9/16/25 %,
# 38/59/71 kB/s a client, a frame 33/53/60 ms (llvmpipe, 640x400). Each
# some 1.6x over them; the times by CHECK_SLOW, the box and the bytes not
# (its units, the game's own). With every drive's track in every step's
# request (before [KIT_CROWD_CHECK]'s tracks_lit()) 20 players read Kit's
# tick 81 ms and the box 52 %, and at 35 the bots stood still.
def limits(n):
	return {"gap": max(45, 1.5 * n) * slow, "tick": 1.5 * n * slow,
		"box": 0.8 * n + 5, "bytes": 2000 * n + 10000, "frame": (2 * n + 20) * slow}
bad = []
for l in open(sys.argv[1]):
	f = l.split()
	n = f[0]
	L = limits(int(n))
	for k, i, what in (("gap", 2, "Kit's tick gap %s ms"), ("tick", 4, "Kit's tick %s ms"),
			("box", 6, "the box %s %% of a tick's budget"),
			("bytes", 11, "%s bytes/s to a client"), ("frame", 12, "a frame %s ms")):
		if float(f[i]) > L[k]:
			bad.append("%s players: %s over %.0f" % (n, what % f[i], L[k]))
	if f[16] != "walked":
		bad.append("%s players: the bots did not walk" % n)
	print("limits at %s: Kit's gap %.0f ms, Kit's tick %.0f ms, the box %.0f %%, "
		"%.0f bytes/s, a frame %.0f ms" % (n, L["gap"], L["tick"], L["box"],
		L["bytes"], L["frame"]))
for b in bad:
	print("over: " + b)
sys.exit(1 if bad else 0)
PY
verdict_keep
[ "$verdict_rc" = 0 ] || fail "a crowd past its limits (the table above; $t)"
echo "PASS: a crowd of$fitted players on one Workbench server within the limits"
