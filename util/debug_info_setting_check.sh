#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-11)
# covers: builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua extensions/luanti_client/init.lua extensions/luanti_client/settings.lua
# [DEBUG_INFO_SETTING]: the F5 info's level is a setting, kept.
# Vanilla on the minimal game, one client's three runs:
#   1. at start Basic (the default); the settings' "Debug info (F5)" set
#      to Full;
#   2. at start Full; F5 cycles it to Off;
#   3. at start Off, and the dropdown reads Off (a screenshot).
# luanti_client on official Luanti's devtest (skipped without them):
# Off at start, F5 twice; Full at the next start, F5 once; Off at the
# third, and its settings.json says 0.
# simplified: luanti_client's settings screen row is not driven, and its
# level is read at the extension's load, not each session
#   util/debug_info_setting_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp debug_info_setting; t=$CHECK_TMP
lsrv=
trap '[ -n "$lsrv" ] && kill $lsrv 2>/dev/null; check_cleanup' EXIT
at_start(){ grep -a "debug info at start: " "$1" | tail -1 | sed 's/.*at start: //'; }

# Vanilla
mkdir -p "$t/v/apps/vanilla/saves/di/luanti"
echo "enable_damage = false" > "$t/v/apps/vanilla/saves/di/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=di start_server "$t/v.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/v" -C "$t/vc" -l 3 ||
	fail "the server ($t/v.log)"
CHECK_PIDS+=($SERVER_PID)
client(){ run_client 60 "$1" timeout 200 "$here/Build/bin/buildat" -C "$t/nc" \
	-D "$t/nu" -s "127.0.0.1:$SERVER_PORT" -w 1100x600 -u 1 -l 3 \
	-o sound_mute=1 -c @"$2"; }
# The delays: a screen a line says is up laid out in the frames after it,
# and the dropdown's list after its click
settings='wait_log 120000 load: the world is in
delay 1000
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Settings..."
wait_log 5000 Game settings shown
delay 1000'
printf '%s\nclick DropDownList "▼" 668 256\ndelay 500\nkeypress Down\nkeypress Return\nwait_log 5000 debug info:\nquit\n' \
	"$settings" > "$t/1.cmds"
client "$t/1.log" "$t/1.cmds"
printf 'wait_log 120000 load: the world is in\ndelay 1000\nkeypress F5\nwait_log 5000 debug info:\nquit\n' > "$t/2.cmds"
client "$t/2.log" "$t/2.cmds"
printf '%s\nscreenshot %s\nquit\n' "$settings" "$t/3.png" > "$t/3.cmds"
client "$t/3.log" "$t/3.cmds"
grep -a "Command sequence failed" "$t"/[123].log && fail "a drive"
echo "vanilla at start: $(at_start "$t/1.log"), $(at_start "$t/2.log"), $(at_start "$t/3.log")"
[ "$(at_start "$t/1.log") $(at_start "$t/2.log") $(at_start "$t/3.log")" = "1 2 0" ] ||
	fail "vanilla's levels ($t/1.log ...)"
grep -aq "vanilla : debug info: 2" "$t/1.log" || fail "the dropdown did not set Full ($t/1.log)"
echo "ok: vanilla"

# luanti_client
G="$BUILDAT_USER_PATH/shared/vanilla/games/devtest"
if ! command -v luanti > /dev/null || [ ! -d "$G" ]; then
	echo "PASS (vanilla; luanti_client SKIPPED: no luanti or devtest)"
	exit 0
fi
mkdir -p "$t/games" "$t/w"
cp -r "$G" "$t/games/"
printf 'gameid = devtest\nbackend = sqlite3\n' > "$t/w/world.mt"
P=$((30200 + RANDOM % 300))
LUANTI_GAME_PATH="$t/games" MINETEST_GAME_PATH="$t/games" \
	luanti --server --world "$t/w" --port $P > "$t/l.log" 2>&1 &
lsrv=$!
for _ in $(seq 60); do
	grep -q "listening on" "$t/l.log" && break
	kill -0 $lsrv 2>/dev/null || fail "luanti died ($(tail -3 "$t/l.log"))"
	sleep 0.5
done
mkdir -p "$t/lcl"
now=$(date +%s)
echo "\"true\",\"udp://127.0.0.1:$P\",\"\",\"$now\",\"$now\",\"\",\"\",\"\"" \
	> "$t/lcl/network_addresses.csv"
lc(){ # log, F5 presses
	# A settle after the line: the world's keys taken in the frames after
	{ echo "wait_log 60000 loading done"; echo "delay 1000"
		for _ in $(seq "$2"); do echo "keypress F5"; echo "wait_log 5000 debug info:"; done
		echo quit; } > "$t/lc.cmds"
	(cd "$here/Build" && BUILDAT_LUANTI_ADDRESS=127.0.0.1:$P BUILDAT_LUANTI_CONNECT=1 \
		BUILDAT_LUANTI_NAME=dicheck timeout 120 bin/buildat -m luanti_client \
		-D "$t/lcl" -w 800x600 -l 3 -o sound_mute=1 -c @"$t/lc.cmds" > "$1" 2>&1) ||
		fail "the drive ($1): $(grep -a "Command sequence failed" "$1" | tail -1)"
}
lc "$t/lc1.log" 2
lc "$t/lc2.log" 1
lc "$t/lc3.log" 0
echo "luanti_client at start: $(at_start "$t/lc1.log"), $(at_start "$t/lc2.log"), $(at_start "$t/lc3.log")"
[ "$(at_start "$t/lc1.log") $(at_start "$t/lc2.log") $(at_start "$t/lc3.log")" = "0 2 0" ] ||
	fail "luanti_client's levels ($t/lc1.log ...)"
grep -q '"debug_info" *: *0' $(find "$t/lcl" -name settings.json | head -1) ||
	fail "settings.json: $(find "$t/lcl" -name settings.json)"
echo "PASS: the F5 info's level kept in vanilla's and luanti_client's settings, F5's and the dropdown's"
