#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-11)
# covers: apps/vanilla/main/main.cpp apps/vanilla/main/client_lua/init.lua builtin/luanti/luanti.cpp builtin/luanti/session.h builtin/luanti/lua/entity.lua
# [JOIN_WHEN_LOADED]: vanilla puts a player in the world only once their
# client has it loaded. Vanilla on the minimal game; a fixture logs the
# connected players whenever they change, which is who another player sees.
#   1. A joins straight to the server and stays; B joins over a link of
#      300 KB/s (util/netsim.py). Each one's join line, and their name among
#      the players, come after their client's luanti:world_in; B placed (its
#      client's "the server put the player at") before that.
#   2. C over the same link leaves once placed, before its world is in: no
#      join, no leave, never among the players.
#   3. luanti_client on a local Luanti server (devtest): the loading panel
#      stays past the registry's "loading done" until the blocks round the
#      player are drawn, and the screen right after is the world.
# simplified: 3 on the direct link; util/netsim.py is TCP and Luanti UDP.
# 3 needs luanti in PATH and devtest in the desk's games, else is skipped.
#   util/join_when_loaded_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp join_when_loaded; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/s
mkdir -p "$d/apps/vanilla/saves/jw/luanti" "$d/shared"
echo "enable_damage = false" > "$d/apps/vanilla/saves/jw/luanti/world.mt"
cat > "$d/shared/fixture.lua" <<'L'
local seen = ""
core.register_globalstep(function()
	local n = {}
	for _, p in ipairs(core.get_connected_players()) do
		n[#n + 1] = p:get_player_name()
	end
	table.sort(n)
	local s = table.concat(n, ",")
	if s ~= seen then
		seen = s
		core.log("action", "jw: players [" .. s .. "]")
	end
end)
L
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=jw \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 60 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
LINK=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$here/util/netsim.py" --listen "$LINK" --to "127.0.0.1:$SERVER_PORT" \
	--delay 0 --rate 2400 > "$t/netsim.log" 2>&1 &
ns=$!
CHECK_PIDS+=($ns)
for i in $(seq 50); do
	grep -aq "netsim: listening" "$t/netsim.log" && break
	kill -0 $ns 2>/dev/null || fail "netsim ($t/netsim.log)"
	sleep 0.2
done
client(){ run_client 60 "$1" timeout 300 "$here/Build/bin/buildat" -C "$t/nc$2" \
	-D "$t/nu$2" -s "127.0.0.1:$3" -w 640x360 -l 3 -o sound_mute=1 -c @"$4"; }

# 1. A's 60 s is staying in while B and C come (killed after them); B's
# 2 s is the server's join after its world_in
printf "wait_log 60000 load: the world is in\ndelay 60000\nquit\n" > "$t/a.cmds"
client "$t/a.log" a "$SERVER_PORT" "$t/a.cmds" &
a=$!
wait_for_log "$t/srv.log" "jw: players \[." 60 || fail "A did not get in ($t/srv.log)"
printf "wait_log 300000 load: the world is in\ndelay 2000\nquit\n" > "$t/b.cmds"
client "$t/b.log" b "$LINK" "$t/b.cmds" || fail "B's run ($t/b.log)"
# 2
printf "wait_log 120000 the server put the player at\nquit\n" > "$t/c.cmds"
client "$t/c.log" c "$LINK" "$t/c.cmds" || fail "C's run ($t/c.log)"
# simplified: 3 s for the server to have taken C's leave; it logs nothing
# for one never joined
sleep 3
kill $a 2>/dev/null; wait $a 2>/dev/null
grep -a "luanti:world_in\|put in\|jw: players\|Player .* \(joined\|left\)" "$t/srv.log" | sed 's/.*\(luanti *: \|ACTION\[[^]]*\]: \)//' | cut -c 1-120
for c in b c; do grep -aq "the server put the player at" "$t/$c.log" || fail "$c not placed ($t/$c.log)"; done
grep -aq "load: the world is in" "$t/c.log" && fail "C's world came in before it left; the link is too fast to test a leave"
python3 - "$t/srv.log" <<'PY' || fail "the joins ($t/srv.log)"
import re, sys
log = open(sys.argv[1], errors="replace").read().splitlines()
ev = []
for l in log:
    m = re.search(r"Client (\d+): luanti:world_in", l)
    if m: ev.append(("in", m.group(1))); continue
    m = re.search(r"Player (\S+) (joined|left)", l)
    if m: ev.append((m.group(2), m.group(1))); continue
    m = re.search(r"jw: players \[(.*)\]", l)
    if m: ev.append(("players", m.group(1))); continue
    if "no luanti:world_in" in l: ev.append(("limit", l))
print(ev)
assert not [e for e in ev if e[0] == "limit"], "a client put in by the limit"
ins = [i for i, e in enumerate(ev) if e[0] == "in"]
joins = [i for i, e in enumerate(ev) if e[0] == "joined"]
assert len(ins) == 2 and len(joins) == 2, "%d world_in, %d joins" % (len(ins), len(joins))
for i, j in zip(ins, joins):
    assert i < j, "a join before its world_in"
    name = ev[j][1]
    first = [k for k, e in enumerate(ev) if e[0] == "players" and name in e[1].split(",")][0]
    assert first > i, "%s among the players before its world_in" % name
names = {ev[j][1] for j in joins}
left = [e[1] for e in ev if e[0] == "left"]
assert set(left) <= names, "a leave of one never in: %s" % left
assert max(len(e[1].split(",")) for e in ev if e[0] == "players" and e[1]) <= 2, "three players"
print("joined after world_in: " + ", ".join(sorted(names)))
PY
echo "ok: vanilla"

# 3
G="$BUILDAT_USER_PATH/shared/vanilla/games/devtest"
if [ ! -d "$G" ] || ! command -v luanti > /dev/null; then
	echo "SKIP 3: no devtest or no luanti"
else
	mkdir -p "$t/lg" "$t/lw" "$t/lc"
	cp -r "$G" "$t/lg/"
	printf 'gameid = devtest\nbackend = sqlite3\n' > "$t/lw/world.mt"
	P=$(python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
	LUANTI_GAME_PATH="$t/lg" luanti --server --world "$t/lw" --port "$P" > "$t/luanti.log" 2>&1 &
	CHECK_PIDS+=($!)
	wait_for_log "$t/luanti.log" "listening on" 60 || fail "the Luanti server ($t/luanti.log)"
	now=$(date +%s)
	echo "\"true\",\"udp://127.0.0.1:$P\",\"\",\"$now\",\"$now\",\"\",\"\",\"\"" \
		> "$t/lc/network_addresses.csv"
	printf 'wait_log 60000 loading: the world is in\ndelay 300\nscreenshot %s\nquit\n' \
		"$t/lc.png" > "$t/lc.cmds"
	BUILDAT_LUANTI_ADDRESS=127.0.0.1:$P BUILDAT_LUANTI_CONNECT=1 BUILDAT_LUANTI_NAME=jwl \
		run_client 60 "$t/lc.log" timeout 120 "$here/Build/bin/buildat" -m luanti_client \
		-D "$t/lc" -w 640x360 -l 3 -o sound_mute=1 -c @"$t/lc.cmds" ||
		fail "luanti_client's run ($t/lc.log)"
	grep -a "luanti_c: loading done\|loading: the world is in" "$t/lc.log" | cut -c 12-
	sed -n '/luanti_c: loading done/,$p' "$t/lc.log" |
		grep -aq "loading: the world is in, drawn round the player" ||
		fail "the panel did not wait for the world ($t/lc.log)"
	python3 - "$t/lc.png" <<'PY' || fail "the panel still up ($t/lc.png)"
import sys
import numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
panel = (np.abs(a - [15, 18, 23]).max(axis=2) <= 4).mean()
print("the panel's colour on %.0f%% of the screen" % (panel * 100))
assert panel < 0.3
PY
fi
echo "PASS: vanilla puts a player in the world on their client's luanti:world_in, a slow link's too; one who leaves while loading leaves no trace; luanti_client's panel stays until the world round the player is drawn"
