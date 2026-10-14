#!/bin/bash
# tier: full
# cost: 90s (a first run compiles demo_digger and hearth, 2026-10-05)
# covers: builtin/client_file/client_file.cpp src/client/app.cpp client/extensions/network/init.lua extensions/launch_world/world.lua builtin/starport_announce/starport_announce.cpp apps/starport/main/main.cpp client/extensions/starport/init.lua
# [LAUNCH_WORLD] (4): **a native server's icon, kept from one connect**.
# A demo_digger server with an admin's server_icon.png of 120 pixels, which it
# scales to 64; a client connects once and quits; the client is started
# again into the room, connecting to nothing, and the server's sphere on
# the floor wears the stored icon.
# [SERVER_ICONS]: **a Starport listing's icon on the floor**. A Starport
# and a Hearth listed on it with a 64-pixel icon; an announce with a
# larger one is refused; the room's first start fetches the list and the
# icon, and the second wears it on the listing's sphere. Luanti's
# servers wear the icon of the game the list names, where it is installed.
#
#   extensions/launch_world/server_icon.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
srv= sp= an=
trap 'kill $srv $sp $an 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
P=29881
mkdir -p "$t/srv/apps/demo_digger" "$t/cl"
cp "$here/apps/vanilla/launcher/grass_block.png" "$t/srv/apps/demo_digger/server_icon.png"
cd "$here/Build"
start_server "$t/srv.log" "Listening at" 180 $P \
	bin/buildat_server -m ../apps/demo_digger -D "$t/srv" -l 3 || fail "demo_digger did not start"
srv=$SERVER_PID
grep -aq "The server's icon: .*server_icon.png" "$t/srv.log" ||
	fail "the server did not take its icon ($(tail -2 "$t/srv.log"))"
grep -aq "server_icon.png scaled down to 64" "$t/srv.log" ||
	fail "the 120-pixel icon was not scaled down"
# A client's drive: it quits once its line is logged
cmds(){ printf 'wait_log_any %s %s\nquit\n' "$1" "$2" > "$t/cmds"; }
cmds 20000 "server icon from localhost:$P kept"
timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -C "$t/cache" -s localhost:$P -w 640x360 -l 3 \
	-o sound_mute=1 -c @"$t/cmds" > "$t/cl1.log" 2>&1
grep -aq "server icon from localhost:$P kept" "$t/cl1.log" ||
	fail "the client did not keep the icon"
kept=$(ls "$t/cache/server_icons/"*.png)
sha=$(basename "$kept" .png)
file "$kept" | grep -q "64 x 64" || fail "the kept icon is not 64x64: $(file "$kept")"
grep -q "\"tcp://localhost:$P\".*\"$sha\"" "$t/cl/network_addresses.csv" ||
	fail "the address's row has no icon: $(cat "$t/cl/network_addresses.csv")"
kill $srv; srv=
# The room, connecting to nothing
cmds 20000 "wears its stored icon"
timeout 90 bin/buildat -D "$t/cl" -C "$t/cache" -m launch_world -w 640x360 \
	-l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/cl2.log" 2>&1
grep -aq "marks: server tcp://localhost:$P wears its stored icon" "$t/cl2.log" ||
	fail "the room's sphere does not wear it"

# A Starport, and a Hearth listed on it with its icon
SP=29884 AN=29885
export BUILDAT_CONNECT_PORTS="$SP,$AN"
start_server "$t/sp.log" "setup code" 180 $SP \
	bin/buildat_server -m ../apps/starport -D "$t/sp" -l 3 || fail "the Starport did not start"
sp=$SERVER_PID
mkdir -p "$t/an/apps/hearth"
cp "$here/client/data/favicon.png" "$t/an/apps/hearth/server_icon.png"
isha=$(sha256sum "$t/an/apps/hearth/server_icon.png" | cut -d' ' -f1)
printf '{"starports": ["http://127.0.0.1:%s"], "name": "Icon check",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}\n' $SP > "$t/an/apps/hearth/starport.json"
bin/buildat_server -m ../apps/hearth -D "$t/an" -P $AN -l 3 > "$t/an.log" 2>&1 &
an=$!
for _ in $(seq 600); do
	[ -f "$t/an/apps/hearth/starport_claim.txt" ] && break
	kill -0 $an 2>/dev/null || fail "Hearth exited ($(tail -3 "$t/an.log"))"
	sleep 0.2
done
read -r _ _ id _ _ ccode < <(grep -v "^#" "$t/an/apps/hearth/starport_claim.txt")
code=$(grep -ao "setup code [A-Z0-9]*" "$t/sp.log" | cut -d' ' -f3)
cmds 20000 '"id":1003,'
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_CREATE=1 BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_sp" -w 640x360 -l 3 -o sound_mute=1 \
	-s 127.0.0.1:$SP -c @"$t/cmds" > "$t/cl_sp.log" 2>&1
list(){ curl -s -m 5 "127.0.0.1:$SP/api/v1/list"; }
# Once a second: the Starport answers an address 60 lists a minute
for _ in $(seq 60); do
	list | grep -q "\"icon\":\"$isha\"" && break
	sleep 1
done
list | grep -q "\"icon\":\"$isha\"" ||
	fail "the listing has no icon ($(list | head -c 300); $(grep -a "Starport\|icon" "$t/an.log" | tail -2))"
curl -s -m 5 "127.0.0.1:$SP/api/v1/icon/$isha" | sha256sum | grep -q "^$isha" ||
	fail "/api/v1/icon does not serve it"
big=$(od -An -v -tx1 "$here/apps/vanilla/launcher/grass_block.png" | tr -d ' \n')
curl -s -m 5 -X POST "127.0.0.1:$SP/api/v1/announce" -d "{\"port\": 1, \"unlisted\": true,
	\"kind\": \"app\", \"audience\": \"everyone\", \"access\": \"open\",
	\"icon\": \"$big\"}" | grep -q '"error":"icon: ' ||
	fail "an announce with a 120-pixel icon was taken"
# The room: the client's Starport is this one, its origin accepted; the
# first start fetches, the second wears
mkdir -p "$t/cl2"
echo "{\"starports\": [\"http://127.0.0.1:$SP\"]}" > "$t/cl2/starport.json"
printf '%s\n%s\n' 'accepted,address,description,created,last_attempt,name,icon,server' \
	"\"true\",\"http://127.0.0.1:$SP\",\"check\",\"0\",\"$(date +%s)\",\"\",\"\",\"\"" > "$t/cl2/network_addresses.csv"
for n in 3 4; do
	if [ $n = 3 ]; then cmds 20000 "icon $isha kept"
	else cmds 20000 "wears its listing's icon"; fi
	timeout 90 bin/buildat -D "$t/cl2" -C "$t/cache2" -m launch_world -w 640x360 \
		-l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/cl$n.log" 2>&1
done
[ -f "$t/cache2/server_icons/$isha.png" ] ||
	fail "the listing's icon was not fetched ($(grep -a "Starport\|icon" "$t/cl3.log" | tail -3))"
grep -aq "servers: 1 listed on Starport" "$t/cl4.log" ||
	fail "the listing is not on the floor ($(grep -a "servers:" "$t/cl4.log"))"
grep -aq "marks: server 127.0.0.1:$AN wears its listing's icon" "$t/cl4.log" ||
	fail "the listing's sphere does not wear its icon"

# Luanti's list: a server wears the icon of the game the list names, when
# that game is installed here; two on one game both wear it
mkdir -p "$t/cl5/shared/vanilla/games/testgame/menu" "$t/cl5/extensions/serverlist"
cp "$here/client/data/favicon.png" "$t/cl5/shared/vanilla/games/testgame/menu/icon.png"
marks(){ # game -> the room's count of its own icons
	printf '192.0.2.1:30000|One|3|%s\n192.0.2.2:30000|Two|2|%s\n' "$1" "$1" \
		> "$t/cl5/extensions/serverlist/serverlist.csv"
	cmds 20000 "of the room's own icons"
	timeout 90 bin/buildat -D "$t/cl5" -C "$t/cache5" -m launch_world -w 640x360 \
		-l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/cl5_$1.log" 2>&1
	grep -ao "marks: [0-9]* of the room's own" "$t/cl5_$1.log" | cut -d' ' -f2
}
m0=$(marks "") m1=$(marks testgame)
[ -n "$m0" ] && [ "$m1" = $((m0 + 2)) ] ||
	fail "the list's servers do not wear their game's icon (marks $m0, then $m1)"
echo "PASS: the server's icon came at one connect, scaled to 64, and the room wears it after a restart; a listing's icon reached the floor; a larger one was refused; Luanti servers wear their game's icon"
