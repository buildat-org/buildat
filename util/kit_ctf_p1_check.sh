#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-04)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/box/box.c builtin/kit/client_lua/ui.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/controls.lua apps/workbench/main/main.cpp
# [KIT_CTF] P1: positions, moves, regions, speed and markers for any game,
# on Workbench (its stone floor; the admin kitboss, one client), with a
# type of the check's own (BUILDAT_WORKBENCH_TYPES: workbench/probe, its
# inputs calling the API, its runs logging what they saw). Placed: the
# probe P (3, a marker "Flag" while its shared "marked"), a kit/team T
# (4) and under it a kit/region R (5) 96x384x96, from (-40, -100, -40),
# and a wall of stone between the player and P. By the editor's "try":
#   1. P's "probe": c.players has kitboss with pos, yaw and alive.
#   2. "region": c:region_at a cell in R (R, its team T, its dig rule),
#      R's far corner (the raised cap) and a cell past it (none).
#   3. "move": P moved (logged at its new place).
#   4. In play: P's marker on screen behind the wall, then (P moved 3
#      along +x) drawn where it went (to the left, facing -z), at the screen's edge with P
#      behind the view and off to the side (screenshots wall, behind,
#      side: look at them).
#   5. A walk of 2 s along +x, then "speed" 1.3 (kitboss's), a walk of
#      2 s back: the second 1.2...1.4 times the first, and no correction
#      of the client's prediction during it.
#   6. "probe" again: kitboss elsewhere. "mark" false: the marker hidden.
#      "fall" from (6, 8, -8): landed on the floor, at y 1; from y -200,
#      below the World's bottom: nothing below, P where it was.
#
#   util/kit_ctf_p1_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_ctf_p1; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
export BUILDAT_WORKBENCH_STONE=1 BUILDAT_WORKBENCH_PROJECT=world
# (in its app directory: the sandboxed server reads nothing else of the run's)
export BUILDAT_WORKBENCH_TYPES="$t/user/apps/workbench/check_types"
mkdir -p "$t/user/apps/workbench/check_types"
cat > "$t/user/apps/workbench/check_types/probe.lua" <<'EOF'
-- The check's probe: each input calls one of Kit's [KIT_CTF] calls
local function f(x) return tostring(math.floor(x * 100 + 0.5) / 100) end
return {
	version = 1,
	players = true,
	regions = true,
	params = {
		marker_color = {type = "string", default = "#ff3030"},
		marker_label = {type = "string", default = "Flag"},
	},
	state = {marked = {default = true, shared = true}},
	look = {shape = "sphere", size = 0.3, color = "param:marker_color"},
	marker = {color = "param:marker_color", label = "param:marker_label",
		state = "marked"},
	inputs = {probe = "any", move = "position", fall = "position",
		speed = "number", region = "position", mark = "bool"},
	on_input = function(c, input, v, by)
		if input == "probe" then
			for _, p in ipairs(c.players) do
				c:log("player " .. p.name .. " at " .. (p.pos and f(p.pos[1]) ..
						"," .. f(p.pos[2]) .. "," .. f(p.pos[3]) or "-") ..
						" yaw " .. tostring(p.yaw) .. " alive " .. tostring(p.alive))
			end
		elseif input == "move" then
			c:move(v)
		elseif input == "fall" then
			c:move(v, {fall = true})
		elseif input == "speed" then
			c:speed(by, v)
		elseif input == "region" then
			local r = c:region_at(v)
			c:log(r and "region " .. r.id .. " team " .. r.team .. " dig " ..
					tostring(r.rules.dig) or "no region")
		elseif input == "mark" then
			c.state.marked = v
		end
	end,
	on_fall = function(c, pos)
		c:log(pos and "fell onto " .. f(pos[1]) .. "," .. f(pos[2]) .. "," ..
				f(pos[3]) or "fell: nothing below")
	end,
}
EOF

want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
code_of() # <server log>
{
	wait_for_log "$1" "setup code [A-Z0-9]+" 30
	grep -aoP 'setup code \K[A-Z0-9]+' "$1" | head -1
}
n=0; c=1
edit() { echo "event kit_edit $1"; n=$((n + 1)); echo "wait_log 10000 kit editor: state: $c entities, $n to undo"; }
place() { c=$((c + 1)); edit "$1"; }
setp() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
try() # <input> <value> <server log line to wait for: none here>
{
	echo "event kit_edit {\"op\": \"try\", \"id\": 3, \"input\": \"$1\", \"value\": $2}"
	echo "wait_log 10000 kit editor: tried 3's $1:"
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
EOF
	place '{"op": "place", "type": "workbench/probe", "pos": [3, 1, -8]}'
	place '{"op": "place", "type": "kit/team", "pos": [0, 1, 4]}'
	place '{"op": "place", "type": "kit/region", "pos": [-40, -100, -40], "parent": 4}'
	setp 5 size '[96, 384, 96]'
	for x in -1 0 1 2 3 4 5 6; do
		for y in 1 2 3; do
			edit "{\"op\": \"set_voxel\", \"pos\": [$x, $y, -4], \"voxel\": \"kit/stone\"}"
		done
	done
	try probe 1
	try region '[0, 0, 0]'
	try region '[55, 283, 55]'
	try region '[56, 0, 0]'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 0.25 0 -1
frames 10
wait_log_any 10000 kit: marker 3 "Flag" on screen
screenshot @T@/wall.png
event kit_markers
keypress F6
wait_log 10000 kit editor: state:
EOF
	try move '[6, 1, -8]'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 0.25 0 -1
frames 30
event kit_markers
look_dir -0.25 0 1
frames 10
screenshot @T@/behind.png
event kit_markers
look_dir -1 0 0.3
frames 10
screenshot @T@/side.png
event kit_markers
look_dir 1 0 0
frames 10
event kit_body
keydown W
delay 2000
keyup W
frames 30
event kit_body
keypress F6
wait_log 10000 kit editor: state:
EOF
	try speed 1.3
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir -1 0 0
frames 30
event kit_body
keydown W
delay 2000
keyup W
frames 30
event kit_body
keypress F6
wait_log 10000 kit editor: state:
EOF
	try probe 1
	try mark false
	echo 'wait_log 10000 kit: marker 3 "Flag" hidden'
	try fall '[6, 8, -8]'
	try fall '[6, -200, -8]'
	echo "sync 5000"
	echo "quit"
} > "$t/boss.cmds"
sed -i "s|@T@|$t|g" "$t/boss.cmds"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
code=$(code_of "$t/srv.log")
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	run_client 60 "$t/boss.log" timeout 240 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -c @"$t/boss.cmds" ||
	fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log; b=$t/boss.log
grep -a "probe 3\|speed x\|Entity 3's" "$s" | sed 's/^.* I [a-z_]* *: /  /' | cut -c1-150
grep -a "kit: marker\|kit: body at" "$b" | sed 's/^.* I [a-z_]* *: /  /' | cut -c1-150
# 1. positions
grep -aqE "probe 3: player kitboss at -?[0-9.]+,1,-?[0-9.]+ yaw -?[0-9.]+ alive true" "$s" ||
	fail "the probe did not see kitboss's place, yaw and alive ($s)"
[ "$(grep -aoE "probe 3: player kitboss at [^ ]+" "$s" | sort -u | wc -l)" -ge 2 ] ||
	fail "kitboss's place was the same after the walks ($s)"
# 2. regions
want "$s" "probe 3: region 5 team 4 dig none" "probe 3: no region"
[ "$(grep -ac "probe 3: region 5 team 4" "$s")" = 2 ] ||
	fail "region_at did not find the 96x384x96 region's far corner ($s)"
# 3. and 6. moves and falls
want "$s" "Entity 3's workbench/probe moves to (6, 1, -8)" \
	"probe 3: fell onto 6,1,-8" "probe 3: fell: nothing below" \
	"Entity 3's workbench/probe: nothing to fall onto below (6, -200, -8)" \
	"kitboss's speed x1.3"
# 4. the marker
at() { grep -aoP "kit: marker 3 is on screen at \K-?[0-9]+(?=,)" "$b" | sed -n "$1p"; }
x1=$(at 1); x2=$(at 2)
# (facing -z, +x is to the left on the screen: Urho3D's left-handed axes)
[ -n "$x1" ] && [ -n "$x2" ] && [ "$x2" -lt $((x1 - 20)) ] ||
	fail "the marker did not follow the probe along +x ($x1 -> $x2, $b)"
[ "$(grep -ac "kit: marker 3 is at the edge" "$b")" = 2 ] ||
	fail "the marker was not kept at the edge behind and to the side ($b)"
want "$b" 'kit: marker 3 "Flag" hidden'
for f in wall behind side; do
	[ -s "$t/$f.png" ] || fail "no screenshot $f ($t)"
done
# 5. the speed: each walk's distance along x, the corrections during them
bodies=($(grep -aoP "kit: body at \K-?[0-9.]+(?=,)" "$b"))
corr=($(grep -aoP "acks, \K[0-9]+(?= corrections)" "$b"))
[ "${#bodies[@]}" = 4 ] || fail "not 4 body lines ($b)"
read d1 d2 ratio < <(awk -v a="${bodies[0]}" -v b="${bodies[1]}" \
	-v c="${bodies[2]}" -v d="${bodies[3]}" 'function abs(x){return x < 0 ? -x : x}
	BEGIN { d1 = abs(b - a); d2 = abs(d - c); printf "%.2f %.2f %.3f\n", d1, d2, d2 / d1 }')
echo "  walks: $d1 m, then $d2 m at x1.3 (x$ratio); corrections ${corr[*]}"
awk -v r="$ratio" -v d="$d1" 'BEGIN { exit !(d > 5 && r >= 1.2 && r <= 1.4) }' ||
	fail "the walk at x1.3 went x$ratio the first ($d1 m, $d2 m; $b)"
[ "${corr[2]}" = "${corr[3]}" ] ||
	fail "the client's prediction was corrected during the walk at x1.3 (${corr[2]} -> ${corr[3]}; $b)"
echo "PASS: [KIT_CTF] P1: c.players' pos, yaw and alive; c:region_at (a team's region, 96x384x96); c:move and its fall (landed; nothing below); c:speed 1.3 walked x$ratio with no correction; the marker through a wall, following its entity, at the edge behind and to the side, hidden by its state; screenshots $t/{wall,behind,side}.png"
