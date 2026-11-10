#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~6 min (2026-11-10)
# covers: builtin/kit/kit.cpp builtin/kit/types/bot.lua builtin/kit/types/bot.client.lua builtin/kit/types/spawner.lua builtin/kit/types/pause_menu_action.lua builtin/kit/types/goal.lua builtin/kit/types/turret.lua builtin/kit/types/airship.lua builtin/kit/types/ui_player_list.lua builtin/kit/types/shop.lua builtin/kit/client_lua/module.lua apps/workbench/templates/ctf/** apps/workbench/templates/airships/**
# [KIT_BOT_DIFFICULTY] "Add bot" asks for the bot's knobs, on two fresh
# Workbench projects:
#   1. Capture the flag (a round for 2): "Add bot" in the pause menu opens
#      the dialog, the pointer free; aim, reaction and speed stepped
#      (50 %, 0.8 s, 70 %) and Add: the bot has them. A second one's dialog
#      starts at them; Cancel takes that bot away. A third, Add: the two
#      walk onto the pad, and in the round each one's copy has its knobs.
#   2. [KIT_AIRSHIPS_BOTS] Airships: two bots from the pause menu (the
#      dialog's defaults): one takes the bots' airship's gun (the balloons'
#      goal, priority 10), the other its helm (priority 5); the gunner fires
#      and hits a balloon, the helmsman flies out to them; the airship
#      deleted under them, both out of their seats and the server up.
#      [KIT_AIRSHIPS_BOTS_LEFTOVERS] The gunner's shots never hit its own
#      crew; the fly-out goal (49) is the helmsman's even when the gunner
#      enters its box first. kitboss, at the gun of a copy of their airship,
#      shoots at their helm: the bots fight back from their gun and hit him
#      or his ship.
#   3. [KIT_AIRSHIPS_BOTS_2] In 1, kitboss with a sword hits the first bot
#      on foot: it fights back by hand. In 2, a player list lists the bots
#      marked "(bot)". Then a round: kitboss onto the pad, the two bots
#      follow him in (the pad goal 54, on while a round runs), each into the
#      team with the fewest; kitboss buys a skiff at Red's shop. The bots
#      buy a skiff and a gun at their team's shops, put the gun on, take
#      the helm and the gun ("crew", goal 53), fly at the other team's ship
#      and hit it; the round's list shows them in their team's colour.
# Screenshots, kept with KEEP_TMP=1: $t/dialog.png, $t/airship.png, $t/round.png
#   util/kit_bot_knobs_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_bot_knobs; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
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
ed() { step 10 "kit editor: state:" "event kit_edit $1"; }
set_() { ed "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
srv() { await "$SL" "$SM" "$1" "$2"; }
srv_mark() { SM=$(mark "$SL"); }
srv_n() # <seconds> <count> <regex>: that many lines since the mark
{
	local i
	for i in $(seq $(($1 * 5))); do
		[ "$(tail -c +$((SM + 1)) "$SL" | grep -caE "$3")" -ge "$2" ] && return 0
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "not $2 of \"$3\" in $SL in $1 s ($CL)"
}
pause() # <button>: pressed in the pause menu
{
	step 10 "pause: the menu shown" "keypress Escape"
	cmd "frames 3" "click Button \"$1\""
}
# "Add bot", its dialog up: the spawner's id; BOT the bot's
add_bot() # <spawner>
{
	srv_mark
	local m=$(mark "$CL")
	pause "Add bot"
	srv 10 "kit/spawner $1: made [0-9]+"
	BOT=$(tail -c +$((SM + 1)) "$SL" | grep -aoP "kit/spawner $1: made \K[0-9]+" | head -1)
	await "$CL" "$m" 10 "kit: entity $BOT's client part: bot dialog shown"
	cmd "frames 3"
}
knob() { step 5 "bot dialog: $1 " "click Button \"bot $1 $2\"" "frames 2"; }
# A fresh server and kitboss on a new project from a template
open() # <name> <template>
{
	SL=$t/$1_srv.log CL=$t/$1_boss.log
	start_server "$SL" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/$1_user" -l 3 ||
		fail "the server did not come up ($SL)"
	CHECK_PIDS+=($SERVER_PID)
	wait_for_log "$SL" "setup code [A-Z0-9]+" 30
	local code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
	[ -n "$code" ] || fail "no setup code ($SL)"
	mkfifo "$t/$1_cmd"
	sleep 900 > "$t/$1_cmd" &
	FEED=$!
	CHECK_PIDS+=($FEED)
	# (not run_client: a job in the background reads /dev/null unless told)
	BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
		timeout 600 bin/buildat -C "$t/client_cache" -D "$t/$1_cu" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -c - < "$t/$1_cmd" > "$CL" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
	exec 3> "$t/$1_cmd"
	await "$CL" 0 120 "Joined as kitboss"
	cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
	step 30 "world_menu: the list shown" "frames 3"
	step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New project..."'
	cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
	step 10 "world_menu: template picked" "click Text \"$2\""
	step 60 "player physics enabled" "frames 3" 'click Button "Create"'
	await "$CL" 0 20 "kit editor: edit mode on"
}
play()
{
	srv_mark
	step 15 "the server is Running" 'event kit_edit {"op": "play"}'
	step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
}
close()
{
	cmd quit
	exec 3>&-
	wait $CLIENT 2>/dev/null
	kill $FEED 2>/dev/null
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
# 1. Capture the flag: the dialog, its knobs, a round
open ctf "Capture the flag"
BOSS=$(grep -aoP 'kitboss is entity \K[0-9]+' "$SL" | tail -1)
set_ 7 players 2
# [KIT_AIRSHIPS_BOTS_2] a sword for kitboss (75) by the bots' spawner
ed '{"op": "place", "type": "kit/item_giver", "pos": [6, 1, -6]}'
set_ 75 item '"kit/sword"'
play
cmd 'event kit_edit {"op": "mode", "on": true}'
cmd 'event kit_edit {"op": "walk_here", "pos": [4, 1, -6]}'
srv 10 "kitboss walks here"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
step 20 "kit: items: kit/sword" "event kit_use 75"
cmd "event kit_hold kit/sword"
add_bot 61
cmd "screenshot $t/dialog.png"
knob aim -
knob reaction +
knob reaction +
knob speed -
knob speed -
srv_mark
cmd 'click Button "bot add"' "event kit_hit $BOT"
B1=$BOT
srv 10 "kit/bot $B1: knobs: aim 50%, reaction 0.8 s, speed 70% by kitboss"
# [KIT_AIRSHIPS_BOTS_2] hit with the sword on foot, it fights back by hand
srv 10 "Bot $B1 is attacked by player:$BOSS \(kitboss\)"
srv 10 "kit/bot $B1: goal -1 attack \"fight back\""
srv 30 "kit/bot $B1: hits $BOSS with a hand for goal -1"
add_bot 61
B2=$BOT
srv_mark
cmd 'click Button "bot cancel"'
srv 10 "kit/bot $B2: cancelled by kitboss"
add_bot 61
B3=$BOT
srv_mark
cmd 'click Button "bot add"'
srv 10 "kit/bot $B3: knobs: aim 50%, reaction 0.8 s, speed 70% by kitboss"
srv_mark
srv 90 "kit/arena 7: countdown over: a round for 2 players"
srv 30 "Bot $B1 into session [0-9]+ as Bot"
srv 30 "Bot $B3 into session [0-9]+ as Bot"
srv 10 "knobs: aim 50%, reaction 0.8 s, speed 70%"
close
# 2. Airships: a crew of two bots on the bots' airship
open air "Airships"
BOSS=$(grep -aoP 'kitboss is entity \K[0-9]+' "$SL" | tail -1)
# kitboss's gunboat: a copy of the bots' airship beside it (55, its gun 57)
ed '{"op": "copy", "ids": [40]}'
ed '{"op": "place", "clipboard": true, "pos": [4, 3, -14]}'
# [KIT_AIRSHIPS_BOTS_2] a player list (58)
ed '{"op": "place", "type": "kit/ui_player_list", "pos": [0, 1, 0]}'
play
srv 20 "Entity 42's kit/turret steps in play"
srv 20 "Entity 57's kit/turret steps in play"
for i in 1 2; do
	add_bot 50
	srv_mark
	cmd 'click Button "bot add"'
	srv 10 "kit/bot $BOT: knobs: aim 75%, reaction 0.4 s, speed 90% by kitboss"
done
SM=0
srv 30 "Bot [0-9]+ takes the seat of entity 42"
srv 30 "Bot [0-9]+ takes the seat of entity 41"
cmd "frames 30" "screenshot $t/airship.png"
srv 60 "Bot [0-9]+ fires entity 42's kit/turret"
srv 150 "Bot [0-9]+'s projectile [0-9]+ hits entity 4[3-7]"
srv 150 "kit/goal 49: done"
# kitboss at his gun shoots at their helm: they fight back
srv_mark
cmd 'event kit_edit {"op": "mode", "on": true}'
cmd 'event kit_edit {"op": "walk_here", "pos": [4, 4.5, -11]}'
srv 10 "kitboss walks here"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
step 10 "kit: aiming at 41" "event kit_use 57" "frames 10" "event kit_aim 41 45 3 fire"
srv 30 "kitboss's projectile [0-9]+ hits entity (40|4[12])"
srv 20 "Bot [0-9]+ is attacked by player:$BOSS \(kitboss\)"
srv 30 "kit/bot [0-9]+: goal -1 attack \"fight back\""
srv 60 "Bot [0-9]+'s projectile [0-9]+ hits entity (55's cell|$BOSS\$)"
cmd "event kit_aim 0" "frames 10" "screenshot $t/fight_back.png"
# The bots' airship deleted under its helmsman (in the user's playtest it
# was shot down): out of the seat, the server up (the drive loop erased
# the drive it was on and crashed)
srv_mark
cmd 'event kit_edit {"op": "mode", "on": true}'
ed '{"op": "delete", "id": 40}'
srv 10 "Bot [0-9]+ leaves the seat of entity 4[12]: the seat is gone"
# Still up: it answers an edit
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
# 3. [KIT_AIRSHIPS_BOTS_2] A round: kitboss onto the arena's pad; the two bots
# follow him in (goal 54, on while a round runs), each into the team with
# the fewest; kitboss buys a skiff at Red's shop (22). The bots buy, arm and
# crew their team's ship, fly at the other team's and shoot it
# (the practice goals' via went with the airship: a round refuses a
# dangling id)
cmd 'event kit_edit {"op": "mode", "on": true}'
set_ 48 via 0
set_ 49 via 0
srv_mark
cmd 'event kit_edit {"op": "walk_here", "pos": [2.5, 1, -2.5]}'
srv 10 "kitboss walks here"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
srv 30 "kit/arena 14: countdown over: a round for 1 players"
srv 10 "kit/goal 54: active for everyone"
srv_n 60 2 "Bot [0-9]+ into session [0-9]+ as Bot [0-9]+"
cmd "event kit_use 22"
srv 20 "sold kit/airship_skiff to kitboss as [0-9]+"
srv 60 "sold kit/airship_skiff to Bot [0-9]+ as [0-9]+"
srv 60 "Bot [0-9]+ puts kit/airship_gun on entity [0-9]+"
srv 60 "Bot [0-9]+ takes the seat of entity [0-9]+"
srv 120 "Bot [0-9]+ fires entity [0-9]+'s kit/turret from"
srv 150 "Bot [0-9]+'s projectile [0-9]+ hits entity [0-9]+'s cell"
cmd "frames 30" "screenshot $t/round.png"
close
python3 -I - "$t" <<'PY' || fail "the logs say otherwise ($t)"
import re, sys
t = sys.argv[1]
srv = open(f"{t}/ctf_srv.log", errors="replace").read()
cl = open(f"{t}/ctf_boss.log", errors="replace").read()
K = "aim 50%, reaction 0.8 s, speed 70%"
made = re.findall(r"kit/spawner 61: made (\d+)", srv)
if len(made) != 3:
	sys.exit(f"bots made: {made}")
b1, b2, b3 = made
# The dialog: the pointer free; the second one started at the first's answer
if re.search(r"bot dialog shown, the pointer free: false", cl):
	sys.exit("a dialog did not free the pointer")
starts = re.findall(r"kit: entity (\d+)'s client part: bot dialog shown, the pointer free: true: (.*)", cl)
if [s for b, s in starts] != ["aim 75 reaction 0.4 speed 90", "aim 50 reaction 0.8 speed 70",
		"aim 50 reaction 0.8 speed 70"]:
	sys.exit(f"the dialogs started at {starts}")
# The cancelled one is gone, the two others into the round with their knobs
into = dict((b, c) for b, s, c in re.findall(r"Bot (\d+) into session (\d+) as Bot (\d+)", srv))
if sorted(into) != sorted([b1, b3]):
	sys.exit(f"into the round: {into} (made {made}, {b2} cancelled)")
for b, c in into.items():
	if not re.search(rf"kit/bot {c}: knobs: {K}", srv):
		sys.exit(f"Bot {b}'s copy {c} has not its knobs")
# [KIT_AIRSHIPS_BOTS_2] on foot: B1 hit by kitboss's sword hits him back by hand
foot = re.findall(rf"kit/bot {b1}: (hits|misses) (\d+) with a hand for goal -1", srv)
if not foot or ("hits", foot[0][1]) not in foot:
	sys.exit(f"Bot {b1} did not hit kitboss back on foot: {foot}")
# Airships: the gunner and the helmsman are two
srv = open(f"{t}/air_srv.log", errors="replace").read()
gun = re.search(r"(Bot \d+) takes the seat of entity 42", srv).group(1)
helm = re.search(r"(Bot \d+) takes the seat of entity 41", srv).group(1)
if gun == helm:
	sys.exit(f"one bot at both stations: {gun}")
shots = len(re.findall(rf"{gun} fires entity 42's kit/turret", srv))
hits = re.findall(rf"{gun}'s projectile \d+ hits entity (4[3-7])", srv)
if not hits:
	sys.exit(f"the gunner {gun} hit no balloon in {shots} shots")
# [KIT_AIRSHIPS_BOTS_LEFTOVERS] its own crew never hit; 49 the helmsman's
crew = re.findall(rf"Bot \d+'s projectile \d+ hits entity ({gun[4:]}|{helm[4:]})$", srv, re.M)
if crew:
	sys.exit(f"a bot's shot hit its own crew: {crew}")
by = re.findall(r"kit/goal 49: done for everyone by (Bot \d+)", srv)
if by != [helm]:
	sys.exit(f"goal 49 done by {by}, not the helmsman {helm}")
back = re.findall(r"(Bot \d+)'s projectile \d+ hits entity (55's cell \S+|\d+)$", srv[srv.find("is attacked by player:"):], re.M)
# [KIT_AIRSHIPS_BOTS_2] the list: the bots marked, in the lobby and the round
# (with their team's colour)
if not re.search(r"kit/ui_player_list 58: players: .*Bot \d+ \(bot\)  0", srv):
	sys.exit("no bot marked in the lobby's player list")
r = srv[srv.find("countdown over: a round for 1 players"):]
if not re.search(r"kit/ui_player_list 58: players: .*Bot \d+ \(bot\) #(d03030|3050e0) ", r):
	sys.exit("no bot with its team's colour in the round's player list")
# The round: the teams, the ships sold, a bot's hit on the other team's ship
team = dict(re.findall(r"kit/team \d+: (kitboss|Bot \d+) joins team (Red|Blue)", r))
bots = [n for n in team if n != "kitboss"]
if len(bots) != 2 or team.get("kitboss") != "Red":
	sys.exit(f"the round's teams: {team}")
ship = {}
for who, sid in re.findall(r"sold kit/airship_skiff to (kitboss|Bot \d+) as (\d+)", r):
	ship[sid] = team[who]
rhits = [(b, sid) for b, sid in re.findall(r"(Bot \d+)'s projectile \d+ hits entity (\d+)'s cell", r)
	if sid in ship and ship[sid] != team[b]]
if not rhits:
	sys.exit(f"no bot hit the other team's ship (ships {ship}, teams {team})")
shooter = rhits[0][0]
fires = [(float(x), float(z)) for x, z in re.findall(
	rf"{shooter} fires entity \d+'s kit/turret from \(([-\d.]+), [-\d.]+, ([-\d.]+)\)", r)]
# (its ship from its pad, x +-40: toward the middle)
moved = min(abs(x) for x, z in fires)
if moved > 35:
	sys.exit(f"{shooter}'s ship did not move: its gun fired from {fires[:3]}")
helms = re.findall(r"kit/bot (\d+): takes the helm at \d+ for goal 53", r)
if not helms:
	sys.exit("no bot took a helm for the crew goal")
print(f"ctf: bots {b1} {b3} into the round as {into[b1]} {into[b3]} with {K}, {b2} cancelled; "
	f"airships: gunner {gun} {shots} shots, hits {hits}; helmsman {helm} flew out; "
	f"fighting back: {back[:4]}; on foot: {foot[:3]}; round: teams {team}, ships {ship}, "
	f"{shooter} hit {rhits[0][1]} from |x| {moved}, helms by {helms}")
PY
verdict_keep
[ "$verdict_rc" = 0 ] && echo "PASS: Add bot's dialog sets a bot's knobs, its round copy has them; an airship crewed by bots; a bot fights back on foot; bots in an airships round crew, fly and hit; bots marked in the player list"
verdict_exit
# vim: set noet ts=4 sw=4:
