#!/bin/bash
# tier: full
# cost: ~2.5 min (2026-10-12)
# covers: builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua builtin/luanti/client_lua/module.lua client/api.lua
# [VIEW_SETTINGS_LOCAL]: the render mode in vanilla's View settings.
#   1. A launcher's game (save vs, the minimal game), settings.json saying
#      pbr and a stale view_render_mode of unlit in the game's storage:
#      drawn pbr; View's render mode to shadows, then to unlit: each a
#      rejoin through the launcher, drawn in that mode, settings.json
#      holding it, the other rows kept.
#   2. A server the launcher did not start, its settings.json shadows,
#      joined through the connect screen: render mode to unlit rejoins it
#      at the same address, drawn unlit; its settings.json untouched.
# simplified: native only; the three-row walk is vanilla_player_settings_check's.
#   util/view_settings_local_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp view_settings_local; t=$CHECK_TMP
d=$t/u
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=vs start_server "$t/mk.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$t/c" -l 3 || fail "vs ($t/mk.log)"
for _i in $(seq 300); do
	grep -aq "The world is up" "$t/mk.log" && break
	kill -0 "$SERVER_PID" 2>/dev/null || break
	sleep 0.2
done
grep -aq "The world is up" "$t/mk.log" || fail "vs not up ($t/mk.log)"
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
echo "enable_damage = false" >> "$d/apps/vanilla/saves/vs/luanti/world.mt"
F=$d/shared/vanilla/settings.json
echo '{"render_mode": "pbr", "view_range": "90", "distant_detail": "half"}' > "$F"
mkdir -p "$d/apps/vanilla/client"
printf unlit > "$d/apps/vanilla/client/view_render_mode"
# mode <m>: View's render mode one step down, from the pause menu (at
# 1100x600, the row vanilla_player_settings_check found); 15 s in the
# game after, past the old server's 10 s stop ([REJOIN_KILLS_SERVER]).
# The 500 ms after the drop-down's click is its list opening: nothing
# logs it
mode(){ printf 'keypress Escape\nwait_log 5000 pause: the menu shown\ndelay 500\nclick Button "Settings..."\nwait_log 5000 Game settings shown\ndelay 1000\nclick DropDownList "▼" 668 120\ndelay 500\nkeypress Down\nkeypress Return\nwait_log 60000 drawing the world %s\ndelay 15000\n' "$1"; }
json(){ python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$F" "$1"; }

# 1.
{
	printf 'wait_log_any 20000 , first vs\nframes 3\nclick Text "vs"\n'
	printf 'wait_log 60000 load: the world is in\ndelay 1500\n'
	mode shadows; mode unlit; echo quit
} > "$t/1.cmds"
timeout 400 "$here/Build/bin/buildat" -o launch_ui=launch_menu -D "$d" -C "$t/c1" \
	-w 1100x600 -l 3 -o sound_mute=1 -c @"$t/1.cmds" > "$t/1.log" 2>&1
# The quit stops the last server; a kill or a disconnect before it is a
# rejoin's
sed '/Command sequence complete/q' "$t/1.log" |
	grep -a "did not stop in 10 s\|SIGKILL\|Disconnected from server" &&
	fail "a rejoin's server killed or left ($t/1.log)"
for p in $(pgrep -f "[b]uildat_server .*-D $d"); do kill $p; done
grep -a "luanti:world_info: \|view: \|Starting local server\|Command sequence" "$t/1.log" | cut -c1-160
grep -aq "Command sequence complete" "$t/1.log" || fail "the drive ($t/1.log)"
# Each session's mode, said once by its world_info
modes(){ grep -a "luanti:world_info: " "$1" | sed 's/.*, //' | tr '\n' ' '; }
[ "$(modes "$t/1.log")" = "pbr shadows unlit " ] ||
	fail "not drawn pbr, shadows, unlit ($t/1.log)"
[ "$(grep -ac "Starting local server" "$t/1.log")" = 3 ] || fail "not three launches ($t/1.log)"
[ "$(json render_mode)" = unlit ] || fail "settings.json: $(cat "$F")"
[ "$(json view_range)" = 90 ] && [ "$(json distant_detail)" = half ] ||
	fail "the other rows not kept: $(cat "$F")"
echo "ok: a launcher's game: settings.json's mode over a stale stored one; shadows and unlit each a relaunch, written to settings.json"

# 2. The second server's own user path and settings.json
s=$t/s
mkdir -p "$s/apps/vanilla/saves/rs/luanti" "$s/shared/vanilla"
echo "enable_damage = false" > "$s/apps/vanilla/saves/rs/luanti/world.mt"
G=$s/shared/vanilla/settings.json
echo '{"render_mode": "shadows"}' > "$G"
sum=$(md5sum < "$G")
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=rs start_server "$t/s2.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$s" -C "$t/c2s" -l 3 ||
	fail "the server ($t/s2.log)"
CHECK_PIDS+=($SERVER_PID)
# Through the connect screen, which the rejoin comes back to; shadows,
# Down, is unlit
{
	printf 'wait_log_any 30000 Join a Buildat server: shown\ndelay 500\nclick LineEdit "29500"\ndelay 300\nkeypress End\n'
	printf 'keypress Backspace\n%.0s' 1 2 3 4 5
	printf 'text %s\ndelay 300\nclick Button "Join"\n' $SERVER_PORT
	printf 'wait_log 60000 load: the world is in\ndelay 1500\n'
	mode unlit; echo quit
} > "$t/2.cmds"
timeout 300 "$here/Build/bin/buildat" -o launch_ui=launch_menu -a extension/launch_menu/connect \
	-D "$t/u2" -C "$t/c2" -w 1100x600 -u 1 -l 3 -o sound_mute=1 -c @"$t/2.cmds" > "$t/2.log" 2>&1
grep -a "luanti:world_info: \|view: \|reconnect\|Command sequence" "$t/2.log" | cut -c1-160
grep -aq "Command sequence complete" "$t/2.log" || fail "the drive ($t/2.log)"
grep -aq "reconnect: joined [a-z0-9.]*:$SERVER_PORT" "$t/2.log" || fail "not rejoined ($t/2.log)"
[ "$(modes "$t/2.log")" = "shadows unlit " ] ||
	fail "not drawn shadows, then unlit ($t/2.log)"
[ "$(md5sum < "$G")" = "$sum" ] || fail "the server's settings.json changed"
echo "PASS: the render mode rejoins in it: a launcher's game through settings.json, another server through the client's own choice"
