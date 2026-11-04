#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min, ~3 min with a cold module cache (2026-10-31)
# covers: builtin/kit/** apps/workbench/** client/core/aitta/** src/impl/aitta.cpp
# [KIT] stage 5, publishing, on a local Aitta and two Workbench servers:
#   1. alice's key is bound on the Aitta; her Kit package alice/lamps
#      1.0.0 (a component type, alice/lamp, written by hand) packed and
#      published by the command line.
#   2. On server A alice (its admin) opens the palette's New tab, accepts
#      the network dialog's question about the Aitta by a click; the tab
#      lists it, and installs it; places an alice/lamp, sets its
#      brightness and saves it as her prefab lamp_post; stars it a
#      favourite (the Favourites tab has it); the credits name the
#      package; "Publish my prefabs..." writes her prefabs into
#      dev_apps/my_prefabs (its dependency on alice/lamps) and opens the
#      publish screen on it, which the check then packs and publishes by
#      the command line.
#   3. On server B carol (its admin) installs alice/my_prefabs from the
#      New tab: alice/lamps comes with it first; places the prefab
#      alice/lamp_post; the credits, from the pause menu (Credits...,
#      its Escape and Close back to the menu), name both packages.
#   4. alice/lamps 2.0.0 (its lamp version 2: level for brightness, by
#      its migrate) published; carol upgrades it from the New tab: the
#      placed lamp is migrated (brightness 7, level 70), and after a
#      restart B has both packages and the lamp at version 2.
#   5. [AITTA_KEY_IDENTITY] A second Aitta binds "alice" to another key,
#      and its alice/lamps 1.0.0 is published there. On server C dave,
#      with both Aittas, sees two alice/lamps, each with its Aitta's
#      host, installs both (two packages, <fp>/lamps and <fp2>/lamps,
#      each vouched for by its own Aitta), places a lamp of each, and the
#      credits name both, "by alice @<host>" each.
# A package is its key's: its types are "<fp>/<n>", people read
# "alice/<n>" once its Aitta vouched (the servers ask it: the Aittas'
# ports allowed by BUILDAT_CONNECT_PORTS).
# KEEP_TMP=1 keeps the screenshots: the New tab, the favourites, the
# credits, the export's question and the publish screen (A); the New tab
# and the credits (B); the two alice/lamps and their credits (C).
#
#   util/kit_publish_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
# Workbench opens its project "world" at once, no Manage
# ([WORKBENCH_PROJECTS]: workbench_check.sh goes through Manage)
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_publish; t=$CHECK_TMP
b="$here/Build/bin/buildat"
cd "$here/Build"

start_server "$t/aitta.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/aitta" -l 3 ||
	fail "Aitta did not start ($t/aitta.log)"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
acode=$(grep -ao "setup code [A-Z0-9]*" "$t/aitta.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
fp=$(aitta_fp "$t/pub")
printf 'wait_log_any 20000 ai: {"id":1,\nquit\n' > "$t/bind.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$acode \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"alice\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/bind.cmds" > "$t/bind.log" 2>&1 ||
	fail "the bind's client ($t/bind.log)"
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind ($t/bind.log)"

# A Kit package, its manifest and its files: <dir> <name> <version> [deps]
manifest(){
	printf '{"kind": "kit", "author": "alice", "name": "%s", "version": "%s",
		"engine_api": 2, "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "%s", "dependencies": [%s]}\n' "$2" "$3" "$2 for Kit" \
		"${4:-}" > "$1/meta.json"
}
publish(){ # <dir> [key] [port]
	local zip
	zip=$("$b" aitta pack "$1" "${2:-$t/key}" "$t/out" 2>"$t/pack.err") ||
		fail "pack $1: $(cat "$t/pack.err")"
	"$b" aitta publish "$zip" 127.0.0.1:${3:-$P} 2>&1 | grep -q "listed: alice/" ||
		fail "publish $1"
	sleep 1 # the list's newest is by time, in seconds
}
lamp(){ # <version>: alice/lamp; version 2 has level for brightness
	mkdir -p "$t/lamps/types"
	if [ "$1" = 1 ]; then
		cat > "$t/lamps/types/lamp.lua" <<'EOF'
-- alice/lamp: a lamp's look, as bright as it is set
return {
	version = 1,
	params = {brightness = {type = "number", default = 5}},
	look = {shape = "sphere", size = 0.3, color = "#ffe080"},
}
EOF
	else
		cat > "$t/lamps/types/lamp.lua" <<'EOF'
-- alice/lamp version 2: its level, ten a brightness
return {
	version = 2,
	params = {level = {type = "number", default = 50}},
	look = {shape = "sphere", size = 0.4, color = "#ffe080"},
	migrate = function(p, from)
		if from < 2 then
			p.level = (p.brightness or 5) * 10
			p.brightness = nil
		end
		return p
	end,
}
EOF
	fi
}
lamp 1
manifest "$t/lamps" lamps 1.0.0
publish "$t/lamps"
echo "ok: alice/lamps 1.0.0 published"

# A user path with only this Aitta (or the Aittas on the ports given),
# their addresses already allowed; "ask" leaves this one to the network
# dialog
user(){ # <name> [ask | port...]
	local n=$1 now list= rows= port ask=
	shift
	[ "${1:-}" = ask ] && { ask=1; shift; }
	now=$(date +%s)
	for port in "${@:-$P}"; do
		list+="${list:+, }\"http://127.0.0.1:$port\""
		rows+="\"true\",\"http://127.0.0.1:$port\",\"\",\"$now\",\"$now\",\"\",\"\",\"\""$'\n'
	done
	mkdir -p "$t/cu_$n"
	echo "{\"starports\": [], \"aittas\": [$list]}" > "$t/cu_$n/starport.json"
	[ -n "$ask" ] && return
	printf 'accepted,address,description,created,last_attempt,name,icon,server\n%s' \
		"$rows" > "$t/cu_$n/network_addresses.csv"
}
server(){ # <log name> <user dir>
	start_server "$t/$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$2" -l 3 ||
		fail "the server did not come up ($t/$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client(){ # <name> <drive>: its commands in $t/<drive>.cmds
	sed -i "s|@T@|$t|g" "$t/$2.cmds"
	run_client 60 "$t/$2.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$2.cmds" ||
		fail "client $2 failed ($t/$2.log, $t/srv*.log)"
}
stop(){
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
want(){ # <log> <text>...
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
code(){ # <server log>
	wait_for_log "$1" "setup code [A-Z0-9]+" 30
	grep -aoP 'setup code \K[A-Z0-9]+' "$1" | head -1
}
# The ntfy question (a first join), and the tools on by the pause menu's Edit
NTFY='wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don'"'"'t add"'
EDIT='wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress Escape
wait_log 10000 pause: the menu shown
click Button "Edit"
wait_log 10000 kit editor: state:'
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
# The servers ask the Aittas whose a package's key is
export BUILDAT_CONNECT_PORTS=$P

# 2. Server A, alice, whose New tab asks about the Aitta: the dialog's
# Accept clicked, not the editor's walk view under it going up into the
# crosshair ([WB_NET_DIALOG_CLICK])
user alice ask
server srva "$t/a"
c=$(code "$t/srva.log")
cat > "$t/alice.cmds" <<EOF
wait_log_any 60000 Joined as alice
$NTFY
$EDIT
click Button "New"
wait_log 20000 Asking the user about
frames 3
click Button "Accept"
wait_log 10000 The user accepted http://127.0.0.1:$P
wait_log_any 20000 kit editor: package alice/lamps 1.0.0
frames 3
screenshot @T@/a_new.png
click Button "Install"
wait_log 20000 kit editor: Package: installed alice/lamps 1.0.0
wait_log_any 20000 kit editor: installed alice/lamps as $fp/lamps
event kit_edit {"op": "place", "type": "$fp/lamp", "pos": [2, 1, 2]}
wait_log 10000 entities, 1 to undo
event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "brightness", "value": 7}
wait_log 10000 entities, 2 to undo
event kit_edit {"op": "save_prefab", "ids": [3], "name": "lamp_post"}
wait_log 10000 entities, 3 to undo
click Button "All"
wait_log 5000 kit editor: the palette's All tab
click Button "alice/lamp"
wait_log 5000 kit editor: placing alice/lamp
click Button "Favourite alice/lamp"
wait_log 5000 kit editor: alice/lamp a favourite
click Button "Favourites"
wait_log 5000 kit editor: the palette's Favourites tab
frames 3
screenshot @T@/a_favourites.png
mouse_click right
click Button "Credits"
wait_log 5000 kit editor: credit alice/lamps 1.0.0 by alice
frames 3
screenshot @T@/a_credits.png
frames 3
click Button "Close"
wait_log 5000 kit editor: the credits closed
click Button "New"
wait_log 20000 kit editor: package alice/lamps 1.0.0
click Button "Publish my prefabs..."
wait_log 10000 aitta publish: Kit's export asked, 1 files
frames 3
screenshot @T@/a_export.png
click Button "Yes"
wait_log 10000 aitta publish: the package page, my_prefabs
delay 300
screenshot @T@/a_publish.png
EOF
BUILDAT_JOIN_NAME=alice BUILDAT_JOIN_CODE=$c client alice alice
! grep -aq "kit editor: into the crosshair" "$t/alice.log" ||
	fail "a click on the network dialog went into the editor's crosshair ($t/alice.log)"
want "$t/srva.log" "alice installed alice/lamps 1.0.0: 1 types, 0 prefabs" \
	"alice exports 1 files, 1 dependencies"
d="$t/cu_alice/dev_apps/my_prefabs"
[ -f "$d/types/lamp_post.prefab.json" ] || fail "no lamp_post in $d"
grep -q '"kit" : "alice/lamps"' "$d/meta.json" ||
	fail "no dependency on alice/lamps ($d/meta.json)"
grep -q '"brightness" *: *7' "$d/types/lamp_post.prefab.json" ||
	fail "the prefab's brightness ($d/types/lamp_post.prefab.json)"
grep -aq "alice/lamp a favourite" "$t/alice.log" &&
	grep -q "$fp/lamp" "$t/cu_alice/kit_favourites.json" ||
	fail "no favourite (a_favourites.png)"
stop
echo "ok: installed from the New tab, placed, a prefab, a favourite, credits, exported"
# The publish screen's form, as the command line has it: the licences
python3 -I -c '
import json, sys
p = sys.argv[1]
m = json.load(open(p))
m.update(license_code="MIT", license_media="CC0-1.0")
json.dump(m, open(p, "w"))' "$d/meta.json"
publish "$d"
echo "ok: alice/my_prefabs 0.1.0 published"

# 3. Server B, carol: the prefab's package, its dependency first
user carol
server srvb "$t/b"
c=$(code "$t/srvb.log")
cat > "$t/carol.cmds" <<EOF
wait_log_any 60000 Joined as carol
$NTFY
$EDIT
click Button "New"
wait_log 20000 kit editor: package alice/my_prefabs 0.1.0
frames 3
screenshot @T@/b_new.png
click Button "Install"
wait_log 20000 kit editor: Package: installed alice/my_prefabs 0.1.0
wait_log_any 20000 kit editor: installed alice/my_prefabs as $fp/my_prefabs
event kit_edit {"op": "place", "prefab": "$fp/lamp_post", "pos": [1, 1, 3]}
wait_log 10000 entities, 1 to undo
keypress Escape
wait_log 10000 pause: the menu shown
click Button "Credits..."
wait_log 5000 kit editor: credit alice/my_prefabs 0.1.0 by alice
frames 3
screenshot @T@/b_credits.png
keypress Escape
wait_log 5000 kit editor: the credits closed
frames 3
click Button "Credits..."
wait_log 5000 kit editor: credit alice/lamps 1.0.0 by alice
click Button "Close"
wait_log 5000 kit editor: the credits closed
frames 3
click Button "Continue"
wait_log 5000 pause: the menu closed
EOF
BUILDAT_JOIN_NAME=carol BUILDAT_JOIN_CODE=$c client carol carol
want "$t/srvb.log" "carol installed alice/lamps 1.0.0" \
	"carol installed alice/my_prefabs 0.1.0: 0 types, 1 prefabs"
want "$t/carol.log" "kit editor: credit alice/lamps 1.0.0 by alice"
[ "$(grep -an "carol installed alice/lamps" "$t/srvb.log" | cut -d: -f1)" -lt \
	"$(grep -an "carol installed alice/my_prefabs" "$t/srvb.log" | cut -d: -f1)" ] ||
	fail "the dependency not first ($t/srvb.log)"
echo "ok: the prefab's package installed on another server, its dependency first, placed, credited"

# 4. alice/lamps 2.0.0, its migrate; carol upgrades
lamp 2
manifest "$t/lamps" lamps 2.0.0
publish "$t/lamps"
# ([WB_EDITOR_VIEW_MEMORY]) carol left B in edit mode: back in it at once
cat > "$t/upgrade.cmds" <<EOF
wait_log_any 60000 Joined as carol
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: remembered: edit mode
wait_log_any 10000 kit editor: edit mode on
wait_log_any 10000 kit editor: state:
click Button "New"
wait_log 20000 kit editor: package alice/lamps 2.0.0
click Button "Upgrade"
wait_log 20000 kit editor: Package: upgraded alice/lamps from 1.0.0 to 2.0.0
EOF
BUILDAT_JOIN_CREATE= BUILDAT_JOIN_NAME=carol client carol upgrade
want "$t/srvb.log" "Entity 3: $fp/lamp's migrate from version 1: {\"level\":70,\"own_look\":true}" \
	"Entity 3's $fp/lamp upgraded from version 1 to 2" \
	"carol upgraded alice/lamps from 1.0.0 to 2.0.0: 1 types, 0 prefabs, 0 voxel types, 1 entities upgraded"
stop
server srvb2 "$t/b"
# Kit hosts after "Listening at"
wait_for_log "$t/srvb2.log" "Component type $fp/lamp version" 60
want "$t/srvb2.log" "Kit packages: 2" "Component type $fp/lamp version 2"
grep -aq "Entity 3's $fp/lamp upgraded" "$t/srvb2.log" &&
	fail "upgraded again at the restart ($t/srvb2.log)"
stop
echo "ok: upgraded with its migrate, kept over a restart"

# 5. [AITTA_KEY_IDENTITY] A second Aitta's "alice", another key: two
# alice/lamps, both installed on one server, each credited with its host
start_server "$t/aitta2.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/aitta2" -l 3 ||
	fail "Aitta 2 did not start ($t/aitta2.log)"
CHECK_PIDS+=($SERVER_PID)
P2=$SERVER_PORT
acode=$(grep -ao "setup code [A-Z0-9]*" "$t/aitta2.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key2" > "$t/pub2" 2>/dev/null || fail "keygen 2"
fp2=$(aitta_fp "$t/pub2")
[ "$fp2" != "$fp" ] || fail "two keys, one fingerprint"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$acode \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"alice\",\"key\":\"$(cat "$t/pub2")\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl2" -w 800x600 -l 3 \
	-s 127.0.0.1:$P2 -c @"$t/bind.cmds" > "$t/bind2.log" 2>&1 ||
	fail "the second bind's client ($t/bind2.log)"
grep -aq 'ai: {"id":1,"ok":true' "$t/bind2.log" || fail "the second bind ($t/bind2.log)"
mkdir -p "$t/lamps2/types"
cat > "$t/lamps2/types/lamp.lua" <<'EOF'
-- The other alice's lamp
return {
	version = 1,
	params = {glow = {type = "number", default = 3}},
	look = {shape = "box", size = 0.3, color = "#80c0ff"},
}
EOF
manifest "$t/lamps2" lamps 1.0.0
publish "$t/lamps2" "$t/key2" $P2
echo "ok: the second Aitta's alice/lamps 1.0.0 published, another key"
export BUILDAT_CONNECT_PORTS=$P,$P2
user dave $P $P2
server srvc "$t/c"
c=$(code "$t/srvc.log")
cat > "$t/dave.cmds" <<EOF
wait_log_any 60000 Joined as dave
$NTFY
$EDIT
click Button "New"
wait_log_any 20000 kit editor: package alice/lamps @127.0.0.1:$P 2.0.0
wait_log_any 20000 kit editor: package alice/lamps @127.0.0.1:$P2 1.0.0
frames 3
screenshot @T@/c_new.png
click Button "Install"
wait_log 20000 kit editor: Package: installed alice/lamps
frames 5
click Button "Install"
wait_log_any 20000 kit editor: installed alice/lamps @127.0.0.1:$P as $fp/lamps
wait_log_any 20000 kit editor: installed alice/lamps @127.0.0.1:$P2 as $fp2/lamps
event kit_edit {"op": "place", "type": "$fp/lamp", "pos": [2, 1, 2]}
wait_log 10000 entities, 1 to undo
event kit_edit {"op": "place", "type": "$fp2/lamp", "pos": [4, 1, 2]}
wait_log 10000 entities, 2 to undo
click Button "All"
wait_log 5000 kit editor: the palette's All tab
click Button "alice/lamp @127.0.0.1:$P2"
wait_log 5000 kit editor: placing alice/lamp @127.0.0.1:$P2
mouse_click right
click Button "Credits"
wait_log 5000 kit editor: credit alice/lamps 2.0.0 by alice @127.0.0.1:$P (
wait_log_any 5000 kit editor: credit alice/lamps 1.0.0 by alice @127.0.0.1:$P2 (
frames 3
screenshot @T@/c_credits.png
EOF
BUILDAT_JOIN_NAME=dave BUILDAT_JOIN_CODE=$c client dave dave
want "$t/srvc.log" "dave installed alice/lamps 2.0.0: 1 types" \
	"dave installed alice/lamps 1.0.0: 1 types" \
	"Package $fp/lamps: alice's on 127.0.0.1:$P" \
	"Package $fp2/lamps: alice's on 127.0.0.1:$P2"
grep -aq "signed with another key" "$t/srvc.log" &&
	fail "an author's name pinned to a key ($t/srvc.log)"
stop
echo "PASS: Kit packages published, installed with a dependency, credited, upgraded with their migrate; two Aittas' alice/lamps both installed on one server, each credited with its Aitta's host"
