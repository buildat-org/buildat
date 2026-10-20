#!/bin/bash
# tier: full
# cost: ~55s (2026-10-21)
# covers: client/api.lua src/client/app_lua.h src/client/web/index.html builtin/accounts/client_lua/accounts.lua apps/hillclimb/main/client_lua/init.lua
# [WEB_JOIN_054]: the web client's join to a public game reaches the login
# page, and past it the game's own player. hillclimb in Firefox
# (util/web_drive.sh, the web client from web/): the login page after the
# accounts hello, the first admin's account made by the setup code, and
# the car the server adds on the login. The name has a "t", the chat key,
# which a focused field must keep. Then the car driven 10 s (W held) and
# no voxelworld:node_volume_updated over 5 ms ([HC_WEB_CHOPPY]).
# simplified: the server runs main/init.lua and main/join.lua in either
# order, and only join-first (testhill's) made the game's accounts
# instance take the hello; the run has whichever order it gets. Shown both
# ways by hand, 2026-10-20, with init.lua's load moved to the fences packet.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/web_join.XXXXXX")
log=$out/drive.log
bash "$here/util/web_drive.sh" firefox hillclimb \
	"$here/util/web_join.json" "$out" > "$log" 2>&1 ||
	{ echo "FAIL: the drive ($log; $(grep -a "accounts" "$out/page.log" |
			tail -3 | tr '\n' ' '))"; exit 1; }
# [HC_WEB_CHOPPY] Driven 10 s on the soft sand, digging: no ground update
# took the main thread 5 ms ("slow packet"; 7-13 ms each when the
# chunk's heights were read in the update)
slow=$(grep -ac "slow packet: voxelworld:node_volume_updated" "$out/page.log")
[ "$slow" = 0 ] || { echo "FAIL: $slow ground updates over 5 ms ($out/page.log)"; exit 1; }
rm -rf "$out"
echo "PASS: a web join to hillclimb shows the login page, and the car after it; driven 10 s, no ground update over 5 ms"
