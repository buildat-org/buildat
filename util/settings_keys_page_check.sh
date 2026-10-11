#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-11)
# covers: extensions/launch_menu/preferences.lua extensions/launch_menu/init.lua extensions/ui_utils/init.lua client/api.lua apps/vanilla/main/client_lua/pause.lua apps/vanilla/main/client_lua/menu.lua
# [SETTINGS_KEYS_PAGE]: the keys on a page of their own, one code for the
# launcher's Keys screen and a game's settings window.
#   1. The launcher's Keys screen: a row picked by the keys, then the
#      wheel over the list: the view moves and the selection stays; ten
#      rows down, a row reset, rebound by Enter and a key, and reset
#      again: the view and the selection the same through all three.
#   2. Vanilla's Luanti settings: "Key bindings..." opens the page with
#      the game's actions and the client's two only, a key rebound there,
#      and Back is on Luanti settings again.
#   3. Vanilla in a world (the minimal game): the pause menu has no "Key
#      bindings"; Settings... has no key rows, its "Key bindings..." opens
#      the page, a key rebound, put back by Backspace and rebound again;
#      Escape is on the settings page, Escape again closes it, and the
#      new key works in the game.
#   util/settings_keys_page_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp settings_keys_page; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"
client(){ timeout 240 bin/buildat -o launch_ui=launch_menu -w 1100x600 -u 1 -l 3 -o sound_mute=1 "$@"; }
# The page's log lines of one run: "<what>; the view at N, <row> selected"
lines(){ grep -a "$1: .*; the view at" "$2" | sed 's/.*: \([^:]*; the view at.*\)/\1/'; }

# 1
{
	echo "wait_log 60000 rows in"; echo "delay 1500"
	echo 'click Button "Settings"'; echo "delay 800"
	echo 'click Button "Keys"'; echo "wait_log 5000 launch_menu: keys,"
	echo "delay 500"; echo "mouse_pos 500 400"; echo "delay 500"
	echo "keypress Down"; echo "keypress Down"; echo "keypress Backspace"
	echo "delay 300"
	for _ in 1 2 3 4; do echo "mouse_wheel -1"; done
	echo "delay 300"; echo "keypress Backspace"; echo "delay 300"
	for _ in $(seq 10); do echo "keypress Down"; done
	echo "delay 300"; echo "keypress Backspace"; echo "delay 300"
	echo "keypress Return"; echo "delay 200"; echo "keypress K"; echo "delay 300"
	echo "keypress Backspace"; echo "delay 300"
	echo "screenshot $t/launcher.png"; echo quit
} > "$t/l.cmds"
client -C "$t/lc" -D "$t/lu" -c @"$t/l.cmds" > "$t/l.log" 2>&1
lines launch_menu "$t/l.log" > "$t/l.lines"
cat "$t/l.lines"
python3 - "$t/l.lines" <<'PY' || fail "the launcher's Keys screen ($t/l.log)"
import re, sys
rows = [re.match(r"(.*?) (reset|= K); the view at (\d+), (.*) selected$", l.strip())
        for l in open(sys.argv[1])]
assert len(rows) == 5 and all(rows), "%d lines, not 5" % len(rows)
v = [int(r.group(3)) for r in rows]
sel = [r.group(4) for r in rows]
assert v[1] > v[0] and sel[1] == sel[0], "the wheel: %s" % rows[:2]
assert v[2] == v[3] == v[4] and sel[2] == sel[3] == sel[4] and \
    rows[3].group(2) == "= K", "a key bound moved the page: %s" % rows[2:]
print("the wheel moved the view and not the selection; a key bound and reset kept both")
PY

# 2: Luanti settings, the client starting vanilla's server
cat > "$t/s.cmds" <<C
wait_log 120000 Key bindings...
delay 1000
click Button "Key bindings..."
wait_log 5000 Game keys shown
delay 500
click Button "Fly mode on and off"
delay 300
keypress L
delay 300
screenshot $t/luanti_settings_keys.png
keypress Escape
wait_log 5000 Game keys closed
delay 1500
screenshot $t/luanti_settings.png
quit
C
client -C "$t/sc" -D "$t/su" -a app/vanilla/settings -l 4 -c @"$t/s.cmds" > "$t/s.log" 2>&1
grep -a "Game keys shown\|Game keys: " "$t/s.log" | cut -c 30-
grep -aq "Game keys shown: [0-9]* rows under Luanti *(app/vanilla), This client's$" "$t/s.log" ||
	fail "Luanti settings' page is not the game's alone ($t/s.log)"
grep -aq "Game keys: Fly mode on and off = L;" "$t/s.log" ||
	fail "no key rebound in Luanti settings ($t/s.log)"
# Back: Luanti settings drawn again, from the server's answer
sed -n '/Game keys closed/,$p' "$t/s.log" | grep -aq "UIStack:push(): .*vanilla menu: Luanti settings" ||
	fail "Back is not on Luanti settings ($t/s.log)"

# 3
mkdir -p "$t/vu/apps/vanilla/saves/kp/luanti"
echo "enable_damage = false" > "$t/vu/apps/vanilla/saves/kp/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=kp start_server "$t/v.log" \
	"STATUS Listening" 120 auto bin/buildat_server -u launcher=1 -A 127.0.0.1 \
	-m ../apps/vanilla -D "$t/vu" -C "$t/vc" -l 3 || fail "the vanilla server ($t/v.log)"
CHECK_PIDS+=($SERVER_PID)
cat > "$t/v.cmds" <<C
wait_log 120000 the server put the player at
delay 8000
keypress Escape
delay 1500
screenshot $t/pause.png
click Button "Settings..."
wait_log 5000 Game settings shown
delay 1000
screenshot $t/settings.png
mouse_pos 550 300
$(for _ in $(seq 10); do echo "mouse_wheel -1"; done)
delay 500
click Button "Key bindings..."
wait_log 5000 Game keys shown
delay 500
mouse_pos 550 300
$(for _ in $(seq 20); do echo "mouse_wheel -1"; done)
delay 500
click Button "The line of detail on and off"
delay 300
keypress N
delay 300
keypress Backspace
delay 300
keypress Return
delay 200
keypress N
delay 300
screenshot $t/keys.png
keypress Escape
wait_log 5000 Game keys closed
delay 500
screenshot $t/settings_back.png
keypress Escape
delay 1500
keypress Escape
delay 1500
keypress N
delay 1000
quit
C
client -C "$t/vcc" -D "$t/vcu" -s 127.0.0.1:"$SERVER_PORT" -l 4 -c @"$t/v.cmds" > "$t/vc.log" 2>&1
grep -a "Game keys\|Game settings shown" "$t/vc.log" | cut -c 30- | cut -c 1-200
grep -a "Command sequence failed" "$t/vc.log" && fail "the drive ($t/vc.log)"
grep -a "keyboard_page: .*Continue playing" "$t/vc.log" | grep -aq "Key bindings" &&
	fail "the pause menu has its own Key bindings ($t/vc.log)"
grep -aq "Game settings shown: View, Sound, .*, [1-9][0-9]* of the game's keys" "$t/vc.log" ||
	fail "the settings window ($t/vc.log)"
lines "Game keys" "$t/vc.log" > "$t/v.lines"
python3 - "$t/v.lines" <<'PY' || fail "the game's keys page ($t/vc.log)"
import sys
l = [x.strip() for x in open(sys.argv[1])]
want = ["The line of detail on and off = N", "The line of detail on and off reset",
        "The line of detail on and off = N"]
assert [x.split(";")[0] for x in l] == want, l
assert len(set(x.split(";")[1] for x in l)) == 1, "the page moved: %s" % l
print("rebound, reset and rebound in place")
PY
grep -aq "Game keys shown: [0-9]* rows under Luanti *(server/[^,]*), This client's$" "$t/vc.log" ||
	fail "the page has more than the game's keys ($t/vc.log)"
# The new key in the game: F5's line, after the window closed
sed -n '/Game keys closed/,$p' "$t/vc.log" | grep -aq "vanilla : b/.*| step:" ||
	fail "N did not show the line of detail ($t/vc.log)"
echo "PASS: the launcher's Keys keep the view and selection through the wheel and a rebinding; vanilla's Luanti settings and pause menu Settings open the game's keys page, a key rebound there works in the game"
