#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~40 s (2026-11-17)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/api.h builtin/kit/client_lua/module.lua
# [KIT_AGENT_FEEDBACK_1117] (4), (6): a type's Lua reading its players and
# its per-player state. On Workbench, kitboss (the admin, on a headless
# weston's Xwayland of the check's own) places a probe (reads_players = true, a
# per_player state `own`) in the scene "world"; Running, each tick it
# counts one up in own for each player and logs c.players (name, p.scene,
# p.away), own's entries by pairs(c.state.own) and the state's keys by
# pairs(c.state) and next(c.state) (the state's proxy: Lua 5.1 has no
# __pairs, and they listed nothing). kitboss makes the scene "second" and
# is moved there: the probe in world sees him in second, away.
# [KIT_SMALL_PIECES] on_away: the probe in world gets it once as he goes to
# second (his c.players entry here, in second); a probe placed in second
# (joining him) gets it once as he quits (not here). The probe's client part
# reads its client_params' shown (and its change), not its other param.
#   util/kit_player_scene_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_player_scene; t=$CHECK_TMP
cd "$here/Build"
check_build
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
export BUILDAT_WORKBENCH_TYPES="$t/user/apps/workbench/check_types"
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
cat > "$BUILDAT_WORKBENCH_TYPES/probe.lua" <<'LUA'
return {
	version = 1,
	reads_players = true,
	state = {own = {default = {}, per_player = true}, ticks = {default = 0}},
	-- ([KIT_SMALL_PIECES] shown for its client part, hidden not)
	params = {shown = {type = "string", default = "seen"},
		hidden = {type = "string", default = "secret"}},
	client_params = {"shown"},
	on_start = function(c)
		c:after(0.2, "tick")
	end,
	on_timer = function(c)
		c.state.ticks = c.state.ticks + 1
		local list = {}
		for _, p in ipairs(c.players or {}) do
			c.state.own[p.by] = (c.state.own[p.by] or 0) + 1
			list[#list + 1] = p.name .. " in " .. tostring(p.scene) ..
					(p.away and " (away)" or "")
		end
		local entries, keys = 0, 0
		for _ in pairs(c.state.own) do entries = entries + 1 end
		for _ in pairs(c.state) do keys = keys + 1 end
		c:log("probe: " .. table.concat(list, ", ") .. "; own " .. entries ..
				", keys " .. keys .. ", next " .. tostring(next(c.state) ~= nil))
		c:after(0.2, "tick")
	end,
	-- [KIT_SMALL_PIECES] on_away: who, and their c.players entry then
	on_away = function(c, by)
		for _, p in ipairs(c.players or {}) do
			if p.by == by then
				c:log("probe away: " .. c:name(by) .. " from " .. c.id .. ", here " ..
						tostring(p.here) .. ", in " .. tostring(p.scene))
			end
		end
	end,
	on_join = function(c, by)
		c:log("probe join: " .. c:name(by) .. " at " .. c.id)
	end,
}
LUA
cat > "$BUILDAT_WORKBENCH_TYPES/probe.client.lua" <<'LUA'
local said = {}
return {
	on_update = function(e)
		local l = "probe client " .. e.id .. ": shown " .. tostring(e.params.shown) ..
				", hidden " .. tostring(e.params.hidden)
		if said[e.id] ~= l then
			said[e.id] = l
			e:log(l)
		end
	end,
}
LUA
sock=buildat-pps-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
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
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE=$code timeout 300 bin/buildat -C "$t/client_cache" \
	-D "$t/cu_boss" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 \
	-c - < "$t/boss.cmd" > "$CL" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/boss.cmd"
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 60 "player physics enabled"
await "$CL" 0 30 "kit editor: edit rights: yes"
step 20 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
step 10 "kit editor: the server is Ended" 'event kit_edit {"op": "stop"}'
m=$(mark "$SL")
cmd 'event kit_edit {"op": "place", "type": "workbench/probe", "pos": [0, 1, 2]}'
await "$SL" "$m" 10 "An edit by kitboss: placed workbench/probe"
# [KIT_SMALL_PIECES] client_params: its client part reads shown, not hidden;
# shown set, the new value
pid=$(tail -c +$((m + 1)) "$SL" | grep -aoP "An edit by kitboss: placed workbench/probe \K[0-9]+" | head -1)
await "$CL" 0 10 "probe client $pid: shown seen, hidden nil"
step 10 "probe client $pid: shown again, hidden nil" \
	"event kit_edit {\"op\": \"set\", \"id\": $pid, \"comp\": 0, \"param\": \"shown\", \"value\": \"again\"}"
echo "ok: client_params: the client part reads shown (and its change), not hidden"
m=$(mark "$SL")
step 10 "kit editor: the server is Running" 'event kit_edit {"op": "play"}'
await "$SL" "$m" 10 "probe join: kitboss at [0-9]+"
p1=$(tail -c +$((m + 1)) "$SL" | grep -aoP "probe join: kitboss at \K[0-9]+" | head -1)
m=$(mark "$SL")
await "$SL" "$m" 10 "probe: kitboss in world;"
m=$(mark "$SL")
step 20 "kit editor: in the scene second " 'event kit_edit {"op": "new_scene", "name": "second"}'
await "$SL" "$m" 10 "probe: kitboss in second \(away\);"
# [KIT_SMALL_PIECES] on_away: the probe in world as he went to second (here,
# in second); one placed in second, joined, as he leaves the game (not here)
await "$SL" "$m" 5 "probe away: kitboss from $p1, here true, in second$"
m=$(mark "$SL")
cmd 'event kit_edit {"op": "place", "type": "workbench/probe", "pos": [0, 1, 2]}'
await "$SL" "$m" 10 "probe join: kitboss at [0-9]+"
p2=$(tail -c +$((m + 1)) "$SL" | grep -aoP "probe join: kitboss at \K[0-9]+" | head -1)
[ "$p2" != "$p1" ] || fail "the second probe's join is the first's ($SL)"
m=$(mark "$SL")
cmd "quit"
exec 3>&-
wait $CLIENT
CLIENT=
await "$SL" "$m" 10 "probe away: kitboss from $p2, here false"
for p in $p1 $p2; do
	n=$(grep -ac "probe away: kitboss from $p," "$SL")
	[ "$n" = 1 ] || fail "probe $p's on_away $n times, not once ($SL)"
done
echo "ok: on_away once each: probe $p1 as kitboss went to second, probe $p2 as he left the game"
grep -aoE "probe: .*" "$SL" | uniq | head -4
grep -aq "probe: kitboss in world; own 1, keys 2, next true" "$SL" ||
	fail "no probe line with kitboss in world, own's entry and the state's two keys ($SL)"
grep -aq "probe: kitboss in second (away); own 1, keys 2, next true" "$SL" ||
	fail "the probe in world did not see kitboss in second, away ($SL)"
echo "PASS: a type's Lua: c.players' scene and away, a per_player state's entries and c.state's keys listed by pairs and next, on_away on a scene change and a leave, client_params ($t)"
