#!/bin/bash
# tier: full
# cost: ~6 min (2026-10-17)
# covers: builtin/world_menu/** builtin/storage/storage.cpp apps/skeldat/launcher/init.lua apps/vanilla/main/client_lua/menu.lua apps/skeldat/main/client_lua/join.lua
# [WORLD_MENU]: the shared world menu in skeldat, skelenti and vanilla,
# driven by the launcher's own client (-u launcher=1). In each, on a fresh
# server, a world made through New world... (skeldat's with the seed
# typed and the size picked from its choices; vanilla's New save..., the
# minimal game) and played; on
# the server started again, the world listed, renamed and deleted (to
# vanilla's trash), the list empty after. skeldat started with the
# launcher's save= ([SKELDAT_LAUNCH_WORLD]): a missing one is the menu,
# an existing one played says Loading, "world" starts with no list.
# menu=worlds world= ([SKELDAT_SAVE_WORLD_MENU]): the menu with that
# world selected, none for a missing one.
# skeldat on a public server: the admin made by the setup code picks
# ([WORLD_MENU_ADMIN]).
#   builtin/world_menu/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp world_menu; t=$CHECK_TMP
b="$here/Build/bin/buildat"

# <app> <run> <cmds file> [-u lines]: a server on the app's tree under
# $t/<app>, one client through the commands
run()
{
	local app=$1 n=$2 cmds=$3 launch=${4:-launcher=1}
	BUILDAT_SKELDAT_WORLD= BUILDAT_SKELENTI_WORLD= BUILDAT_LUANTI_SAVE= \
		BUILDAT_LUANTI_GAME= start_server \
		"$t/$app.srv$n.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -u "$launch" -m "$here/apps/$app" \
		-D "$t/$app/srv" -C "$t/$app/srv.cache" -l 3 ||
		fail "the server ($t/$app.srv$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	run_client 60 "$t/$app.cli$n.log" timeout 300 "$b" -C "$t/$app/c" \
		-D "$t/$app/u" -w 1100x700 -l 3 -o sound_mute=1 \
		-s "127.0.0.1:$SERVER_PORT" -c @"$cmds" ||
		fail "the drive ($t/$app.cli$n.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
}

for app in skeldat demo_skelenti; do
	short=${app#demo_}
	{
		printf '%s\n' "wait_log 120000 world_menu: the list shown, 0 worlds" \
			'click Button "New world..."' \
			"wait_log 5000 world_menu: the name screen shown" "delay 300"
		# skeldat's seed, in its field (the empty one; the name's says world);
		# its size and bone speed the defaults, 256 x 64 x 256 at 1x
		# ([SKELDAT_BONE_SPEED], [SKELDAT_TUNE_256])
		[ $short = skeldat ] && printf '%s\n' 'click LineEdit ""' \
			"delay 300" "text 4242" "delay 300"
		printf '%s\n' 'click Button "Create"' \
			"wait_log 180000 $([ $short = skeldat ] && echo 'skeldat: placed at' ||
				echo 'load: the world is in')" "quit"
	} > "$t/$short.cmds1"
	run $app 1 "$t/$short.cmds1"
	grep -aq 'world_menu: made "world"' "$t/$app.srv1.log" &&
		grep -aq "$short: the world \"world\" starts" "$t/$app.srv1.log" ||
		fail "$short: New world did not make and start \"world\" ($t/$app.srv1.log)"
	if [ $short = skeldat ]; then
		grep -aq 'the world "world" starts, seed 4242,.* 256 x 64 x 256' \
			"$t/$app.srv1.log" && grep -aq "the bones at 1x" "$t/$app.srv1.log" ||
			fail "skeldat: the seed option not used, or not the default size and speed ($t/$app.srv1.log)"
		# The whole world made before the play, its progress in the menu
		grep -aq "world_menu: the wait shown: Making the world: 1 of 16" \
			"$t/$app.cli1.log" ||
			fail "skeldat: no progress while the world was made ($t/$app.cli1.log)"
		# [SKELDAT_LAUNCH_WORLD] The launcher's save=: one that is no world
		# is the menu, where "world" played says Loading; "world" itself
		# starts with no list
		printf '%s\n' "wait_log 120000 world_menu: the list shown, 1 worlds" \
			'click Button "world"' "wait_log 5000 world_menu: the list shown" \
			"delay 300" 'click Button "Play"' \
			"wait_log 180000 skeldat: placed at" "quit" > "$t/skeldat.cmds_l1"
		run $app l1 "$t/skeldat.cmds_l1" "$(printf 'launcher=1\nsave=nosuch')"
		grep -aq 'the launch.s save "nosuch" is no world' "$t/$app.srvl1.log" ||
			fail "skeldat: save=nosuch not said ($t/$app.srvl1.log)"
		grep -aq "world_menu: the wait shown: Loading the world" "$t/$app.clil1.log" &&
			! grep -aq "the wait shown: Making" "$t/$app.clil1.log" ||
			fail "skeldat: an existing world not Loading ($t/$app.clil1.log)"
		printf '%s\n' "wait_log 120000 skeldat: placed at" "quit" > "$t/skeldat.cmds_l2"
		run $app l2 "$t/skeldat.cmds_l2" "$(printf 'launcher=1\nsave=world')"
		grep -aq 'the world "world" starts' "$t/$app.srvl2.log" &&
			! grep -aq "world_menu: the list shown" "$t/$app.clil2.log" ||
			fail "skeldat: save=world not started without the menu ($t/$app.srvl2.log)"
		echo "  skeldat: the launch's save= started, a missing one the menu, Loading said"
		# [SKELDAT_SAVE_WORLD_MENU] A save's "World menu..." (its launcher's
		# for_save entry): menu=worlds world=<save>. A copy of "world" as
		# "other", newer, listed first: world=world the menu with "world"
		# selected and no world started until its Play; world=nosuch the
		# menu with none selected
		luajit -e "local e = dofile('$here/apps/skeldat/launcher/init.lua')({launch = function(a)
			assert(a.app == 'skeldat' and a.params.menu == 'worlds' and a.params.world == 'w1') end})
			for _, x in ipairs(e) do if x.for_save then assert(x.label == 'World menu...'); x.run('w1'); return end end
			error('no for_save entry')" || fail "skeldat: the launcher's World menu... entry"
		cp -r "$t/$app/srv/apps/$app/saves/world" "$t/$app/srv/apps/$app/saves/other"
		touch "$t/$app/srv/apps/$app/saves/other"
		printf '%s\n' "wait_log 120000 world_menu: the list shown, 2 worlds" \
			"delay 500" "screenshot $t/skeldat.selected.png" 'click Button "Play"' \
			"wait_log 180000 skeldat: placed at" "quit" > "$t/skeldat.cmds_l3"
		run $app l3 "$t/skeldat.cmds_l3" "$(printf 'launcher=1\nmenu=worlds\nworld=world')"
		grep -aq "world_menu: world selected" "$t/$app.clil3.log" &&
			sed -n '/world_menu: "world" selected/,$p' "$t/$app.srvl3.log" |
				grep -aq 'the world "world" starts' &&
			! sed -n '1,/world_menu: "world" selected/p' "$t/$app.srvl3.log" |
				grep -aq 'the world ".*" starts' ||
			fail "skeldat: world=world not selected, or a world started before its Play ($t/$app.srvl3.log)"
		printf '%s\n' "wait_log 120000 world_menu: the list shown, 2 worlds" \
			"delay 1000" "quit" > "$t/skeldat.cmds_l4"
		run $app l4 "$t/skeldat.cmds_l4" "$(printf 'launcher=1\nmenu=worlds\nworld=nosuch')"
		grep -aq 'no world "nosuch" to select' "$t/$app.srvl4.log" &&
			! grep -aq "world_menu: .* selected" "$t/$app.clil4.log" &&
			! grep -aq 'the world ".*" starts' "$t/$app.srvl4.log" ||
			fail "skeldat: world=nosuch selected something or started a world ($t/$app.srvl4.log)"
		rm -r "$t/$app/srv/apps/$app/saves/other"
		echo "  skeldat: World menu... with its save selected, none for a missing one"
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
	# [SKELDAT_HIGH_SCORES] Presets: none for an app that sets none, nor
	# for skeldat with no score yet
	grep -aq "world_menu: 0 presets" "$t/$app.cli1.log" ||
		fail "$short: presets in the list ($t/$app.cli1.log)"
	echo "  $short: made (and played), renamed, deleted"
done
# [WORLD_MENU_ADMIN] skeldat on a public server (no launcher=1), no world
# and no admin: bob's join is refused, told of the setup code; boss joins
# with the code, is admin and gets the menu; bob joins again and waits
# for an admin; boss makes a world and bob goes in with it. [SKELDAT_LOGIN]
# carl, arriving to the running world with no login, gets the login page
# and is not placed; dave, logging in, goes in as dave
pub=$t/skeldat_public
BUILDAT_SKELDAT_WORLD= start_server "$t/pub.srv.log" "STATUS Listening" 300 \
	auto "$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$pub/srv" -C "$pub/srv.cache" -l 3 || fail "the server ($t/pub.srv.log)"
CHECK_PIDS+=($SERVER_PID)
pub_pid=$SERVER_PID
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/pub.srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/pub.srv.log)"
# pub_client <name> <log> <cmds> [code]
pub_client()
{
	BUILDAT_JOIN_NAME=$1 BUILDAT_JOIN_PASSWORD=secret123 \
		BUILDAT_JOIN_CREATE=${1:+1} BUILDAT_JOIN_CODE="${4:-}" \
		run_client 60 "$2" timeout 400 "$b" -C "$pub/c$1" -D "$pub/u$1" \
		-w 1100x700 -l 3 -o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$3"
}
printf '%s\n' "wait_log 30000 accounts: the login page shown" "delay 500" \
	"screenshot $t/pub.no_admin.png" "quit" > "$t/bob0.cmds"
pub_client bob "$t/pub.bob0.log" "$t/bob0.cmds" ||
	fail "bob: the first drive ($t/pub.bob0.log)"
grep -aq "Login refused: This server has no admin yet: .*setup code" \
	"$t/pub.bob0.log" || fail "bob: not told of the setup code ($t/pub.bob0.log)"
printf '%s\n' 'wait_log 30000 accounts: ntfy asked' \
	'wait_log_any 5000 server window: the page ntfy' 'delay 300' \
	"click Button \"Don't add\"" 'delay 500' \
	"wait_log_any 30000 world_menu: the list shown, 0 worlds" \
	"delay 20000" 'click Button "New world..."' \
	"wait_log 5000 world_menu: the name screen shown" "delay 300" \
	'click Button "Create"' "wait_log 300000 skeldat: placed at" "quit" \
	> "$t/boss.cmds"
# Boss opens the registration, for bob, and holds the menu 20 s while bob
# joins and waits
BUILDAT_JOIN_ADMIN="setting open_registration on" pub_client boss "$t/pub.boss.log" "$t/boss.cmds" "$code" &
boss=$!
wait_for_log "$t/pub.boss.log" "the list shown, 0 worlds" 120 ||
	fail "boss: no menu ($t/pub.boss.log)"
printf '%s\n' "wait_log 30000 world_menu: the wait shown: Waiting for an admin" \
	"delay 500" "screenshot $t/pub.bob_wait.png" \
	"wait_log 300000 skeldat: placed at" "quit" > "$t/bob.cmds"
pub_client bob "$t/pub.bob.log" "$t/bob.cmds" || fail "bob: the drive ($t/pub.bob.log)"
wait $boss || fail "boss: the drive ($t/pub.boss.log)"
printf '%s\n' "wait_log 60000 accounts: the login page shown" "delay 3000" \
	"quit" > "$t/carl.cmds"
run_client 60 "$t/pub.carl.log" timeout 400 "$b" -C "$pub/ccarl" \
	-D "$pub/ucarl" -w 1100x700 -l 3 -o sound_mute=1 \
	-s "127.0.0.1:$SERVER_PORT" -c @"$t/carl.cmds" ||
	fail "carl: no login page in a running world ($t/pub.carl.log)"
grep -aq "skeldat: placed at" "$t/pub.carl.log" &&
	fail "carl: placed with no login ($t/pub.carl.log)"
printf '%s\n' "wait_log 120000 skeldat: placed at" "quit" > "$t/dave.cmds"
pub_client dave "$t/pub.dave.log" "$t/dave.cmds" || fail "dave: the drive ($t/pub.dave.log)"
grep -aq "skeldat: dave joins at" "$t/pub.srv.log" &&
	grep -aq "skeldat: boss is an admin" "$t/pub.srv.log" ||
	fail "dave not in as dave, or boss not an admin ($t/pub.srv.log)"
kill $pub_pid; wait $pub_pid 2>/dev/null
echo "  skeldat public: bob told of the setup code, boss admin by it made the world, bob in; carl with no login at the login page, dave in by his"

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
echo "PASS: the world menu in skeldat, skelenti and vanilla: a world made, played, renamed and deleted; on a public server an admin by the setup code picks"
# vim: set noet ts=4 sw=4:
