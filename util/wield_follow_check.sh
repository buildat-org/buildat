#!/bin/bash
# tier: full
# cost: ~70s (2026-10-04)
# covers: builtin/luanti/client_lua/module.lua builtin/luanti/lua/entity.lua apps/vanilla/main/client_lua/scan.lua
# [WIELD_AT_FEET]: what rides the player's own object -- VoxeLibre's held
# item -- is drawn from where the client has the player now, so in third
# person it stays at the hand as the player turns and walks, where the
# server's place for it trailed. VoxeLibre in third person with a stone in
# hand: turned to four yaws, scanned right after each turn and after it
# settles, then walking; every scan has the item at the same place in the
# model's own frame.
# Needs mineclone2 in the desk's games.
#   util/wield_follow_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || { echo "SKIP: no mineclone2"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
t=$(mktemp -d)
s=
trap '[ -n "$s" ] && kill $s 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
mkdir -p "$t/srv/shared/vanilla/games"
cp -r "$G" "$t/srv/shared/vanilla/games/"
M=$t/srv/shared/vanilla/games/mineclone2/mods/zz_give
mkdir -p "$M"
echo "name = zz_give" > "$M/mod.conf"
cat > "$M/init.lua" <<'L'
core.register_on_joinplayer(function(player)
	core.after(2, function()
		player:get_inventory():set_stack("main", 1, "mcl_core:stone 10")
		player:set_wield_index(1)
		core.chat_send_player(player:get_player_name(), "zz_give: the stone in hand")
	end)
end)
L
echo "fixed_map_seed = 1727923235850308" >> "$t/srv/shared/vanilla/games/mineclone2/minetest.conf"
cd "$here/Build"
P=29585
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=wield BUILDAT_LUANTI_FORCE_TIME=9000 \
start_server "$t/srv.log" "STATUS Listening" 120 $P \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -D "$t/srv" -l 3 ||
	fail "server did not listen"
s=$SERVER_PID
# The scans right after a turn and 1.5 s on, and while walking, are the
# timing looked at; the second after c is the model drawn in third person
{
	echo "wait_log 120000 the server put the player"
	echo "wait_log 120000 scene, 0 undrawn within 2"
	echo "wait_log_any 30000 chat: zz_give: the stone in hand"
	echo "delay 1000"; echo "keypress c"; echo "delay 1000"
	# A timing test: a scan 30 ms after the turn and one 1.5 s on
	for y in 0 90 180 270; do
		echo "look $y -10"; echo "delay 30"; echo "event scan 4 y${y}a"
		echo "delay 1500"; echo "event scan 4 y${y}b"
	done
	# A timing test: walking, scanned 400 and 700 ms in
	echo "keydown w"; echo "delay 400"; echo "event scan 4 walk1"
	echo "delay 300"; echo "event scan 4 walk2"; echo "keyup w"
	echo "quit"
} > "$t/seq"
timeout 400 bin/buildat -o launch_ui=launch_menu -s 127.0.0.1:$P -D "$t/cl" -w 800x600 -u 1 -l 3 \
	-o sound_mute=1 -c @"$t/seq" > "$t/cl.log" 2>&1 ||
	fail "the drive ($t/cl.log): $(grep -a "Command sequence failed" "$t/cl.log" | tail -1)"
grep -a "scan [a-z0-9]*: rider" "$t/cl.log" | sed 's/.*: rider [^ ]* //' > "$t/riders"
n=$(wc -l < "$t/riders")
[ "$n" -ge 5 ] || fail "$n rider lines, wanted 5 or more (third person, the item made)"
[ "$(sort -u "$t/riders" | wc -l)" = 1 ] ||
	fail "the item moved on the model: $(sort "$t/riders" | uniq -c | tr '\n' ';')"
echo "PASS: the held item at $(head -1 "$t/riders") in $n scans, turning and walking"
