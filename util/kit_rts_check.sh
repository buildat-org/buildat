#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~7 min (2026-11-24)
# covers: apps/workbench/templates/deepcore/** builtin/kit/client_lua/rts.lua builtin/kit/types/unit.lua builtin/kit/kit.cpp builtin/kit/box/box.c
# [KIT_RTS] (kit_plan 4z37zzo) The Deepcore template (an underground RTS) on
# Workbench; one server, kitboss on a headless weston's Xwayland:
#   1. New from it: its types local/rts_*; in the editor a check type's vault
#      in Blue's base (workbench/rts_vault: hard rock round a dirt plug), the
#      computer's aggression 1 and both sides' money 1500 (it attacks
#      sooner); the lobby; "Play against the computer": a match, kitboss in
#      Blue, the rts camera at Blue's base; fog of war: none of Red's units
#      (in their base, far off) among the client's nodes (kit_rts_nodes),
#      Blue's there;
#   2. the camera: a turn, a pan, the cut;
#   3. select and order by the mouse (mouse_pos and its buttons through
#      rts.lua's handlers, the build bar up; the client at render scale
#      0.5): a box round Blue's digger, a click on it (selected 1), a right
#      click on the ground: it goes there (a digger's way: an open one it
#      drives);
#   4. a factory bought on the build bar, a tank bought: made in its bay, it
#      drives out of the door (stops 2.5 m or more in front of the bay);
#   5. the digger ordered into the vault digs the dirt plug (the vault's plug
#      cells gone) and stops at its west wall of hard rock ("blocked by hard
#      rock", the wall whole); the tank ordered into the vault drives in
#      through the new tunnel (its only way in);
#   6. a harvester's round trip: ore mined, unloaded at the refinery, Blue's
#      money up;
#   7. the computer: within a few game minutes Red buys, its harvesters
#      unload and its attackers are sent at Blue;
#   8. the recorder's perf with 60 units in view (a check type's 60 of
#      Blue's tanks in the middle cavern, the cut on, made with the tools on
#      in the round: try); with Firefox and web/, a short web run on the
#      same save at devicePixelRatio 2: its lobby, a match, a unit clicked,
#      a box, a right click's order (the page's mouse), the units in view
#      (the frame about as bright as the native's), its perf.
# Screenshots (KEEP_TMP=1): $t/lobby.png, $t/start.png, $t/cut.png,
# $t/factory.png, $t/vault.png, $t/ai.png, $t/many.png, $t/web/*.png
#   util/kit_rts_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_rts; t=$CHECK_TMP
cd "$here/Build"
check_build
export BUILDAT_JOIN_PASSWORD=checkpass12 SDL_AUDIODRIVER=dummy
export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
# The vault: outer x 0..5, z 0..4, y 0..3 of hard rock from its cell, a plug
# of dirt in its east wall (x 5, z 1..2, y 0..1); a change logged
cat > "$BUILDAT_WORKBENCH_TYPES/rts_vault.lua" <<'EOF'
local function look(c)
	local p = {math.floor(c.pos[1] + 0.5), math.floor(c.pos[2] + 0.5), math.floor(c.pos[3] + 0.5)}
	local v = c:voxels_at(p, {6, 2, 5})
	local plug, west = 0, 0
	for y = 0, 1 do
		for z = 1, 2 do
			if v[1 + 5 + 6 * (z + 5 * y)] == "kit/dirt" then plug = plug + 1 end
			if v[1 + 6 * (z + 5 * y)] == "kit/hard_rock" then west = west + 1 end
		end
	end
	return plug, west
end
return {
	version = 1,
	about = {what = "A check's: a hard rock vault with a dirt plug."},
	world_voxels = true,
	state = {plug = {default = -1}, west = {default = -1}},
	on_start = function(c)
		local v = {}
		local p = {math.floor(c.pos[1] + 0.5), math.floor(c.pos[2] + 0.5), math.floor(c.pos[3] + 0.5)}
		for x = 0, 5 do
			for z = 0, 4 do
				for y = 0, 3 do
					if x == 0 or x == 5 or z == 0 or z == 4 then
						local plug = x == 5 and z >= 1 and z <= 2 and y <= 1
						v[#v + 1] = {p[1] + x, p[2] + y, p[3] + z, plug and "kit/dirt" or "kit/hard_rock"}
					end
				end
			end
		end
		c:set_voxels_at(v)
		c:log("vault built: " .. #v)
		c:after(1, "look")
	end,
	on_timer = function(c)
		c:after(1, "look")
		local plug, west = look(c)
		if plug ~= c.state.plug or west ~= c.state.west then
			c.state.plug, c.state.west = plug, west
			c:log("vault: plug dirt " .. plug .. "/4, west hard rock " .. west .. "/4")
		end
	end,
}
EOF
# 60 of Blue's tanks in two blocks from its place (the middle cavern), on its
# input "go" (one side: two would shoot each other down before the measure)
cat > "$BUILDAT_WORKBENCH_TYPES/rts_many.lua" <<'EOF'
return {
	version = 1,
	about = {what = "A check's: 60 of Blue's tanks."},
	params = {blue = {type = "prefab", default = "deepcore/tank_blue"},
		at = {type = "number", default = 0}},
	state = {n = {default = 0}},
	inputs = {go = "none"},
	on_start = function(c)
		if c.params.at > 0 then
			c:after(c.params.at, "more")
		end
	end,
	on_input = function(c)
		c:after(0.05, "more")
	end,
	on_timer = function(c)
		for _ = 1, 12 do
			local n = c.state.n
			if n >= 60 then
				c:log("many: 60 made from " .. c.pos[1] .. "," .. c.pos[2] .. "," .. c.pos[3])
				return
			end
			local red = n >= 30
			local i = n % 30
			c:spawn({prefab = c.params.blue,
				pos = {c.pos[1] + (i % 6) * 1.4 + (red and 8 or 0), c.pos[2],
					c.pos[3] + math.floor(i / 6) * 1.4}})
			c.state.n = n + 1
		end
		c:after(0.1, "more")
	end,
}
EOF
VAULT="-44, 7, -14"
MATCH=10 AI=11

sock=buildat-rts-$$
XDG_RUNTIME_DIR=/run/user/$(id -u) weston --backend=headless --renderer=pixman \
	--xwayland --socket=$sock --width=1100 --height=760 --idle-time=0 \
	> "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
d=
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
SL=$t/srv.log CL=$t/boss.log CLIENT=
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		[ -z "$CLIENT" ] || kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		kill -0 "$SERVER_PID" 2>/dev/null || fail "the server is gone ($SL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
}
cmd() { printf '%s\n' "$@" >&3; }
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
# say <command>...: sent, then an "event kit_rts" and its line waited for
say() { step 60 "kit: rts: camera at" "$@" "frames 3" "event kit_rts"; }
last_rts() { grep -a "kit: rts: camera at" "$CL" | tail -1; }
try() { step 10 "kit editor: tried|kit editor: .*refused" "event kit_edit {\"op\": \"try\", \"id\": $1, \"input\": \"$2\"}"; }
# where <id | x,y,z>: where that unit or point is on the screen, "x y" (the
# mouse's pixels), empty if not on it
where()
{
	step 10 "kit: rts: (unit|point) .*(on the screen at|not on the screen)" \
		"event kit_rts_where $1"
	grep -aF "kit: rts: " "$CL" | grep -aF " $1 " | tail -1 |
		grep -aoP "on the screen at \K[0-9]+, [0-9]+" | tr -d ,
}
# [KIT_RTS] The mouse's own clicks (rts.lua's handlers, as a player's: a
# panel with a button up, Deepcore's build bar, made every one nothing and
# "event kit_click_at" went round them)
# mclick <id | x,y,z> <left|right> <regex in the client's log>
mclick()
{
	local p
	p=$(where "$1")
	[ -n "$p" ] || fail "$1 not on the screen to click ($CL)"
	step 10 "$3" "mouse_pos $p" "frames 2" "mouse_down $2" "frames 2" "mouse_up $2"
}
# mbox <id> <regex>: a left drag from 40 px up and left of it to as far
# down and right
mbox()
{
	local p
	p=($(where "$1"))
	[ -n "${p[*]}" ] || fail "$1 not on the screen to box ($CL)"
	step 10 "$2" "mouse_pos $((p[0] - 40)) $((p[1] - 40))" "frames 2" \
		"mouse_down left" "frames 2" "mouse_pos $((p[0] + 40)) $((p[1] + 40))" \
		"frames 2" "mouse_up left"
}
# made <Team> <what>: the id of the last one the match made
made() { grep -aoP "made $1 $2 \K[0-9]+" "$SL" | tail -1; }
# stop <id> <offset>: where it last stopped after the offset, "x y z"
stop() { tail -c +$(($2 + 1)) "$SL" | grep -aoP "Entity $1 stopped at \(\K[^)]+" | tail -1 | tr -d ,; }

start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
grep -aq "workbench: the template in .*deepcore" "$SL" && fail "the template refused ($SL)"
mkfifo "$t/boss.cmd"
sleep 1500 > "$t/boss.cmd" &
CHECK_PIDS+=($!)
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 BUILDAT_JOIN_ADMIN="setting open_registration on" \
	timeout 1400 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1,render_scale=0.5 -c - \
	< "$t/boss.cmd" > "$CL" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/boss.cmd"
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don*"'

# ---- 1. New from the template, the vault, the lobby, a match
await "$CL" 0 30 "world_menu: the list shown"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Deepcore"'
step 120 "kit editor: edit mode on" "frames 3" 'click Button "Create"'
for ty in rts_match rts_ai rts_unit rts_digger rts_harvester; do
	grep -aqE "The template's type local/$ty \([0-9]+ bytes\)" "$SL" || fail "no local/$ty ($SL)"
done
step 10 "entities, 1 to undo" "event kit_edit {\"op\": \"place\", \"type\": \"workbench/rts_vault\", \"pos\": [$VAULT]}"
step 10 "entities, 2 to undo" "event kit_edit {\"op\": \"place\", \"type\": \"workbench/rts_many\", \"pos\": [-7.5, 7, -6]}"
step 10 "entities, 3 to undo" "event kit_edit {\"op\": \"set\", \"id\": $AI, \"comp\": 0, \"param\": \"aggression\", \"value\": 1}"
step 10 "entities, 4 to undo" "event kit_edit {\"op\": \"set\", \"id\": $MATCH, \"comp\": 0, \"param\": \"start_money\", \"value\": 1500}"
MANY=$(grep -aoP "workbench/rts_many \K[0-9]+" "$SL" | head -1)
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$SL" 0 30 "vault built: "
await "$CL" 0 30 'panel .* shown, layer [0-9]+: "Deepcore'
step 10 "Wrote screenshot $t/lobby.png" "frames 10" "screenshot $t/lobby.png"
m=$(mark "$SL")
cmd 'click Button "Play against*"'
await "$SL" "$m" 20 "match started: computer"
await "$SL" "$m" 20 "joins team Blue"
await "$CL" 0 30 "kit: rts: the camera on"
grep -aoP "(Blue|Red)'s ore pockets: [0-9]+ cells" "$SL" | tail -2
say "frames 60" "screenshot $t/start.png"
r0=$(last_rts)
python3 -I - "$r0" <<'PY' || fail "the camera is not at Blue's base: $r0"
import re, sys
x, y, z = map(float, re.search(r"camera at (\S+),(\S+),(\S+),", sys.argv[1]).groups())
assert abs(x + 35) < 8 and abs(z - 1) < 8, (x, z)
PY
HQ=$(made Blue hq) DIG=$(made Blue digger) HARV=$(made Blue harvester)
[ -n "$HQ" ] && [ -n "$DIG" ] && [ -n "$HARV" ] || fail "no Blue hq, digger, harvester ($SL)"
echo "ok: a game from Deepcore, its local/rts_* types, the lobby, a match against the computer, the camera at Blue's base: $r0"

# Fog of war: Red's base far beyond Blue's sight, none of its units nor
# their parts (the ids after each) among the client's nodes; Blue's there
step 10 "kit: rts: nodes " "frames 30" "event kit_rts_nodes"
NODES=" $(grep -a "kit: rts: nodes " "$CL" | tail -1 | sed 's/.*: //') "
nred=0
for id in $(grep -aoP "made Red \w+ \K[0-9]+" "$SL"); do
	for k in $id $((id + 1)); do
		case "$NODES" in *" $k "*) fail "Red's $k sent to Blue's client under the fog ($CL)";; esac
	done
	nred=$((nred + 1))
done
[ "$nred" -ge 4 ] || fail "not 4 Red units made ($SL)"
for id in $HQ $DIG $HARV; do
	case "$NODES" in *" $id "*) ;; *) fail "Blue's $id not on Blue's client: $NODES ($CL)";; esac
done
echo "ok: fog of war: none of Red's $nred units on Blue's client, Blue's own there"

# ---- 2. The camera: a turn, a pan, the cut
say "mouse_pos 512 350" "mouse_down right" "frames 2" "mouse_move 80 0" "frames 2" \
	"mouse_move 80 10" "frames 2" "mouse_up right"
r1=$(last_rts)
say "keydown d" "delay 500" "keyup d"
r2=$(last_rts)
say "keypress PageDown" "frames 10" "screenshot $t/cut.png"
r3=$(last_rts)
python3 -I - "$r0" "$r1" "$r2" "$r3" <<'PY' || fail "the camera did not turn, pan and cut"
import re, sys
def f(s):
    m = re.search(r"camera at (\S+),(\S+),(\S+), yaw (\S+), pitch (\S+),", s)
    return [float(x) for x in m.groups()]
a, b, c = [f(s) for s in sys.argv[1:4]]
assert abs((b[3] - a[3] + 180) % 360 - 180) > 15, ("no turn", a, b)
assert ((b[0] - c[0]) ** 2 + (b[2] - c[2]) ** 2) ** 0.5 > 1, ("no pan", b, c)
assert "cut off" not in sys.argv[4], sys.argv[4]
print("ok: the camera turned, panned and cut: " + re.search(r"cut [^,]*", sys.argv[4]).group(0))
PY
# (back over the base, from the north, the cut where it was)
say "event kit_rts_focus -36 6.5 -6" "keypress PageUp"

# ---- 3. Select and order by the mouse: a box round the digger (made at
# the base's -3, +4), a click on it, a right click on the ground
mbox $DIG "kit: rts: selected [0-9]+ \(box"
say
last_rts | sed 's/.*selected [0-9]*://' | grep -qw "$DIG" || fail "the digger not in the box's selection: $(last_rts)"
mclick $DIG left "kit: rts: selected 1 \(click on $DIG\)"
m=$(mark "$SL")
mclick -37,6.5,-12 right "kit: rts: 1 ordered to"
await "$SL" "$m" 10 "Order by kitboss: 1 units to"
await "$SL" "$m" 60 "local/rts_digger $DIG: dug to -37,7,-12"
echo "ok: the digger selected by a click and ordered by a right click: $(stop $DIG $m)"

# ---- 4. A factory and a tank out of its door
m=$(mark "$SL")
cmd 'click Button "Factory*"'
await "$SL" "$m" 10 "Blue: a factory built"
FAC=$(made Blue factory)
fpos=$(grep -aoP "made Blue factory $FAC at \K\S+" "$SL" | tail -1)
m=$(mark "$SL")
cmd 'click Button "Tank*"'
await "$SL" "$m" 10 "Blue: a tank queued at the factory"
await "$SL" "$m" 20 "made Blue tank [0-9]+"
TANK=$(made Blue tank)
await "$SL" "$m" 30 "Entity $TANK stopped at "
tpos=$(stop $TANK $m)
python3 -I - "$fpos" "$tpos" <<'PY' || fail "the tank did not drive out of the factory's door ($SL)"
import sys
f = [float(v) for v in sys.argv[1].split(",")]
t = [float(v) for v in sys.argv[2].split()]
assert t[2] - f[2] >= 2.5 and abs(t[0] - f[0]) < 2.5, (f, t)
print("ok: the tank made in the factory's bay at %s drove out of its door to %s" % (f, t))
PY
say "event kit_rts_focus ${fpos//,/ }" "frames 20" "screenshot $t/factory.png"

# ---- 5. The digger into the vault, through its plug, not its west wall
grep -aq "vault: plug dirt 4/4, west hard rock 4/4" "$SL" || fail "the vault was not whole ($SL)"
say "event kit_rts_focus -40 6.5 -10"
mclick $DIG left "kit: rts: selected 1 \(click on $DIG\)"
m=$(mark "$SL")
mclick -42,6.5,-12 right "kit: rts: 1 ordered to"
await "$SL" "$m" 60 "local/rts_digger $DIG: dug to -42,7,-12"
await "$SL" "$m" 5 "vault: plug dirt 0/4, west hard rock 4/4"
m=$(mark "$SL")
mclick -47,6.5,-12 right "kit: rts: 1 ordered to"
await "$SL" "$m" 30 "local/rts_digger $DIG: blocked by hard rock"
grep -aq "local/rts_digger $DIG: cannot dig kit/hard_rock" "$SL" || fail "no hard rock refused ($SL)"
tail -c +$((m + 1)) "$SL" | grep -aq "vault: plug" && fail "the vault changed ($SL)"
echo "ok: the digger dug the vault's dirt plug, not its hard rock wall"
# The tank into the vault: its way in the dug plug
tp=($tpos)
say "event kit_rts_focus ${tp[0]} 6.5 ${tp[2]}"
mclick $TANK left "kit: rts: selected 1 \(click on $TANK\)"
say "event kit_rts_focus -40 6.5 -10"
m=$(mark "$SL")
mclick -41,6.5,-12 right "kit: rts: 1 ordered to"
await "$SL" "$m" 60 "Entity $TANK stopped at .*: arrived"
vpos=$(stop $TANK $m)
python3 -I - "$vpos" <<'PY' || fail "the tank is not in the vault: $vpos"
import sys
x, y, z = map(float, sys.argv[1].split())
assert -43.6 < x < -39.4 and -13.6 < z < -10.4, (x, z)
print("ok: the tank drove into the vault through the dug plug: %.1f %.1f" % (x, z))
PY
say "frames 10" "screenshot $t/vault.png"

# ---- 6. A harvester's round trip: unloaded, the money up
await "$SL" 0 120 "local/rts_harvester $HARV: unloaded [0-9]+ at"
# (the money's line the second after the unload's)
ok=
for i in $(seq 10); do
	ok=$(python3 -I - "$SL" "$HARV" <<'PY'
import re, sys
s = open(sys.argv[1], "rb").read().decode(errors="replace")
u = s.index("local/rts_harvester %s: unloaded" % sys.argv[2])
after = [int(v) for v in re.findall(r"Blue's money: ([0-9]+)", s[u:])]
before = [int(v) for v in re.findall(r"Blue's money: ([0-9]+)", s[:u])]
if before and after and after[0] > before[-1]:
    print("ok: a harvester's load unloaded, Blue's money %d -> %d" % (before[-1], after[0]))
PY
)
	[ -n "$ok" ] && break
	sleep 0.5
done
[ -n "$ok" ] || fail "Blue's money did not go up with the unload ($SL)"
echo "$ok"

# ---- 7. The computer: buys, harvests, attacks (aggression 1)
m0=0
await "$SL" "$m0" 30 "local/rts_ai $AI: buys a "
for i in $(seq 600); do
	grep -aqE "local/rts_ai $AI: (sends [0-9]+ attackers|attacks )" "$SL" && break
	kill -0 "$SERVER_PID" 2>/dev/null || fail "the server is gone ($SL)"
	sleep 0.5
done
grep -aqE "local/rts_ai $AI: (sends [0-9]+ attackers|attacks )" "$SL" ||
	fail "the computer sent no attack in 5 min ($SL)"
reds=$(grep -aoP "made Red harvester \K[0-9]+" "$SL" | sort -u | tr '\n' '|')
grep -aqE "local/rts_harvester (${reds%|}): unloaded" "$SL" || fail "no Red harvester unloaded ($SL)"
echo "ok: the computer: $(grep -ac "local/rts_ai $AI: buys" "$SL") buys ($(grep -aoP "local/rts_ai $AI: buys a \K\w+" "$SL" | sort | uniq -c | tr -s ' ' | tr '\n' ',')), its harvesters unloaded, $(grep -aE "local/rts_ai $AI: (sends|attacks)" "$SL" | head -1 | grep -oP 'rts_ai [0-9]+: \K.*')"
say "frames 10" "screenshot $t/ai.png"

# ---- 8. Perf: 60 tanks in view (the cut on: the cavern under the rock)
# (try: the tools on, in the running round; then off, the rts camera back)
m=$(mark "$SL")
step 10 "kit editor: edit mode on" "keypress F6"
try "$MANY" go
await "$SL" "$m" 20 "many: 60 made"
n=$(grep -ac "kit: rts: the camera on" "$CL")
step 10 "kit editor: edit mode off" "keypress F6"
for i in $(seq 50); do
	[ "$(grep -ac "kit: rts: the camera on" "$CL")" -gt "$n" ] && break
	sleep 0.2
done
say "event kit_rts_focus 0 6.5 -3" "mouse_pos 512 350" "mouse_wheel -2" \
	"frames 600" "screenshot $t/many.png"
cmd quit
wait "$CLIENT" 2>/dev/null
CLIENT=
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
# (the game's save, not the app's own _ ones: _chat)
db=$(ls "$t"/user/apps/workbench/saves/*/save.sqlite | grep -v "/saves/_" | head -1)
perf()
{
	python3 -I - "$1" "$2" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
rows = []
for k, v in db.execute("select key, value from store where store = 'playtest'"):
    if not k.startswith("r/"):
        continue
    s = v.decode(errors="replace") if isinstance(v, bytes) else v
    try:
        j = json.loads(s)
        rows += j if isinstance(j, list) else [j]
    except ValueError:
        rows += [json.loads(l) for l in s.splitlines() if l.strip()]
pf = [r for r in rows if isinstance(r, dict) and r.get("kind") == "perf" and "draws" in r]
assert pf, "no perf rows with draws"
pf = pf[-2:]
print("%s: %s" % (sys.argv[2], ", ".join("%.0f fps, %d draws, %d tris, Kit %.2f ms" %
    (r["fps"], r["draws"], r["tris"], r["kit_ms"]) for r in pf)))
PY
}
perf "$db" native > "$t/perf" || fail "no native perf ($db)"
cat "$t/perf"

# ---- The web client: the same save, a match, the 60 tanks, its perf
# (Stop and Play first: the save's round ran on without its players)
web="web skipped (no Firefox or web/)"
if command -v "${FIREFOX:-firefox}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	w=$t/web
	name=$(basename "$(dirname "$db")")
	mkdir -p "$w/user/apps/workbench/saves/$name"
	cp "$db" "$w/user/apps/workbench/saves/$name/save.sqlite"
	cp -r "$BUILDAT_WORKBENCH_TYPES" "$w/user/apps/workbench/"
	export BUILDAT_WORKBENCH_TYPES=$w/user/apps/workbench/check_types BUILDAT_WORKBENCH_PROJECT=$name
	cat > "$t/steps.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "webrts"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "\${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Enter"], ["waitlog", "Joined as webrts", 30],
 ["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
 ["click", "Button", "Don't add"], ["frames", 3],
 ["waitlog_any", "shown, layer [0-9]+: \\"Deepcore", 60], ["frames", 10],
 ["key", "F6"], ["waitlog", "kit editor: edit mode on", 10],
 ["event", "kit_edit {\\"op\\": \\"stop\\"}"], ["waitlog", "kit editor: the server is Ended", 20],
 ["event", "kit_edit {\\"op\\": \\"play\\"}"], ["waitlog", "kit editor: the server is Running", 20],
 ["key", "F6"], ["waitlog", "kit editor: edit mode off", 10],
 ["waitlog", "shown, layer [0-9]+: \\"Deepcore", 60], ["frames", 10],
 ["shot", "\${OUT}/lobby.png"],
 ["click", "Button", "Play against the computer"],
 ["waitlog_any", "kit: rts: the camera on", 60], ["frames", 30],
 ["event", "kit_rts_where"], ["waitlog", "kit: rts: own units: [1-9]", 10], ["frames", 3],
 ["at_log", "kit: rts: unit [0-9]+ on the screen at ([0-9]+), ([0-9]+)", "click"],
 ["waitlog", "kit: rts: selected 1 [(]click on", 10],
 ["at_log", "kit: rts: unit [0-9]+ on the screen at ([0-9]+), ([0-9]+)", "box", -160, -160, 80, 80],
 ["waitlog", "kit: rts: selected [1-9][0-9]* [(]box", 10],
 ["event", "kit_rts_where -35,6.5,3"], ["waitlog", "kit: rts: point .* on the screen at", 10],
 ["at_log", "kit: rts: point [^ ]+ on the screen at ([0-9]+), ([0-9]+)", "rclick"],
 ["waitlog", "kit: rts: [1-9][0-9]* ordered", 10],
 ["shot", "\${OUT}/ordered.png"],
 ["key", "F6"], ["waitlog_any", "kit editor: edit mode on", 10], ["frames", 3],
 ["event", "kit_edit {\\"op\\": \\"try\\", \\"id\\": $MANY, \\"input\\": \\"go\\"}"], ["frames", 60],
 ["key", "F6"], ["waitlog_any", "kit editor: edit mode off", 10], ["frames", 30],
 ["event", "kit_rts_focus 0 6.5 -3"], ["frames", 600],
 ["event", "kit_rts"], ["waitlog_any", "kit: rts: camera at", 10],
 ["shot", "\${OUT}/many.png"]
]
J
	# (a high-DPI page: the mouse's clicks above at twice the CSS pixels)
	WEB_DRIVE_VIEWPORT=1200x800@2 "$here/util/web_drive.sh" firefox workbench "$t/steps.json" "$w" ||
		fail "the web drive ($w)"
	grep -aq "match started: computer" "$w/server.log" || fail "no web match ($w/server.log)"
	# The web's 60 tanks as bright as the native's (the views differ: the
	# frames' middles' means): under physical the meter took a mostly unseen
	# frame's 12x gain and the room read white (web 121 against native 29;
	# the native here is cartoon, a software GL)
	python3 -I - "$t/many.png" "$w/many.png" <<'PY' || fail "the web's room not as bright as the native's ($w/many.png, $t/many.png)"
import sys
from PIL import Image, ImageStat
def mid(f):
    im = Image.open(f).convert("L")
    w, h = im.size
    return ImageStat.Stat(im.crop((w // 5, h * 3 // 20, w * 4 // 5, h * 17 // 20))).mean[0]
n, b = mid(sys.argv[1]), mid(sys.argv[2])
assert n / 2 - 4 < b < n * 2 + 8, (n, b)
print("ok: the web's frame as bright as the native's: %.0f, native %.0f" % (b, n))
PY
	perf "$w/user/apps/workbench/saves/$name/save.sqlite" web >> "$t/perf" ||
		fail "no web perf ($w)"
	web=$(tail -1 "$t/perf")
fi
echo "PASS: Deepcore: new from the template, a match against the computer, the camera, select and order, a tank out of the factory's door, the digger through dirt and not hard rock, a tank through its tunnel, a harvester's money, fog, the computer's buys, harvests and attack; $(head -1 "$t/perf"); $web ($t)"
