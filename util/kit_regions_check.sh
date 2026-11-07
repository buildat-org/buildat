#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-01)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/box/box.c builtin/kit/types/region.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua apps/sample_kit/main/main.cpp apps/sample_kit/main/kit/guard.lua apps/workbench/main/main.cpp apps/workbench/main/client_lua/init.lua
# [KIT] stage 4j's regions with rules, by a player without edit rights
# (kitbob) beside the admin (kitboss, who builds them in Kit's editor):
#   1. apps/sample_kit (its "p" key digs the pillar at (6, 1, 2), asking
#      Kit's regions there). Placed: a big kit/region B (17, 5x3x5 round
#      the pillar, owned by the player "kitalice": dig for owners only), a
#      kit/region P (18, the pillar's cell alone, no digging), the prefab
#      sample_kit/guarded_region G (20: a kit/region, digging for all,
#      and sample_kit/guard, an allow hook refusing digs while on),
#      buttons 21, 22, 23 and 25 and a kit/logic L (24, "or"). End, Run.
#      kitbob digs the pillar after each use:
#        refused by P, the smallest ("Protected: no digging here");
#        21 disables P: refused by G's hook ("The guard says no");
#        22 disables G: refused by B (kitbob among everyone else);
#        23 turns L on, whose out sets B's dig for everyone: dug;
#        25 turns L off (B's dig for everyone off again) and sets B's
#        owner, by kitbob: dug by the owners' column.
#      Each refusal is told to kitbob's client (kit:warning).
#   2. apps/workbench (its players moved by Kit's controls). Placed: a
#      kit/spawner (3, at (0, 1, -4), players on) and a kit/region E (4, 5x3x3 ahead of
#      it, entering for owners only, show_border on). kitbob, put on the
#      spawner, sees E's border drawn in play, a click at the floor there
#      refused in the client and why ("Protected: no digging here"), walks
#      into E and is put back out and told ("Protected: no entering here").
#      A region (5) placed round the admin is not one they are put back
#      out of ([KIT_REGION_NEW_RULES_EMPTY]).
#
#   util/kit_regions_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_regions; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

client() # <name> <log name> <app>: its commands in $t/<log name>.cmds
{
	sed -i "s|@T@|$t|g" "$t/$2.cmds"
	run_client 60 "$t/$2.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1_$3" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$2.cmds" ||
		fail "client $2 failed ($t/$2.log, $t/srv_$3.log)"
}
stop()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
ed() { echo "event kit_edit $1"; }
code_of() # <server log>
{
	wait_for_log "$1" "setup code [A-Z0-9]+" 30
	grep -aoP 'setup code \K[A-Z0-9]+' "$1" | head -1
}

# 1. sample_kit: digs asked of the regions
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 10000 admin script: done
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
frames 3
wait_log_any 60000 replicated: entity 4 open = false
wait_log_any 60000 kit editor: edit rights: yes
click Button "Edit"
wait_log 10000 kit editor: state: 15 entities, 0 to undo
EOF
	n=0; c=15
	edit() { ed "$1"; n=$((n + 1)); echo "wait_log 10000 kit editor: state: $c entities, $n to undo"; }
	place() { c=$((c + 1)); edit "$1"; }
	setp() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": ${4:-0}, \"param\": \"$2\", \"value\": $3}"; }
	link() { edit "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"; }
	place '{"op": "place", "type": "kit/region", "pos": [4, 0, 0]}'
	setp 17 owner '"players"'
	setp 17 owners '"kitalice"'
	setp 17 dig '"owners"'
	place '{"op": "place", "type": "kit/region", "pos": [6, 1, 2]}'
	setp 18 size '[1, 1, 1]'
	c=$((c + 1))
	place '{"op": "place", "prefab": "sample_kit/guarded_region", "pos": [5, 0, 1]}'
	place '{"op": "place", "type": "kit/button", "pos": [1, 1, 1]}'
	place '{"op": "place", "type": "kit/button", "pos": [1, 1, -1]}'
	place '{"op": "place", "type": "kit/button", "pos": [-1, 1, 1]}'
	place '{"op": "place", "type": "kit/logic", "pos": [-1, 0, -1]}'
	setp 24 mode '"or"'
	place '{"op": "place", "type": "kit/button", "pos": [-1, 1, -1]}'
	link 21 pressed 18 disable
	link 22 pressed 20 disable
	link 23 pressed 24 a
	link 24 out 17 dig
	link 25 pressed 24 a_off
	link 25 pressed 17 set_owner
	cat <<'EOF'
click Button "End"
wait_log 10000 kit editor: the server is Ended (by kitboss)
click Button "Run"
wait_log 10000 kit editor: the server is Running (by kitboss)
quit
EOF
} > "$t/boss1.cmds"
# kitbob's dig of the pillar after each use, and what it is told
dig() # <what it is told, or "">
{
	echo "keypress p"
	# (the warning waited for from the keypress: it can come in the frame
	# the dig is sent, before a wait for that line's end begins)
	if [ -n "$1" ]; then
		echo "wait_log 10000 kit: warning: $1"
	else
		echo "wait_log 10000 a dig at the pillar sent"
		echo "sync 5000"
	fi
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 replicated: entity 17 owners = ["kitalice"]
wait_log_any 60000 replicated: entity 18 enabled = true
EOF
	dig "Protected: no digging here"
	echo "event kit_use 21"
	echo "wait_log 10000 replicated: entity 18 enabled = false"
	dig "The guard says no"
	echo "event kit_use 22"
	echo "wait_log 10000 replicated: entity 20 enabled = false"
	dig "Protected: no digging here"
	echo "event kit_use 23"
	echo "wait_log 10000 replicated: entity 24 out = true"
	echo "sync 5000"
	dig ""
	echo "event kit_use 25"
	echo 'wait_log 10000 replicated: entity 17 owners = ["kitbob"]'
	echo "sync 5000"
	dig ""
	echo "quit"
} > "$t/bob1.cmds"

start_server "$t/srv_kit.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/sample_kit -D "$t/user_kit" -l 3 ||
	fail "the server did not come up ($t/srv_kit.log)"
CHECK_PIDS+=($SERVER_PID)
code=$(code_of "$t/srv_kit.log")
[ -n "$code" ] || fail "no setup code ($t/srv_kit.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client kitboss boss1 kit
BUILDAT_JOIN_NAME=kitbob client kitbob bob1 kit
stop
s=$t/srv_kit.log
grep -a "kit/region 1[789]\|kit/region 20\|kit/logic 24\|sample_kit/guard 20\|a dig at the pillar" "$s" |
	sed 's/^.* I [a-z_]* *: /  /' | cut -c1-150 | tail -16
want "$s" "kit/region 17: holds dig owners, place none, enter all, pvp all, damage all, use all" \
	"kit/region 18: holds dig none, place none, enter all, pvp all, damage all, use all" \
	"kit/region 20: holds dig others, place none, enter all, pvp all, damage all, use all" \
	"kit/region 18: disabled by kitbob" "kit/region 20: disabled by kitbob" \
	"sample_kit/guard 20: asked dig at 6,1,2 by kitbob" \
	"kit/logic 24: or on by kitbob" "kit/region 17: dig on for everyone" \
	"kit/logic 24: or off by kitbob" "kit/region 17: dig off for everyone" \
	"kit/region 17: owner by kitbob"
digs=$(grep -aoP "sample_kit: a dig at the pillar: \K.*" "$s" | tr '\n' '|')
[ "$digs" = "refused: Protected: no digging here|refused: The guard says no|refused: Protected: no digging here|written|written|" ] ||
	fail "kitbob's digs went otherwise: $digs ($s)"
echo "ok: sample_kit: the smallest region decides, an allow hook refuses with its reason, everyone else's column refused, a rule's input and an owner set by signals let kitbob dig"

# 2. Workbench: a region kitbob may not enter
export BUILDAT_WORKBENCH_STONE=1 BUILDAT_WORKBENCH_PROJECT=world
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress Escape
wait_log 10000 pause: the menu shown
click Button "Edit"
wait_log 10000 kit editor: state: 1 entities, 0 to undo
EOF
	n=0; c=1
	edit() { ed "$1"; n=$((n + 1)); echo "wait_log 10000 kit editor: state: $c entities, $n to undo"; }
	place() { c=$((c + 1)); edit "$1"; }
	setp() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
	place '{"op": "place", "type": "kit/spawner", "pos": [0, 1, -4]}'
	setp 3 players true
	place '{"op": "place", "type": "kit/region", "pos": [-2, 0, -9]}'
	setp 4 size '[5, 3, 3]'
	setp 4 enter '"owners"'
	setp 4 show_border true
	# [KIT_REGION_NEW_RULES_EMPTY] a region placed round the admin, who
	# stands at (0.5, 1, 0.5): not put back (its rules unpublished read
	# as none for a moment)
	place '{"op": "place", "type": "kit/region", "pos": [-2, 0, -2]}'
	cat <<'EOF'
keypress Escape
wait_log 10000 pause: the menu shown
click Button "End" 512 350
wait_log 10000 kit editor: the server is Ended (by kitboss)
keypress Escape
wait_log 10000 pause: the menu shown
click Button "Run" 512 350
wait_log 10000 kit editor: the server is Running (by kitboss)
quit
EOF
} > "$t/boss2.cmds"
cat > "$t/bob2.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 the server put the player at (0, 1.4, -4)
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit: region 4 border 5x3x3 drawn in play
look_dir 0 -1 -0.5
frames 5
mouse_click left
wait_log 5000 kit: refused: Protected: no digging here
look_dir 0 -0.2 -1
frames 3
screenshot @T@/border.png
keydown W
delay 2500
keyup W
wait_log_any 10000 kit: warning: Protected: no entering here
sync 5000
frames 10
quit
EOF
start_server "$t/srv_wb.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user_wb" -l 3 ||
	fail "the server did not come up ($t/srv_wb.log)"
CHECK_PIDS+=($SERVER_PID)
code=$(code_of "$t/srv_wb.log")
[ -n "$code" ] || fail "no setup code ($t/srv_wb.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client kitboss boss2 wb
BUILDAT_JOIN_NAME=kitbob client kitbob bob2 wb
stop
s=$t/srv_wb.log
grep -a "kit/region 4\|may not enter\|kitbob" "$s" | sed 's/^.* I [a-z_]* *: /  /' |
	cut -c1-150 | tail -8
want "$s" "kit/region 4: holds dig none, place none, enter owners, pvp all, damage all, use all"
grep -aqE "kitbob may not enter \(-?[0-9]+,1,-7\): Protected: no entering here; put back" "$s" ||
	fail "kitbob was not put back at the region's edge ($s)"
# Put back out: never further in than its first row
grep -aoE "kitbob may not enter \(-?[0-9]+,[0-9]+,-?[0-9]+\)" "$s" |
	grep -vqE ",-7\)$" && fail "kitbob got further into the region ($s)"
# Put back at the height it walked in at, not lifted a little each time
grep -aoE "kitbob may not enter \(-?[0-9]+,[0-9]+,-?[0-9]+\)" "$s" |
	grep -vqE "\(-?[0-9]+,1,-?[0-9]+\)$" && fail "kitbob rose while put back ($s)"
grep -aq "kitboss may not enter" "$s" &&
	fail "the admin was put back by a region placed round them ($s)"
[ -s "$t/border.png" ] || fail "no screenshot of the border ($t)"
echo "PASS: Kit's regions: the smallest decides, an allow hook, the owners' and everyone else's columns, a rule's input and an owner by signals (sample_kit's digs); entering refused and put back, the border drawn, a refused click told why (Workbench); screenshot $t/border.png"
