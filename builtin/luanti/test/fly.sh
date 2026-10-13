#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 36s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [FLY_MODES]: the three modes as official has them, driven. A devtest
# world (the singleplayer holds every privilege): K, then Space held for
# two seconds, and the player is up in the air; the fixture then revokes
# fly, the client's chat has "Fly mode enabled (note: no 'fly' privilege)"
# on the next K, and the player is down again within a few seconds (the
# client stops flying without the privilege; the server's hold-down is
# the backstop). Prints PASS or FAIL.
#
#   builtin/luanti/test/fly.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "/tmp/buildat_fly.XXXXXX")
cd "$here/Build"
rm -rf $BUILDAT_USER_PATH/apps/vanilla/saves/buildat_test_fly
srv=""; cli=""
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"; kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
# Under the repo, not $tmp: the boxed server reads nothing in /tmp
out="$here/local/fly"
mkdir -p "$out"
cat > "$out/fixture.lua" <<'LUA'
-- fly.sh's server half: twenty seconds after the join, the player's fly
-- privilege goes, and the position is logged every second for the runner.
-- Once the player is 3 nodes under the highest point since, the chat says
-- so: what the client waits for before it leaves
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.settings:set("singleplayer", "false")
	local privs = core.get_player_privs(name)
	privs.fly = true; privs.fast = true; privs.noclip = true; privs.interact = true
	core.set_player_privs(name, privs)
	local top, said = nil, false
	local function tick()
		if player:is_player() then
			local p = player:get_pos()
			core.log("action", string.format("fly: y=%.1f", p.y))
			if top then
				top = math.max(top, p.y)
				if not said and p.y < top - 3 then
					said = true
					core.chat_send_player(name, "fly: down again")
				end
			end
			core.after(1, tick)
		end
	end
	core.after(1, tick)
	core.after(20, function()
		core.log("action", "fly: revoking fly")
		top = player:get_pos().y
		local p = core.get_player_privs(name)
		p.fly = nil
		core.set_player_privs(name, p)
	end)
end)
LUA
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=buildat_test_fly \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$tmp/srv.log" "Mods loaded" 60 auto \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla ||
	{ echo "FAIL: the server did not start"; exit 1; }
port=$SERVER_PORT
srv=$SERVER_PID
# Join, fly up once the world is playable, keep flying; once the client
# has the privileges without fly (revoked 20 s after the server's join,
# which the client's clock does not know) press K twice: off, then on
# again without it; then until the fixture says the player came down.
# Space is held two seconds: the climb is the hold's length.
{ echo "wait_log 60000 the server put the player"
	echo "wait_log 60000 scene, 0 undrawn within 2"
	echo "keypress K"; echo "wait_log 5000 Fly mode enabled"
	# Noclip too: the world is new each run, and a spawn under leaves
	# stopped the climb (2026-10-13: up 0.3, then down 1.3 after the revoke)
	echo "keypress H"; echo "wait_log 5000 Noclip mode enabled"
	echo "keydown Space"; echo "delay 2000"; echo "keyup Space"
	echo "wait_log_any 30000 privileges: fast, interact, noclip, shout"
	echo "keypress K"; echo "wait_log 5000 Fly mode disabled"
	echo "keypress K"; echo "wait_log 5000 Fly mode enabled (note: no 'fly' privilege)"
	echo "wait_log 20000 fly: down again"; echo "quit"; } > "$tmp/cmds.txt"
bin/buildat -s "localhost:$port" -w 640x360 -l 3 -c @"$tmp/cmds.txt" \
	> "$tmp/cli.log" 2>&1 &
cli=$!
wait "$cli" ||
	fail "the drive ($tmp/cli.log): $(grep -ao 'Command sequence failed.*' "$tmp/cli.log" | head -1)"
ys=$(grep -a "fly: y=" "$tmp/srv.log" | sed 's/.*y=//' | tr '\n' ' ')
first=$(grep -a "fly: y=" "$tmp/srv.log" | sed -n '1s/.*y=//p')
flying=$(grep -a "fly: y=" "$tmp/srv.log" | sed -n '12s/.*y=//p')
last=$(grep -a "fly: y=" "$tmp/srv.log" | tail -1 | sed 's/.*y=//')
note=$(grep -a "Fly mode enabled (note: no 'fly' privilege)" "$tmp/cli.log" |
	grep -vc wait_log)
held=$(grep -ac "is held down" "$tmp/srv.log")
echo "y: $ys"
echo "first $first, flying $flying, last $last; the note $note times, held down $held times"
echo "logs in $tmp"
up=$(python3 -c "print(1 if float('$flying' or 0) > float('$first' or 0) + 3 else 0)")
back=$(python3 -c "print(1 if float('$last' or 99) < float('$flying' or 0) - 2 else 0)")
# The client drops the player itself once it knows the privilege is gone
# (official's rule); the server's hold-down is the backstop for a client
# that does not, so its count is printed and not required
if [ "$up" = 1 ] && [ "$note" -ge 1 ] && [ "$back" = 1 ]; then
	echo PASS
else
	echo FAIL
	exit 1
fi
