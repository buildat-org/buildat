#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~5 min (2026-11-19)
# covers: builtin/kit/types/bot.lua builtin/kit/types/bot.client.lua builtin/kit/types/path.lua builtin/kit/types/bot_driver.prefab.json apps/workbench/templates/brimstone_speedway/types/brim_race.lua apps/workbench/templates/brimstone_speedway/types/brim_yard.lua apps/workbench/templates/brimstone_speedway/composition.json util/kit_racer_drive.py
# [KIT_BOT_DRIVE] (4z37i (4)) Driving bots in Brimstone Speedway: one
# server, kitboss (the admin) on a headless weston's Xwayland of the
# check's own, a new project from the template:
#   1. Race: kitboss on the grid; the pause menu's Add bot, Remove all bots
#      not there (no bot yet); Add bot twice, its dialog's one row (Skill):
#      a bot at skill 100 and one at 0, each onto the grid (slots 2 and 3:
#      the fast one ahead, as bots do not overtake);
#      Remove all bots in the menu now;
#   2. Start: kitboss driven round by util/kit_racer_drive.py (kit_racer's
#      driver), the bots by Kit's (kit/bot drive on the Bone Yard's racing
#      line, kit/path): every checkpoint passed in order and 3 laps each
#      within 240 s of GO, the faster the higher the skill; no crate taken
#      by a bot, no lap record; kitboss's result card with both bots on it
#      (race.png, result.png); the lap times by skill and kitboss's;
#   3. the bots back on the grid when it is over; Remove all bots: both
#      gone, the menu item with them.
# Screenshots, kept with KEEP_TMP=1: $t/race.png, $t/result.png
#   util/kit_racer_bots_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_racer_bots; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build

python3 -I - "$here/apps/workbench/templates/brimstone_speedway/composition.json" \
		> "$t/ids" <<'PY' || fail "the template's composition"
import json, sys
d = json.load(open(sys.argv[1]))
world = [e["id"] for e in d["entities"] if e.get("kind") == "scene" and e["name"] == "world"][0]
def find(name):
    return [e["id"] for e in d["entities"] if e.get("name") == name and e.get("parent") == world][0]
print("RACE=%d SPAWNER=%d" % (find("the race"), find("bots' spawner")))
PY
. "$t/ids"
export PATH_PTS="-100,-58,12 60,-58,10 60,-34,10 10,-34,9 0,-14,9 30,0,10 95,0,12 95,55,12 50,55,9 40,30,8 25,30,8 15,58,10 -40,58,12 -55,20,10 -30,5,9 -60,-10,10 -100,-20,12"

sock=buildat-racerbots-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
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
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
# The pause menu: its items line matching <regex> and not <regex 2> (if
# given), then Continue
pause_items() # <regex> [regex 2]
{
	local i m items=
	for i in $(seq 10); do
		m=$(mark "$CL")
		step 10 "pause: the items" "keypress Escape"
		items=$(tail -c +$((m + 1)) "$CL" | grep -a "pause: the items" | tail -1)
		echo "$items" | grep -qE "$1" && break
		step 10 "pause: the menu closed" "frames 3" 'click Button "Continue"'
		sleep 1
	done
	echo "$items" | grep -qE "$1" || fail "the pause menu not \"$1\": $items ($CL)"
	[ -z "${2:-}" ] || ! echo "$items" | grep -qE "$2" ||
		fail "the pause menu with \"$2\": $items ($CL)"
	step 10 "pause: the menu closed" "frames 3" 'click Button "Continue"'
}
# Add bot, its dialog's Skill (from where it starts: the last sent, else
# the bot's) pressed to <skill>, Add: BOT its id
add_bot() # <skill>
{
	local m=$(mark "$SL") mc=$(mark "$CL") i s
	step 10 "pause: the menu shown" "keypress Escape"
	cmd "frames 3" 'click Button "Add bot"'
	await "$SL" "$m" 10 "kit/spawner $SPAWNER: made [0-9]+"
	BOT=$(tail -c +$((m + 1)) "$SL" | grep -aoP "kit/spawner $SPAWNER: made \K[0-9]+" | head -1)
	await "$CL" "$mc" 10 "kit: entity $BOT's client part: bot dialog shown, the pointer free: true: skill [0-9]+"
	s=$(tail -c +$((mc + 1)) "$CL" | grep -aoP "entity $BOT's client part: bot dialog shown, .*: skill \K[0-9]+" | head -1)
	for i in $(seq $(((${1} - s) / 10))); do
		step 5 "bot dialog: skill " "frames 2" 'click Button "bot skill +"'
	done
	for i in $(seq $(((s - ${1}) / 10))); do
		step 5 "bot dialog: skill " "frames 2" 'click Button "bot skill -"'
	done
	await "$CL" "$mc" 2 "bot dialog: skill $1%"
	cmd "frames 2" 'click Button "bot add"'
	await "$SL" "$m" 10 "knobs: skill $1% by kitboss"
	await "$SL" "$m" 10 "local/brim_race $RACE: Driver $BOT is on the grid, slot [0-9]+"
}
drive() # <who> <seconds> <stop regex>: kit_racer's driver on that client
{
	python3 -I "$here/util/kit_racer_drive.py" "$t/$1.log" "$t/$1.cmd" "$2" "$3" > "$t/drive_$1.log" 2>&1
}
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate 1 || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
mkfifo "$t/boss.cmd"
sleep 900 > "$t/boss.cmd" &
CHECK_PIDS+=($!)
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	timeout 900 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
	< "$t/boss.cmd" > "$CL" 2>&1 &
BOSS=$!
CHECK_PIDS+=($BOSS)
exec 3> "$t/boss.cmd"
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don*"'
await "$CL" 0 30 "world_menu: the list shown"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Brimstone Speedway"'
step 120 "kit editor: edit mode on" "frames 3" 'click Button "Create"'
# (the slowest bot some 50 s behind kitboss at worst: no "out of time")
step 10 "entities, 1 to undo" "event kit_edit {\"op\": \"set\", \"id\": $RACE, \"comp\": 0, \"param\": \"time_out\", \"value\": 200}"
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$CL" 0 10 'kit: ui [0-9]+ list .* shown, layer [0-9]+: "Pick your poison'

# 1. On the grid, two bots added: skill 0 and 100
m=$(mark "$SL")
step 10 "kit: ui full screen none" "frames 3" 'click Button "Race: The*"'
await "$SL" "$m" 5 "local/brim_race $RACE: kitboss is on the grid, slot 1"
pause_items "Add bot" "Remove all bots"
add_bot 100
FAST=$BOT
add_bot 0
SLOW=$BOT
pause_items "Remove all bots"
echo "ok: Add bot twice from the pause menu, its dialog's Skill: Driver $FAST at skill 100, Driver $SLOW at 0, both on the grid; Remove all bots shown"

# 2. The race
m=$(mark "$SL")
mc=$(mark "$CL")
cmd "frames 3" 'click Button "Start the race"'
await "$SL" "$m" 5 "local/brim_race $RACE: kitboss starts the race: 3 cars"
await "$CL" "$mc" 10 '"GO! Eat dirt, scrap heaps!"'
SHOTS="-20,-58,$t/race.png" drive boss 300 'panel .* shown, layer [0-9]+: "The flag is down' ||
	fail "kitboss's driver: $(tail -2 "$t/drive_boss.log")"
await "$SL" "$m" 240 "local/brim_race $RACE: the race is over: everyone finished"
step 10 "Wrote screenshot $t/result.png" "frames 10" "screenshot $t/result.png"
python3 -I - "$SL" "$m" "$CL" "$mc" "$RACE" "$SLOW" "$FAST" <<'PY' || fail "the race ($SL)"
import re, sys
log, at, cl, cat, race, slow, fast = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), *sys.argv[5:]
L = open(log, "rb").read()[at:].decode(errors="replace").splitlines()
def t(l):
    h, m, s = re.search(r"(\d+):(\d+):([\d.]+) ", l).groups()
    return int(h) * 3600 + int(m) * 60 + float(s)
pre = "local/brim_race %s: " % race
# (GO: the client's announcer line, the logs' clocks the same)
go = t(next(l for l in open(cl, "rb").read()[cat:].decode(errors="replace").splitlines()
            if "GO! Eat dirt" in l))
def run(who):
    order = [re.sub(r".*?" + re.escape(pre + who) + " ", "", l) for l in L if pre + who + " " in l]
    want = []
    for lap in (1, 2, 3):
        want += ["passed checkpoint %d of 3" % k for k in (1, 2, 3)] + ["completed lap %d" % lap]
    got = [o for o in order if o.startswith("passed checkpoint") or o.startswith("completed lap")]
    assert got == want, (who, got)
    laps = [t(l) for l in L if pre + who + " completed lap" in l]
    fin = [l for l in L if pre + who + " finished" in l]
    assert fin, (who, "no finish")
    return [b - a for a, b in zip([go] + laps, laps)], t(fin[0]) - go
s_laps, s_t = run("Driver " + slow)
f_laps, f_t = run("Driver " + fast)
b_laps, b_t = run("kitboss")
assert s_t < 240 and f_t < 240, (s_t, f_t)
assert f_t < s_t, ("skill 100 not faster than 0", f_t, s_t)
text = "\n".join(L)
assert not re.search(r"Driver \d+ picks up", text), "a bot took a crate"
assert not re.search(r"Driver \d+ lap .*record", text), "a lap record by a bot"
card = [l for l in open(cl, errors="replace") if re.search(r'shown, layer [0-9]+: "You: ', l)][-1]
assert "Driver " + slow in card and "Driver " + fast in card, card
fmt = lambda v: " ".join("%.1f" % x for x in v)
print("ok: 3 laps, every checkpoint in order: skill 0 in %.1f s (laps %s), skill 100 in %.1f s "
      "(laps %s), kitboss (kit_racer's driver) in %.1f s (laps %s); no crate, no record"
      % (s_t, fmt(s_laps), f_t, fmt(f_laps), b_t, fmt(b_laps)))
print("ok: kitboss's result card: " + re.search(r'"You: .*', card)[0])
PY

# 3. Back on the grid; Remove all bots
await "$SL" "$m" 10 "local/brim_race $RACE: Driver $SLOW is on the grid"
m=$(mark "$SL")
step 10 "pause: the menu shown" "keypress Escape"
cmd "frames 3" 'click Button "Remove all bots"'
await "$SL" "$m" 10 "kitboss removed all bots \(2\)"
pause_items "Continue" "Remove all bots"
echo "ok: the bots back on the grid after the race; Remove all bots: both gone, the item with them"
cmd "quit"
echo "PASS: Brimstone Speedway's driving bots: Add bot with its Skill row, onto the grid, 3 laps over every checkpoint at skill 0 and 100 (100 faster), on kitboss's result card, no crate or record; back on the grid, Remove all bots; screenshots $t/race.png $t/result.png"
# vim: set noet ts=4 sw=4:
