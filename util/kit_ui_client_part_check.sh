#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s, ~2 min with a cold module cache (2026-11-22)
# covers: builtin/kit/client_lua/ui.lua builtin/kit/client_lua/module.lua
# [KIT_UI_CLIENT_PART] A UI type's client part moving and changing its own
# element (e.ui), on a fresh Workbench project: kitboss (the admin, 1024x700)
# saves local/bob (a builder's UI type, kind text, at the centre; its part
# bobs it by dy, fades it by opacity, sets its text once a second and its
# colour between two, logs e.ui.rect() and e.ui.screen(), and tries
# e.ui.set{id = 4}) and places it 3, a kit/ui_text 4 ("Other", top) and a
# kit/param_set 5 (3's width 40 for the player). Then:
#   1. the part's poke at 4 refused ("no field id"), e.ui's functions only
#      rect, screen, set and text;
#   2. 5 by kitboss's Try, then play: 3 logged at three heights or more, two
#      opacities, two texts "Bob <n>", 40 wide (432 px: the player's own
#      width under the part's changes); rect() 40 wide on a 146.3 x 100
#      screen; 4 never moved, faded or changed (bob.png and bob2.png 20
#      frames later: look at them);
#   3. edit mode: 3 drawn as authored (no part offset).
# KEEP_TMP=1 keeps $t/bob.png and $t/bob2.png.
#   util/kit_ui_client_part_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_ui_client_part; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
SL=$t/srv.log CL=$t/boss.log
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $BOSS 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
}
cmd() { printf '%s\n' "$@" >&3; }
ed() { local e; for e in "$@"; do cmd "event kit_edit $e" "sync 5000"; done; }
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"

mkfifo "$t/boss.cmd"
sleep 900 > "$t/boss.cmd" &
CHECK_PIDS+=($!)
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_ADMIN="setting open_registration on" \
	BUILDAT_JOIN_NAME=kitboss timeout 300 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -c - \
	< "$t/boss.cmd" > "$CL" 2>&1 &
BOSS=$!
CHECK_PIDS+=($BOSS)
exec 3> "$t/boss.cmd"
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 60 "kit editor: edit rights: yes"
cmd "max_fps 30"
ed '{"op": "mode", "on": true}'
place() # <type> <id>
{
	ed "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [0, 1, 0]}"
	await "$SL" 0 10 "An edit by kitboss: placed $1 $2\b"
}
setp() { ed "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
python3 -I - > "$t/type.cmd" <<'PY'
import json
src = '''return {
	version = 1,
	no_position = true,
	ui = {kind = "text", text = "param:text", anchor = "center", x = 0, y = 0,
		width = "param:width", size = 3, color = "#ffffff", background = "#000000c0"},
	params = {text = {cat = "hud", type = "string", default = "Bob"},
		width = {cat = "hud", type = "number", default = 0, min = 0, max = 400}},
	state = {shown = {default = true, shared = true}},
}'''
client = '''return {
	on_add = function(e)
		local ok, err = pcall(e.ui.set, {id = 4, text = "poked"})
		local fns = {}
		for k in pairs(e.ui) do
			fns[#fns + 1] = k
		end
		table.sort(fns)
		e:log("poke " .. tostring(ok) .. " " .. tostring(err) .. "; e.ui " ..
				table.concat(fns, " "))
		e.t, e.sec = 0, -1
	end,
	on_update = function(e, dt)
		e.t = e.t + dt
		e.ui.set{dy = 6 * math.sin(e.t * 3), opacity = 0.6 + 0.4 * math.cos(e.t * math.pi)}
		local s = math.floor(e.t)
		if s ~= e.sec then
			e.sec = s
			e.ui.set{text = "Bob " .. s, color = s % 2 == 0 and "#ffcc00" or "#66ccff"}
			local x, y, w, h, shown = e.ui.rect()
			local sw, sh = e.ui.screen()
			e:log(string.format("rect %s %s %s %s %s; screen %.1f x %.1f; text %s",
					tostring(x), tostring(y), tostring(w), tostring(h),
					tostring(shown), sw, sh, tostring((e.ui.text()))))
		end
	end,
}'''
print("event kit_type " + json.dumps({"op": "put", "name": "bob", "source": src,
	"client": client}))
PY
cat "$t/type.cmd" >&3
await "$CL" 0 20 "bob: Saved"
place local/bob 3
place kit/ui_text 4
setp 4 text '"Other"'
place kit/param_set 5
setp 5 target 3
setp 5 target_type '"local/bob"'
setp 5 param '"width"'
setp 5 value '"40"'
await "$SL" 0 10 "An edit by kitboss: set 5's kit/param_set value to"
echo "ok: placed: local/bob 3, kit/ui_text 4, kit/param_set 5"

# 1. The poke at another element refused; e.ui's functions
await "$CL" 0 20 "kit: entity 3's client part: poke "
p=$(grep -a "kit: entity 3's client part: poke " "$CL" | head -1)
echo "$p" | grep -q "poke false .*no field id; e.ui rect screen set text$" ||
	fail "the poke at 4 not refused as no field, or e.ui not rect screen set text: $p"
echo "ok: e.ui.set{id = 4} refused (no field id); e.ui: rect, screen, set, text"

# 2. Play: bobbing, fading, its text, the player's own width; 4 untouched
m=$(mark "$SL")
ed "{\"op\": \"try\", \"id\": 5, \"input\": \"set\", \"value\": null}"
await "$SL" "$m" 10 "kit/param_set 5: set width of 3 to 40 for kitboss"
mc=$(mark "$CL")
ed '{"op": "mode", "on": false}'
await "$CL" "$mc" 10 "kit: ui 3 text at .* shown.*, part "
for i in $(seq 50); do
	tail -c +$((mc + 1)) "$CL" | grep -a "kit: ui 3 text at" | grep -a ", part " > "$t/l3"
	ys=$(grep -aoE ' at [0-9-]+,[0-9-]+ ' "$t/l3" | cut -d, -f2 | sort -u | wc -l)
	ops=$(grep -aoE 'opacity [0-9.]+' "$t/l3" | sort -u | wc -l)
	txts=$(grep -aoE '"Bob [0-9]+"$' "$t/l3" | sort -u | wc -l)
	[ "$ys" -ge 3 ] && [ "$ops" -ge 2 ] && [ "$txts" -ge 2 ] && break
	sleep 0.2
done
[ "$ys" -ge 3 ] || fail "3 logged at $ys heights, not 3 or more ($t/l3)"
[ "$ops" -ge 2 ] || fail "3 logged at $ops opacities, not 2 or more ($t/l3)"
[ "$txts" -ge 2 ] || fail "3 logged $txts texts \"Bob <n>\", not 2 or more ($t/l3)"
cmd "screenshot $t/bob.png" "frames 20" "screenshot $t/bob2.png" "sync 5000"
await "$CL" "$mc" 10 "kit: entity 3's client part: rect .* 40 "
tail -c +$((mc + 1)) "$CL" | grep -a "kit: ui 4 text at" > "$t/l4"
# (-c is the logical UI: 1580x1080 at -w 1024x700; 40 of its 10.8 px)
ws=$(grep -aoE ' [0-9]+x[0-9]+ in' "$t/l3" | sort -u | tr -d ' in' | tr '\n' ' ')
grep -aoE ' [0-9]+x[0-9]+ in' "$t/l3" | grep -qv ' 432x' &&
	fail "3 not 432 wide (the player's own width 40) throughout: $ws ($t/l3)"
r=$(grep -a "kit: entity 3's client part: rect " "$CL" | tail -1)
r=${r#*client part: }
echo "$r" | grep -qE "rect -?[0-9.]+ -?[0-9.]+ 40 [0-9.]+ true; screen 146.3 x 100.0; text Bob [0-9]+" ||
	fail "rect() or screen() not as drawn: $r"
n4=$(sed -E 's/^.*kit: ui 4 //' "$t/l4" | sort -u | wc -l)
[ "$n4" -le 1 ] && ! grep -qa ", part \|poked" "$t/l4" ||
	fail "4 changed while 3's part ran ($t/l4)"
for i in $(seq 50); do [ -s "$t/bob2.png" ] && break; sleep 0.2; done
[ -s "$t/bob.png" ] && [ -s "$t/bob2.png" ] || fail "no screenshots $t/bob.png, bob2.png"
echo "ok: play: 3 at $ys heights, $ops opacities, $txts texts, $ws wide; $r; 4 unchanged; $t/bob.png, bob2.png"

# 3. Edit mode draws it as authored
mc=$(mark "$CL")
ed '{"op": "mode", "on": true}'
await "$CL" "$mc" 10 "kit: ui 3 text at .*edit mode"
tail -c +$((mc + 1)) "$CL" | grep -a "kit: ui 3 text at .*edit mode" | tail -1 |
	grep -qa ", part " && fail "3's part offset drawn in framed edit mode ($CL)"
echo "ok: edit mode: 3 as authored"
cmd quit
exec 3>&-
wait $BOSS 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
echo "PASS: a UI type's client part moves, fades, recolours and retexts its own element by e.ui, over the player's own width; another element and edit mode untouched; screenshots $t/bob.png $t/bob2.png"
# vim: set noet ts=4 sw=4:
