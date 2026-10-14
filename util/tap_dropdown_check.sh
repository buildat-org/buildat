#!/bin/bash
# tier: broken
# broken: back to full; not open and closed 20 times (dev); no launch_menu
#   settings line (the branch) (local/runs/dev_baseline)
# cost: ~3 min (2026-10-11)
# covers: extensions/ui_utils/init.lua 3rdparty/Urho3D/Source/Urho3D/UI/Menu.cpp
# [TAP_DROPDOWN]: a tap on a dropdown opens it on a phone. In Chrome with
# real touch events (which Chrome follows with its emulated mouse events,
# as a phone's browser does) at a phone's 400x800 CSS pixels, device
# pixel ratio 2; ui_utils logs each popup as it opens and closes:
#   - a client-only dev app made here, the settings window a game opens
#     (buildat.show_game_settings, a ScrollView) with a dropdown in it:
#     20 taps on it at a jitter of up to 6 device pixels each open it and a
#     tap outside closes it; a tap on a choice picks it, and a mouse's
#     click does too; a drag begun on it scrolls the view and opens
#     nothing;
#   - the play app's Engine settings, a dropdown outside a scroll view:
#     the same 20 taps.
# simplified: the Starport listing's dropdowns are not driven (it needs a
# Starport); they are ui_utils.dropdown as these are.
#   util/tap_dropdown_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null || { echo "SKIP: no Chrome"; exit 0; }
[ -f "$here/web/buildat.wasm" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp tap_dropdown; t=$CHECK_TMP
trap check_cleanup EXIT
a=$t/app/tdrop
mkdir -p "$a/main/client_lua"
echo '{"kind": "app", "name": "tdrop", "version": "0.1.0", "engine_api": 2}' > "$a/meta.json"
echo '{"engine_api": 2, "disable_cpp": true, "client_main": "init.lua", "dependencies": [{"module": "network"}, {"module": "client_lua"}, {"module": "client_data"}]}' > "$a/main/meta.json"
cat > "$a/main/client_lua/init.lua" <<'L'
local log = buildat.Logger("tdrop")
local magic = require("buildat/extension/urho3d")
local pick
log:info("tdrop: ready")
magic.SubscribeToEvent("KeyDown", function(_, d)
	local k = d:GetInt("Key")
	if k == magic.KEY_O then
		buildat.show_game_settings{sections = {{title = "Pick", draw = function(w, ui)
			pick = ui.dropdown("Pick", {{"one", 1}, {"two", 2}, {"three", 3}}, 1,
					function(v) log:info("tdrop: picked " .. v) end)
			for i = 1, 12 do
				ui.button("Row " .. i, function() end)
			end
		end}}}
	elseif k == magic.KEY_P then
		log:info("tdrop: at " .. pick.screenPosition.y)
	end
end)
L
# 20 taps at (x, y) jittered by up to 3 CSS pixels, each followed by one
# at (ox, oy) outside; each waits for the popup's own line (ui_utils logs
# it opening and closing), so a tap that opens nothing fails the drive
# there
taps(){ # x y ox oy
	for i in $(seq 20); do
		echo " [\"tap\", $(($1 + RANDOM % 7 - 3)), $(($2 + RANDOM % 7 - 3))], [\"waitlog\", \"dropdown_\\\\d+ open\", 10],"
		echo " [\"tap\", $3, $4], [\"waitlog\", \"dropdown_\\\\d+ closed\", 10],"
	done
}
drive(){ # name, game, steps file, url
	WEB_DRIVE_URL=$4 TOUCH=1 WEB_DRIVE_VIEWPORT=400x800@2 "$here/util/web_drive.sh" \
		chrome "$2" "$3" "$t/$1" > "$t/$1.txt" 2>&1 ||
		fail "$1: the drive: $(tail -2 "$t/$1.txt")"
	grep -ao "ui_utils: dropdown_[0-9]* \(open\|closed\)\|tdrop: .*" \
		"$t/$1/page.log" | sed 's/ui_utils: dropdown_[0-9]* /dropdown /; s/tdrop: //' > "$t/$1.out"
}
# Twenty taps' lines: open, closed, twenty times
twenty(){ # name, out lines
	local want
	want=$(for i in $(seq 20); do printf 'dropdown open\ndropdown closed\n'; done)
	[ "$(echo "$2" | grep '^dropdown' | head -40)" = "$want" ] ||
		fail "$1: not open and closed 20 times: $(echo "$2" | tr '\n' ' ') ($t/$1.out)"
}
# The scroll view. CSS pixels: the dropdown at (270, 151), its choices
# "two" and "three" at y 212 and 240, the window's title at (70, 74)
start_server "$t/srv.log" "STATUS Listening" 90 auto "$here/Build/bin/buildat_server" \
	-m "$a" -D "$t/sd" -C "$t/sd.cache" -W "$here/web" -l 3 || fail "the server"
CHECK_PIDS+=($SERVER_PID)
# The second after the drag is the time a popup it wrongly opened would
# have to say so; the short waits after a line are the page's next frames
cat > "$t/scroll.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "tdrop: ready", 60], ["wait", 1000],
 ["key", "o"], ["waitlog", "Game settings shown", 10], ["wait", 500],
 ["key", "p"], ["waitlog", "tdrop: at ", 10],
$(taps 270 151 70 74)
 ["tap", 270, 151], ["waitlog", "dropdown_\\\\d+ open", 10],
 ["tap", 240, 212], ["waitlog", "tdrop: picked 2", 10], ["waitlog", "dropdown_\\\\d+ closed", 10],
 ["click", 270, 151], ["waitlog", "dropdown_\\\\d+ open", 10],
 ["click", 240, 240], ["waitlog", "tdrop: picked 3", 10], ["waitlog", "dropdown_\\\\d+ closed", 10],
 ["drag", 270, 151, 270, 51, "touch"], ["wait", 1000],
 ["key", "p"], ["waitlog", "tdrop: at ", 10]
]
J
drive scroll tdrop "$t/scroll.json" "http://127.0.0.1:$SERVER_PORT/"
out=$(cat "$t/scroll.out")
twenty scroll "$out"
rest=$(echo "$out" | grep -v '^\(ready\|at \)' | sed '1,40d' | tr '\n' ' ')
[ "$rest" = "dropdown open picked 2 dropdown closed dropdown open picked 3 dropdown closed " ] ||
	fail "scroll: after the taps: $rest ($t/scroll.out)"
y0=$(echo "$out" | grep '^at ' | head -1 | awk '{print $2}')
y1=$(echo "$out" | grep '^at ' | tail -1 | awk '{print $2}')
[ -n "$y0" ] && [ "$y1" -lt $((y0 - 30)) ] || fail "scroll: the drag did not scroll ($y0, then $y1)"
echo "ok: in a scroll view 20 taps open and a tap outside closes, a tap and a click pick, a drag scrolls ($y0 to $y1) and opens nothing"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
# Outside a scroll view: Home's Settings, "Display and sound", the
# Antialiasing dropdown at (306, 340), outside it the title at (100, 230)
# The waits after a line are the page's next frames, the menu laid out;
# the last one only ends the list after the taps' trailing comma
cat > "$t/plain.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "launch_menu: ", 60], ["wait", 2000],
 ["tap", 200, 460], ["waitlog", "launch_menu: settings, ", 10], ["wait", 500],
 ["tap", 180, 275], ["waitlog", "Engine settings shown", 10], ["wait", 500],
$(taps 306 340 100 230)
 ["wait", 200]
]
J
drive plain play "$t/plain.json" ""
twenty plain "$(cat "$t/plain.out")"
echo "ok: outside a scroll view 20 taps open and a tap outside closes"
echo "PASS: a tap opens a dropdown every time, in a scroll view or not; a tap or a click picks; a drag on one scrolls its view"
