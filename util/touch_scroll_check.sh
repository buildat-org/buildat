#!/bin/bash
# tier: quick
# cost: ~40 s (2026-10-11)
# covers: 3rdparty/Urho3D/Source/Urho3D/UI/ScrollView.cpp extensions/launch_menu/preferences.lua
# [TOUCH_SCROLL_ON_BUTTONS]: a finger's drag in a ScrollView scrolls it
# from wherever it began. A client-only dev app made here opens the
# settings window a game opens (buildat.show_game_settings) with a section
# of a slider and twenty buttons, at UI scale 2 (the web's device pixels),
# and by finger: a drag begun on a button scrolls the view and presses
# nothing, a tap on a button presses it, a drag on the slider moves the
# slider and not the view, and a drag begun between two buttons scrolls.
# P logs where the fifth button is and the slider's value.
#   util/touch_scroll_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp touch_scroll; t=$CHECK_TMP
trap check_cleanup EXIT
a=$t/u/dev_apps/tsdrag
mkdir -p "$a/launcher" "$a/main/client_lua"
echo '{"kind": "app", "name": "tsdrag", "version": "0.1.0", "engine_api": 2}' > "$a/meta.json"
echo '{"engine_api": 2, "disable_cpp": true, "client_main": "init.lua", "dependencies": [{"module": "network"}, {"module": "client_lua"}, {"module": "client_data"}]}' > "$a/main/meta.json"
echo 'return function(ctx) return {{id = "play", label = "tsdrag", run = function() ctx.launch{app = "tsdrag"} end}} end' > "$a/launcher/init.lua"
cat > "$a/main/client_lua/init.lua" <<'L'
local log = buildat.Logger("tsdrag")
local magic = require("buildat/extension/urho3d")
local rows = {}
log:info("tsdrag: ready")
magic.SubscribeToEvent("KeyDown", function(_, d)
	local k = d:GetInt("Key")
	if k == magic.KEY_O then
		buildat.show_game_settings{sections = {{title = "Rows", draw = function(w, ui)
			local sl = w:CreateChild("Slider")
			sl:SetStyleAuto()
			sl:SetFixedHeight(24)
			sl.range = 100
			rows.slider = sl
			for i = 1, 20 do
				rows[i] = ui.button("Row " .. i, function() log:info("tsdrag: pressed " .. i) end)
			end
		end}}}
	elseif k == magic.KEY_P then
		log:info("tsdrag: at " .. rows[5].screenPosition.y .. " slider " ..
				math.floor(rows.slider.value))
	end
end)
L
# Window pixels at 800x600 and scale 2: the slider's knob at (60, 233),
# the gap between Row 1 and Row 2 at y 338, Row 3 at y 450
# The delays in a drag are the finger's own timing; the second after it
# is the view coming to rest, which logs nothing. Each P waits for its line.
drag(){ # x0 y0 x1 y1: down, five moves, up
	echo "finger_down 1 $1 $2"
	echo "delay 100"
	for i in 1 2 3 4 5; do
		echo "finger_move 1 $(($1 + ($3 - $1) * i / 5)) $(($2 + ($4 - $2) * i / 5))"
		echo "delay 50"
	done
	echo "finger_up 1"
	echo "delay 1000"
	echo "keypress P"
	echo "wait_log 5000 tsdrag: at "
}
# The half seconds: the launch's screen settling before the key, and the
# window laid out in the frames after its line
open="wait_log_any 30000 tsdrag: ready
delay 500
keypress O
wait_log 5000 Game settings shown
delay 500
keypress P
wait_log 5000 tsdrag: at "
run(){ # name, the sequence after the window is open
	printf '%s\n%s\nquit\n' "$open" "$2" > "$t/$1.cmds"
	(cd "$here/Build" && timeout 60 bin/buildat -o launch_ui=launch_menu \
		-w 800x600 -u 2 -l 3 -o sound_mute=1 -C "$t/c" -D "$t/u" \
		-a dev/tsdrag/play -c @"$t/$1.cmds") > "$t/$1.log" 2>&1 ||
		fail "$1: the drive ($t/$1.log): $(grep -ao 'Command sequence failed.*' "$t/$1.log" | head -1)"
	grep -a "tsdrag: \(at\|pressed\)" "$t/$1.log" | grep -v wait_log | sed 's/.*tsdrag: //' > "$t/$1.out"
}
# A drag begun on Row 3, 200 px up
run button "$(drag 375 450 375 250)"
start=$(sed -n 1p "$t/button.out" | awk '{print $2}')
end=$(sed -n 2p "$t/button.out" | awk '{print $2}')
[ -n "$start" ] && [ -n "$end" ] || fail "button: no positions ($t/button.log)"
[ "$end" -lt $((start - 50)) ] || fail "button: the view did not scroll ($start, then $end)"
grep -q pressed "$t/button.out" && fail "button: a drag pressed it: $(grep pressed "$t/button.out")"
echo "ok: a drag begun on a button scrolls ($start to $end) and presses nothing"
# A tap on Row 3, then the slider's knob dragged right and up, then a drag
# begun between Row 1 and Row 2
run rest "tap 375 450
wait_log 5000 tsdrag: pressed
keypress P
wait_log 5000 tsdrag: at 
$(drag 60 233 400 133)
$(drag 375 338 375 138)"
sed -n 2p "$t/rest.out" | grep -q "^pressed 3$" || fail "the tap: $(cat "$t/rest.out")"
read -r _ y0 _ s0 < <(sed -n 1p "$t/rest.out")
read -r _ y1 _ s1 < <(sed -n 3p "$t/rest.out")
read -r _ y2 _ s2 < <(sed -n 4p "$t/rest.out")
read -r _ y3 _ _ < <(sed -n 5p "$t/rest.out")
[ "$y1" = "$y0" ] || fail "the tap moved the view ($y0, then $y1)"
[ "$s2" -gt 30 ] && [ "$y2" = "$y0" ] ||
	fail "the slider: value $s0 to $s2, the view at $y0 to $y2"
[ "$y3" -lt $((y2 - 50)) ] || fail "a drag between buttons did not scroll ($y2, then $y3)"
echo "ok: a tap presses, a slider's drag is the slider's ($s0 to $s2), a drag between buttons scrolls"
echo "PASS: a drag in a ScrollView scrolls it from wherever it began, a tap still presses"
