#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-12)
# covers: src/impl/packet_stream.cpp src/client/state.cpp src/client/app_lua.h apps/vanilla/main/client_lua/init.lua
# [LOAD_IN_FLIGHT]: the loading screen's second stripe says what is
# arriving when nothing has been whole for half a second.
#   1. Vanilla on VoxeLibre over a 3 MB/s link (util/netsim.py): "load:
#      last flight voxelworld:voxel_registry" lines with its bytes growing,
#      and lines of what is whole again after them.
#   2. The minimal game, joined directly: no flight line.
# simplified: native only; the web's socket feeds the same buffer
# (state.cpp's read_socket()).
# Needs mineclone2 in the desk's games.
#   util/load_in_flight_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || skip "no mineclone2"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp load_in_flight; t=$CHECK_TMP
serve(){ # game save
	mkdir -p "$t/$2/apps/vanilla/saves/$2/luanti" "$t/$2/shared/vanilla/games"
	[ "$1" = minimal ] || cp -r "$G" "$t/$2/shared/vanilla/games/"
	echo "enable_damage = false" > "$t/$2/apps/vanilla/saves/$2/luanti/world.mt"
	BUILDAT_LUANTI_GAME=$1 BUILDAT_LUANTI_SAVE=$2 start_server "$t/$2.srv.log" \
		"STATUS Listening" 180 auto "$here/Build/bin/buildat_server" -u launcher=1 \
		-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/$2" -C "$t/$2.cache" -l 3 ||
		fail "the $1 server ($t/$2.srv.log)"
	CHECK_PIDS+=($SERVER_PID)
}
printf "wait_log 300000 load: the world is in\nquit\n" > "$t/cmds"
client(){ run_client 60 "$1" timeout 400 "$here/Build/bin/buildat" -C "$t/$2.c" \
	-D "$t/$2.u" -w 800x450 -l 3 -o sound_mute=1 -s "$3" -c @"$t/cmds"; }

# 1.
serve mineclone2 vl
LINK=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$here/util/netsim.py" --listen "$LINK" --to "127.0.0.1:$SERVER_PORT" \
	--delay 0 --rate 24000 > "$t/netsim.log" 2>&1 &
CHECK_PIDS+=($!)
sleep 1
client "$t/vl.log" vl "127.0.0.1:$LINK"
grep -aq "load: the world is in" "$t/vl.log" || fail "VoxeLibre not loaded ($t/vl.log)"
grep -a "vanilla : load: last" "$t/vl.log" | sed 's/.*load: last //' | uniq -c | cut -c1-120 | head -20
python3 - "$t/vl.log" <<'PY' || fail "the registry in flight ($t/vl.log)"
import re, sys
lines = [l.split("load: last ", 1)[1].strip()
         for l in open(sys.argv[1], errors="replace") if "vanilla : load: last " in l]
reg = [(i, float(m.group(1))) for i, l in enumerate(lines)
       for m in [re.match(r"flight voxelworld:voxel_registry  ([0-9.]+) of", l)] if m]
assert len(reg) >= 2, "%d registry lines" % len(reg)
mb = [v for _, v in reg]
assert mb == sorted(mb) and mb[-1] > mb[0], "not growing: %s" % mb
assert any(not l.startswith("flight") for l in lines[reg[-1][0] + 1:]), "nothing whole after it"
print("ok: the registry in flight on %d lines, %.1f to %.1f MB" % (len(mb), mb[0], mb[-1]))
PY

# 2.
serve minimal mn
client "$t/mn.log" mn "127.0.0.1:$SERVER_PORT"
grep -aq "load: the world is in" "$t/mn.log" || fail "minimal not loaded ($t/mn.log)"
grep -a "vanilla : load: last flight" "$t/mn.log" && fail "a flight line on a small world ($t/mn.log)"
echo "PASS: a large packet arriving is said with its bytes, a small world's join says none"
