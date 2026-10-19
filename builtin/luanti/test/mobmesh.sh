#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [OBJECT_MESH] step 0: mobmesh.lua's server beside a client that looks at
# the mobs and shoots them. Prints the mobs' properties from the
# server's log and the model lines from the client's; the shot is
# local/mobmesh/mobs.png.
#
#   builtin/luanti/test/mobmesh.sh
#   FIXTURE=connected builtin/luanti/test/mobmesh.sh   (another fixture with
#                                                       the same stage and shots)
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
FIXTURE="${FIXTURE:-mobmesh}"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/$FIXTURE"
mkdir -p "$out"
save="buildat_test_$FIXTURE"
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running"; exit 77
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/$FIXTURE.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 29778 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l "${LOG_LEVEL:-4}" ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
# The second stage is the fixture's next set_pos, 16 s after the first,
# which the client logs as the server putting the player; the 2 s and
# 1.5 s after a look_dir are the models and the world drawn there.
# simplified: the fixture's stage, six seconds after the join, is not
# told apart on the client from the spawn's own placing; ten seconds after
# the first placing is what waits for it and its platform to be drawn. A
# line the client logs for the stage would be the event, but a chat line
# shows in the pictures
cat > "$out/cmds.txt" <<CMDS
wait_log 120000 the server put the player at
delay 10000
look_dir 1 -0.15 0
# simplified: the models and the world in the new direction drawn; a
# settle line after a turn (0 undrawn in view) would be the event
delay 2000
screenshot $out/mobs.png
event scan
wait_log 30000 the server put the player at
look_dir 2.5 0.2 1
# simplified: as above, the side drawn after the turn
delay 1500
screenshot $out/zombie_side.png
event scan
quit
CMDS
bin/buildat -s localhost:29778 -w 1280x720 -l "${CLIENT_LOG_LEVEL:-3}" \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	{ echo "FAIL: the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"; exit 1; }
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
grep "$FIXTURE:" "$out/srv.log" | sed "s/.*$FIXTURE: //"
grep "model \"" "$out/srv.log" | sed 's/.*C1: //'
grep "luanti:model\|scan.*object\|scan.*obj " "$out/cli.log" | sed 's/.*luanti  : //'
# **The verdict is that the mobs were drawn**, not what they look like
# ([CI_RUNS]'s contract, 2026-09-25): the picture is the reading this
# exists to give, and a run where the fixture spawned nothing or the
# client drew no model is a failure nobody needs to open the picture
# for. The exit status was the last grep's until now.
models=$(grep -ac "luanti:model" "$out/cli.log")
models=${models:-0}
shot=$(ls "$out"/*.png 2>/dev/null | wc -l)
echo "the client took $models model lines and $shot pictures"
if [ "$models" -lt 1 ] || [ "$shot" -lt 1 ]; then
	echo "FAIL: no mob model reached the client, or nothing was drawn"
	exit 1
fi
echo "PASS: the mobs' models reached the client and the shot was taken"
exit 0
# vim: set noet ts=4 sw=4:
