#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-16)
# covers: builtin/world_menu/** builtin/storage/storage.cpp apps/vanilla/main/client_lua/menu.lua
# [WORLD_MENU]: the shared world menu in skeldat, skelenti and vanilla,
# driven by the launcher's own client (-u launcher=1). In each, on a fresh
# server, a world made through New world... (skeldat's with the seed
# typed and the size picked from its choices; vanilla's New save..., the
# minimal game) and played; on
# the server started again, the world listed, renamed and deleted (to
# vanilla's trash), the list empty after.
#   builtin/world_menu/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp world_menu; t=$CHECK_TMP
b="$here/Build/bin/buildat"

# <app> <run> <cmds file>: a server on the app's tree under $t/<app>, one
# client through the commands
run()
{
	local app=$1 n=$2 cmds=$3
	BUILDAT_SKELDAT_WORLD= BUILDAT_SKELENTI_WORLD= BUILDAT_LUANTI_SAVE= \
		BUILDAT_LUANTI_GAME= start_server \
		"$t/$app.srv$n.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -u launcher=1 -m "$here/apps/$app" \
		-D "$t/$app/srv" -C "$t/$app/srv.cache" -l 3 ||
		fail "the server ($t/$app.srv$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	run_client 60 "$t/$app.cli$n.log" timeout 300 "$b" -C "$t/$app/c" \
		-D "$t/$app/u" -w 1100x700 -l 3 -o sound_mute=1 \
		-s "127.0.0.1:$SERVER_PORT" -c @"$cmds" ||
		fail "the drive ($t/$app.cli$n.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
}

for app in demo_skeldat demo_skelenti; do
	short=${app#demo_}
	{
		printf '%s\n' "wait_log 120000 world_menu: the list shown, 0 worlds" \
			'click Button "New world..."' \
			"wait_log 5000 world_menu: the name screen shown" "delay 300"
		# skeldat's seed, in its field (the empty one; the name's says world),
		# and its size from the choices, the fourth: 128 x 64 x 128
		[ $short = skeldat ] && printf '%s\n' 'click LineEdit ""' \
			"delay 300" "text 4242" "delay 300" 'click DropDownList "▼"' \
			"delay 500" "keypress Down" "keypress Down" "keypress Down" \
			"keypress Return" "wait_log 5000 world_menu: size picked: 128" \
			"delay 300"
		printf '%s\n' 'click Button "Create"' \
			"wait_log 180000 $([ $short = skeldat ] && echo 'skeldat: placed at' ||
				echo 'load: the world is in')" "quit"
	} > "$t/$short.cmds1"
	run $app 1 "$t/$short.cmds1"
	grep -aq 'world_menu: made "world"' "$t/$app.srv1.log" &&
		grep -aq "$short: the world \"world\" starts" "$t/$app.srv1.log" ||
		fail "$short: New world did not make and start \"world\" ($t/$app.srv1.log)"
	if [ $short = skeldat ]; then
		grep -aq 'the world "world" starts, seed 4242,.* 128 x 64 x 128' \
			"$t/$app.srv1.log" ||
			fail "skeldat: the seed or size option not used ($t/$app.srv1.log)"
		# The whole world made before the play, its progress in the menu
		grep -aq "world_menu: the wait shown: Making the world: 1 of 4" \
			"$t/$app.cli1.log" ||
			fail "skeldat: no progress while the world was made ($t/$app.cli1.log)"
	fi
	printf '%s\n' "wait_log 120000 world_menu: the list shown, 1 worlds" \
		'click Button "world"' "wait_log 5000 world_menu: the list shown" \
		"delay 300" "screenshot $t/$short.menu.png" 'click Button "Rename..."' \
		"wait_log 5000 world_menu: the name screen shown" "delay 300" \
		"text renamed" "delay 300" 'click Button "Rename"' \
		"wait_log 10000 world_menu: the list shown, 1 worlds" "delay 300" \
		'click Button "Delete..."' "delay 500" 'click Button "Delete"' \
		"wait_log 10000 world_menu: the list shown, 0 worlds" "quit" \
		> "$t/$short.cmds2"
	run $app 2 "$t/$short.cmds2"
	grep -aq 'world_menu: "world" renamed "renamed"' "$t/$app.srv2.log" &&
		grep -aq 'world_menu: "renamed" deleted' "$t/$app.srv2.log" ||
		fail "$short: not renamed and deleted ($t/$app.srv2.log)"
	[ ! -e "$t/$app/srv/apps/$app/saves/renamed" ] ||
		fail "$short: the deleted world's directory is still there"
	echo "  $short: made (and played), renamed, deleted"
done
# vanilla: its own New save... screens, then the shared list's Rename and
# Delete
printf '%s\n' "wait_log 120000 menu: 0 saves" "delay 1000" \
	'click Button "New save..."' "delay 800" 'click Button "minimal"' \
	"delay 800" 'click Button "Create and play"' \
	"wait_log 180000 load: the world is in" "quit" > "$t/vanilla.cmds1"
run vanilla 1 "$t/vanilla.cmds1"
grep -aq "The world is up" "$t/vanilla.srv1.log" ||
	fail "vanilla: New save did not start a world ($t/vanilla.srv1.log)"
printf '%s\n' "wait_log 120000 menu: 1 saves" "delay 1000" \
	'click Button "world*"' "wait_log 10000 menu: the world world shown" \
	"delay 300" 'click Button "Rename..."' \
	"wait_log 5000 world_menu: the name screen shown" "delay 300" \
	"text renamed" "delay 300" 'click Button "Rename"' \
	"wait_log 10000 menu: the world renamed shown" "delay 300" \
	'click Button "Delete..."' "delay 500" 'click Button "Move to the trash"' \
	"wait_log 10000 menu: 0 saves" "quit" > "$t/vanilla.cmds2"
run vanilla 2 "$t/vanilla.cmds2"
grep -aq "Save world renamed renamed" "$t/vanilla.srv2.log" &&
	grep -aq "Save renamed moved to .*/trash/renamed-" "$t/vanilla.srv2.log" ||
	fail "vanilla: not renamed and trashed ($t/vanilla.srv2.log)"
echo "  vanilla: made (and played), renamed, moved to the trash"
echo "PASS: the world menu in skeldat, skelenti and vanilla: a world made, played, renamed and deleted"
# vim: set noet ts=4 sw=4:
