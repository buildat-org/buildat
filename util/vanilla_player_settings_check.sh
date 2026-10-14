#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-11)
# covers: builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua builtin/luanti/client_lua/module.lua
# [VANILLA_PLAYER_SETTINGS]: the player's own view settings on a server they
# joined directly. Vanilla on the minimal game, the server's settings.json
# saying shadows and distant detail reduced past half:
#   1. client A: the pause menu's Settings... has a View section; render
#      mode to unlit, distant detail to a third, bobbing off, the shoulder
#      on -- each applied at once (the log);
#   2. client A again: drawing the world unlit, and its own four;
#   3. client B, nothing chosen: the file's values;
# and settings.json unchanged throughout.
# simplified: native only; the web client draws the same script.
#   util/vanilla_player_settings_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp vanilla_player_settings; t=$CHECK_TMP
trap check_cleanup EXIT
mkdir -p "$t/srv/apps/vanilla/saves/vp/luanti" "$t/srv/shared/vanilla"
echo "enable_damage = false" > "$t/srv/apps/vanilla/saves/vp/luanti/world.mt"
F=$t/srv/shared/vanilla/settings.json
echo '{"render_mode": "shadows", "distant_detail": "half"}' > "$F"
sum=$(md5sum < "$F")
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=vp start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client(){ run_client 60 "$1" timeout 200 "$here/Build/bin/buildat" -C "$t/$2c" \
	-D "$t/$2u" -s "127.0.0.1:$SERVER_PORT" -w 1100x600 -u 1 -l 3 \
	-o sound_mute=1 -c @"$3" ||
	fail "the drive ($1): $(grep -a "Command sequence failed\|run_client:" "$1" | tail -1 | cut -c 1-300)"; }
# view <log>: the "view settings" line's values
view(){ grep -a "view settings: " "$1" | tail -1 | sed 's/.*view settings: //'; }

# 1: the four rows, at the window's top, each one step on and waited for
# by its line; a click on one waits for ui_utils' "dropdown_<n> open"
{
	echo "wait_log 60000 load: the world is in"; echo "delay 500"
	echo "keypress Escape"; echo "wait_log 5000 pause: the menu shown"
	echo 'click Button "Settings..."'; echo "wait_log 5000 Game settings shown"
	echo "delay 1000"
	for row in "120 Down view: render_mode = " "154 Down distant terrain: " \
			"188 Up view: view_bobbing_amount = " "222 Down view: third_person_shoulder = "; do
		set -- $row
		echo "click DropDownList \"▼\" 668 $1"; echo "wait_log 5000 dropdown_"
		echo "keypress $2"; echo "keypress Return"; shift 2; echo "wait_log 5000 $*"
	done
	echo "screenshot $t/view.png"; echo quit
} > "$t/1.cmds"
client "$t/1.log" a "$t/1.cmds"
grep -a "Command sequence failed" "$t/1.log" && fail "the drive ($t/1.log)"
grep -a "Game settings shown\|vanilla : view: \|distant terrain" "$t/1.log" | cut -c 30- | cut -c 1-120
grep -aq "Game settings shown: View, Sound" "$t/1.log" || fail "no View section ($t/1.log)"
for want in "view: render_mode = unlit" "distant terrain: third" \
		"view: view_bobbing_amount = 0" "view: third_person_shoulder = 1"; do
	grep -aq "vanilla : $want" "$t/1.log" || fail "not applied: $want ($t/1.log)"
done

# 2 and 3
printf "wait_log 60000 load: the world is in\nwait_log_any 30000 luanti:world_info: \ndelay 1000\nquit\n" > "$t/j.cmds"
client "$t/2.log" a "$t/j.cmds"
client "$t/3.log" b "$t/j.cmds"
echo "A again: $(view "$t/2.log")"
echo "B: $(view "$t/3.log")"
[ "$(view "$t/2.log")" = "render unlit, distant third, bobbing 0, shoulder 1" ] ||
	fail "A's own settings ($t/2.log)"
grep -aq "drawing the world unlit" "$t/2.log" || fail "A not drawn unlit ($t/2.log)"
[ "$(view "$t/3.log")" = "render shadows, distant half, bobbing 1, shoulder 0" ] ||
	fail "B not on the file's ($t/3.log)"
grep -aq "drawing the world shadows" "$t/3.log" || fail "B not drawn shadows ($t/3.log)"
[ "$(md5sum < "$F")" = "$sum" ] || fail "settings.json changed"
echo "PASS: a player's own view settings apply at once and at the next join; another player gets the server's"
