#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-12)
# covers: extensions/launch_menu/init.lua client/launch_grid.lua client/api.lua apps/vanilla/launcher/init.lua apps/vanilla/main/client_lua/menu.lua
# [SAVE_CONTEXT_MENU]: an app's actions on a save, in the launcher's Saves.
# The minimal game's save alpha:
#   1. Saves: World options... in alpha's panel; its row right-clicked: a menu with Continue, World
#      options... and Cancel; World options...: vanilla's worlds screen
#      with alpha selected;
#   2. by finger (BUILDAT_TOUCH=1): the row held 0.8 s: the same menu;
#   3. no "World options..." tile among the apps.
#   util/save_context_menu_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp save_context_menu; t=$CHECK_TMP
d=$t/u
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=alpha start_server "$t/mk.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$t/c" -l 3 ||
	fail "alpha ($t/mk.log)"
wait_for_log "$t/mk.log" "The world is up" 60 || fail "alpha not up ($t/mk.log)"
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null

saves="wait_log_any 20000 , first alpha
delay 1500
event scan 1 home
click Button \"Saves*\"
wait_log 5000 launch_menu: save,
delay 300
event scan 1 saves"
# drive <n> <commands> [env]
drive(){
	printf "%s\nquit\n" "$2" > "$t/$1.cmds"
	env ${3:-} timeout 300 "$here/Build/bin/buildat" -o launch_ui=launch_menu -D "$d" \
		-C "$t/c$1" -w 1100x800 -l 3 -o sound_mute=1 -c @"$t/$1.cmds" > "$t/$1.log" 2>&1
	for p in $(pgrep -f "[b]uildat_server .*-D $d"); do kill $p; done
	grep -aq "Command sequence complete" "$t/$1.log" || fail "drive $1 ($t/$1.log)"
}
# row_at <n>: the middle of alpha's row in drive n's Saves (the screen's
# pixels; a finger's UI is larger)
row_at(){
	python3 - "$t/$1.log" <<'PY' || fail "alpha's row not found ($t/$1.log)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
r = re.findall(r'scan saves: ui +Text at (\d+),(\d+) size (\d+)x(\d+) text "alpha"', log)
assert r, "no alpha row"
x, y, w, h = map(int, r[0])
print(x + w // 2, y + h // 2)
PY
}
drive 0 "$saves"
at=$(row_at 0) || exit 1
drive 3 "$saves" BUILDAT_TOUCH=1
touch_at=$(row_at 3) || exit 1
echo "alpha's row at $at, by finger at $touch_at"
drive 1 "$saves
mouse_pos $at
# The cursor moved is read in the frame after, then the click
delay 300
mouse_click right
wait_log 5000 launch_menu: the actions of alpha
delay 300
event scan 1 menu
click Button \"World options...\"
wait_log 120000 menu: the world alpha selected for its options"
drive 2 "$saves
finger_down 1 $touch_at
wait_log 5000 launch_menu: the actions of alpha
finger_up 1
# A settle after the line: the release read, the menu still up, in the
# frames after
delay 300
event scan 1 menu" BUILDAT_TOUCH=1
python3 - "$t/0.log" "$t/1.log" "$t/2.log" <<'PY' || fail "the menus ($t/0.log $t/1.log $t/2.log)"
import sys
logs = [open(f, errors="replace").read() for f in sys.argv[1:]]
def has(log, label, text):
    return any('scan %s: ui' % label in l and 'text "%s"' % text in l for l in log.splitlines())
assert not has(logs[0], "home", "World options..."), "a World options... tile"
assert has(logs[0], "saves", "World options..."), "not in alpha's panel"
for i in (1, 2):
    for want in ("Continue", "World options...", "Cancel"):
        assert has(logs[i], "menu", want), "drive %d: no %s" % (i, want)
print("ok: the menu by right click and by finger; World options... opened alpha's")
PY
echo "PASS: a save's actions by right click and long press, World options... on it"
