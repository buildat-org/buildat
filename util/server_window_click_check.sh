#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-11)
# covers: apps/vanilla/main/client_lua/pause.lua builtin/accounts/client_lua/accounts.lua
# [SERVER_WINDOW_CLICK]: the Server window opened from vanilla's Settings
# stays open for a click inside it. Vanilla on the minimal game, natively,
# at UI size automatic and 150 %: pause menu, Settings..., scrolled,
# Server...; a click on the sidebar's "Open to LAN" and "Account" and one
# on the page: Settings not shown again; a click far off the window:
# Settings back.
#   util/server_window_click_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp server_window_click; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"
mkdir -p "$t/uv/apps/vanilla/saves/sw/luanti"
echo "enable_damage = false" > "$t/uv/apps/vanilla/saves/sw/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=sw start_server "$t/v.log" \
	"STATUS Listening" 120 auto bin/buildat_server -u launcher=1 -A 127.0.0.1 \
	-m ../apps/vanilla -D "$t/uv" -C "$t/cv" -l 3 ||
	fail "the vanilla server did not start ($t/v.log)"
CHECK_PIDS+=($SERVER_PID)
for size in auto 1.5; do
	cat > "$t/$size.cmds" <<C
wait_log 120000 the server put the player at
delay 8000
keypress Escape
delay 1500
click Button "Settings..."
wait_log 5000 Game settings shown
delay 1000
mouse_pos 550 500
$(for _ in $(seq 30); do echo "mouse_wheel -1"; done)
delay 500
click Button "Server..."
delay 1500
click Button "Open to LAN"
delay 1000
click Button "Account"
delay 1000
mouse_pos 650 650
mouse_click left
delay 1000
screenshot $t/${size}_inside.png
mouse_pos 15 500
mouse_click left
delay 1500
screenshot $t/${size}_off.png
quit
C
	timeout 240 bin/buildat -o launch_ui=launch_menu -w 1100x1000 -u 1 -l 3 \
		-o sound_mute=1 -o ui_size=$size -C "$t/c$size" -D "$t/u$size" \
		-s 127.0.0.1:"$SERVER_PORT" -c @"$t/$size.cmds" > "$t/$size.log" 2>&1
	grep -a "Command sequence failed" "$t/$size.log" && fail "the drive at $size ($t/$size.log)"
	python3 - "$t/$size.log" <<'PY' || fail "UI size $size ($t/$size.log)"
import sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
shown = [i for i, l in enumerate(lines) if "Game settings shown: " in l]
off = [i for i, l in enumerate(lines) if "command: mouse_pos 15 500" in l]
assert len(shown) == 2 and off, "%d times Settings shown" % len(shown)
assert shown[1] > off[0], "Settings back before the click off the window"
assert not any("pause: a press off" in l for l in lines), "pause took a press"
PY
	echo "ok: UI size $size"
done
echo "PASS: clicks inside the Server window keep it; one off it goes back to Settings"
