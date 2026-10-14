#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-10-14)
# covers: apps/vanilla/main/client_lua/keys.lua
# [KEYS_E_F]: vanilla's default keys in a world (VoxeLibre, survival:
# creative's search field takes the focus, and an E typed there is
# text):
# I opens nothing; E opens the inventory; E again closes it, which a
# third E shows by opening it again (an E that did not close would close
# it there). The form's field not typed into by the E that opened it is
# builtin/luanti/test/form_key.sh's.
# simplified: F (special, aux1) is the same table edit and not driven: a
# speed is no log line; nor is luanti_client's, which needs a Luanti
# server
#   util/keys_e_f_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || skip "no mineclone2"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp keys_e_f; t=$CHECK_TMP
mkdir -p "$t/srv/apps/vanilla/saves/k/luanti" "$t/srv/shared/vanilla/games"
cp -r "$G" "$t/srv/shared/vanilla/games/"
printf "creative_mode = false\nenable_damage = false\n" > "$t/srv/apps/vanilla/saves/k/luanti/world.mt"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=k start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
cat > "$t/cmds" <<'CMDS'
wait_log 120000 load: the world is in
wait_log_any 120000 form: the game set the inventory
delay 1000
keypress i
delay 1500
event scan 1 after_i
keypress e
wait_log 5000 form: the inventory opened
delay 800
keypress e
delay 800
keypress e
delay 1500
quit
CMDS
run_client 60 "$t/cli.log" timeout 300 "$here/Build/bin/buildat" -C "$t/c" \
	-D "$t/u" -w 1000x700 -l 3 -o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" \
	-c @"$t/cmds" ||
	fail "the drive ($t/cli.log: $(grep -a "Command sequence failed\|run_client:" "$t/cli.log" | tail -1))"
# The module's own line, not the sequencer's echo of the wait; the scan
# after I is before any
opened="luanti *: form: the inventory opened"
before=$(sed '/scan after_i/q' "$t/cli.log" | grep -ac "$opened")
[ "$before" = 0 ] || fail "I opened the inventory ($t/cli.log)"
n=$(grep -ac "$opened" "$t/cli.log")
[ "$n" = 2 ] || fail "E opened the inventory $n times of the 2 that E, E, E makes ($t/cli.log)"
echo "PASS: I opens nothing, E opens the inventory and closes it"
# vim: set noet ts=4 sw=4:
