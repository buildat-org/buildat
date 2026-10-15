#!/bin/bash
# tier: full
# cost: ~4 min (2026-10-07)
# covers: client/api.lua discuss_this_server client/core/urho3d/init.lua apps/hearth/main/main.cpp apps/hearth/main/client_lua/init.lua extensions/luanti_client/settings.lua
# [DISCUSS_SERVER]: "Discuss (leave server)" in luanti_client's pause
# menu. A Starport recommending a Hearth, the Hearth listed there with an
# admin, an ID logged in on the client, and a local devtest Luanti server
# joined through luanti_client's dialog, listed by being in the launcher's
# copy of Luanti's list ([LUANTI_LISTED_JOIN]). The button
# leaves, joins the Hearth with the ID and, with no thread about the
# server, opens the new thread's form titled "<name> [<address>]"; with
# one (made under the Servers topic by the first run), that thread. No
# button for a server not off the list, or with no ID logged in. The
# overlay's Discuss in the game ([OVERLAY_DISCUSS]) leaves it too, and the
# Hearth offers the server or its game.
# Needs luanti in PATH and devtest in the desk's games.
#   util/discuss_server_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/devtest"
[ -d "$G" ] || { echo "SKIP: no devtest"; exit 0; }
command -v luanti > /dev/null || { echo "SKIP: no luanti"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
tmp=$(mktemp -d "/tmp/buildat_discuss.XXXXXX")
SP=29681
HE=29682
LU=30179
export BUILDAT_CONNECT_PORTS="$SP,$HE"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

mkdir -p "$tmp/games" "$tmp/w"
cp -r "$G" "$tmp/games/"
printf 'gameid = devtest\nbackend = sqlite3\n' > "$tmp/w/world.mt"
LUANTI_GAME_PATH="$tmp/games" MINETEST_GAME_PATH="$tmp/games" \
	luanti --server --world "$tmp/w" --port $LU > "$tmp/lu.log" 2>&1 &
pids+=($!)
start_server "$tmp/sp.log" "setup code" 120 $SP \
	Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -l 3 ||
	fail "the Starport did not start (sp.log)"
pids+=($SERVER_PID)
code=$(grep -o "setup code [A-Z0-9]*" "$tmp/sp.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "the Starport did not start (sp.log)"
# Once the Starport listens, or the Hearth's first announce is lost
mkdir -p "$tmp/he/apps/hearth"
cat > "$tmp/he/apps/hearth/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Check hearth", "ids": "anyone",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
start_server "$tmp/he.log" "setup code" 120 $HE \
	Build/bin/buildat_server -m apps/hearth -D "$tmp/he" -l 3 ||
	fail "the Hearth did not start (he.log)"
pids+=($SERVER_PID)
wait_for_log "$tmp/sp.log" "verified ok" 60 ||
	fail "the Hearth was not listed ($tmp/he.log)"
# The Starport's admin: the Hearth recommended, its listing claimed; the
# claim, the script's third request, answered
read -r _ _ id _ _ ccode < <(grep -v "^#" "$tmp/he/apps/hearth/starport_claim.txt")
printf '%s\n' 'wait_log 30000 sp: {"id":3,' quit > "$tmp/cmds.txt"
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_CREATE=1 BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false,\"recommended_hearth\":\"http://127.0.0.1:$HE\"}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/admin" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$SP -c @"$tmp/cmds.txt" > "$tmp/admin.log" 2>&1 ||
	fail "the Starport's admin drive ($tmp/admin.log)"
# The Hearth's admin, an ID of its own by the setup code; and the reader's
# session for the client
read -r boss session < <(python3 - "$SP" "$id" <<'PY'
import json, sys, time, urllib.request
B = "http://127.0.0.1:%s/api/v1/" % sys.argv[1]
def call(w, **k):
    r = json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
    assert r["ok"], r
    return r["result"]
y = time.gmtime().tm_year - 40
b = call("id/register", name="boss", password="secret1", birth_year=y)
t = call("id/token", session=b["session"], listing=sys.argv[2], name="boss")
r = call("id/register", name="reader", password="secret1", birth_year=y)
print(t["token"], r["session"])
PY
) || fail "the ID API"
setup=$(grep -ao "setup code [A-Z0-9]*" "$tmp/he.log" | tail -1 | cut -d' ' -f3)
printf '%s\n' "wait_log_any 30000 Joined as" quit > "$tmp/boss.txt"
BUILDAT_HEARTH_STARPORT=$boss BUILDAT_HEARTH_CODE=$setup timeout 90 \
	Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/boss" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$HE -c @"$tmp/boss.txt" > "$tmp/boss.log" 2>&1 ||
	fail "the Hearth's admin drive ($tmp/boss.log)"
grep -q "claimed the server with the setup code" "$tmp/he.log" ||
	fail "the Hearth got no admin ($tmp/boss.log)"

# The client: the reader logged in, the Starport's recommendation as its
# list fetch keeps it, the Luanti server's address allowed
client_dir() { # dir with_id
	mkdir -p "$1"
	local ids=""
	[ "$2" = 1 ] && ids="\"ids\": {\"http://127.0.0.1:$SP\": {\"session\": \"$session\", \"name\": \"reader\"}},"
	cat > "$1/starport.json" <<EOF
{"starports": ["http://127.0.0.1:$SP"], $ids
 "recommends": {"http://127.0.0.1:$SP": {"hearth": "http://127.0.0.1:$HE", "aittas": []}}}
EOF
	local now; now=$(date +%s)
	printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","","%s","%s","","",""\n"true","udp://127.0.0.1:%s","","%s","%s","","",""\n' \
		$SP $now $now $LU $now $now > "$1/network_addresses.csv"
}
client_dir "$tmp/cl" 1
client_dir "$tmp/out" 0
wait_for_log "$tmp/lu.log" "Server for gameid" 60 ||
	fail "the Luanti server did not start ($tmp/lu.log)"
# luanti_client's dialog, made after its self-tests: Return through the
# address, name and password fields joins (a few frames for the focus to
# move between them); Escape, a scan of the pause menu; then the menu's
# second last row, Discuss, and the ID's first-time "Use it". listed: the
# name the launcher's serverlist cache has for the server, or none.
pause() { # dir log listed extra_cmds...
	local d=$1 log=$2 listed=$3
	shift 3
	rm -f "$d/extensions/serverlist/serverlist.csv"
	if [ -n "$listed" ]; then
		mkdir -p "$d/extensions/serverlist"
		printf '127.0.0.1:%s|%s|0|devtest\n' $LU "$listed" > "$d/extensions/serverlist/serverlist.csv"
	fi
	{
		# A settle after the line: the screen it opens laid out
		echo "wait_log_any 30000 world: self-test ok"; echo "delay 300"
		for _ in 1 2 3; do echo "keypress Return"; echo "delay 400"; done
		echo "wait_log_any 60000 voxel types have their own textures"
		if [ -z "${OVERLAY:-}" ]; then
			echo "keypress Escape"; echo "wait_log 5000 pause: the menu shown"
			echo "delay 300"; echo "event scan"
		fi
		for c in "$@"; do echo "$c"; done
		echo "quit"
	} > "$tmp/c"
	BUILDAT_LUANTI_ADDRESS=127.0.0.1:$LU BUILDAT_LUANTI_NAME=discusser \
		BUILDAT_HEARTH_REQS="${HEARTH_REQS:-}" \
		timeout 120 Build/bin/buildat -m luanti_client -D "$d" -w 800x600 -l 3 \
		-o sound_mute=1 -c @"$tmp/c" > "$log" 2>&1 ||
		fail "the drive ($log): $(grep -ao 'Command sequence failed.*' "$log" | head -1)"
}
# Discuss, the Hearth joined, the ID's name asked the first time only;
# then the page <page> and the scripted requests' answer (the first is
# 1001), in either order
discuss() { # first page
	echo "mouse_pos 400 377"; echo "mouse_click left"
	echo "wait_log 30000 Connect succeeded (127.0.0.1:$HE)"
	if [ "$1" = 1 ]; then
		# A settle after the line: the prompt laid out before the click
		echo "wait_log 30000 ID name prompt"; echo "delay 300"
		echo "mouse_pos 330 326"; echo "mouse_click left"
	fi
	echo "wait_log_any 30000 hearth: page $2"
	echo 'wait_log_any 20000 hr: {"id":1001,'; echo "delay 500"; echo "event scan"
}
# No thread yet: the form, its title the listed name -- a control
# character and a double space in it made one space -- and the address;
# then a thread made as the form's Send would make it
HEARTH_REQS="{\"cmd\":\"new_thread\",\"server\":true,\"subject\":\"server:127.0.0.1:$LU\",\"title\":\"Checked [127.0.0.1:$LU]\",\"body\":\"About it\",\"kind\":\"\"}" \
	pause "$tmp/cl" "$tmp/cl1.log" $'Check \x01 Server' \
	"$(discuss 1 "A thread about 127.0.0.1:$LU")"
grep -aq 'text "Discuss (leave server)"' "$tmp/cl1.log" ||
	fail "no Discuss in the pause menu ($tmp/cl1.log)"
grep -aq "hr discuss: .*server:127.0.0.1:$LU" "$tmp/cl1.log" ||
	fail "the Hearth was not handed the server ($tmp/cl1.log)"
grep -aq "hearth: page A thread about 127.0.0.1:$LU" "$tmp/cl1.log" ||
	fail "no new thread's form ($tmp/cl1.log)"
grep -aq "hearth: title Check Server \[127.0.0.1:$LU\]" "$tmp/cl1.log" ||
	fail "the title is not filled in ($tmp/cl1.log)"
echo "ok: Discuss with no thread opens the form, titled"

# The thread made above is what the next Discuss opens (a request of
# its own makes the Hearth say its pages)
HEARTH_REQS='{"cmd":"me"}' \
	pause "$tmp/cl" "$tmp/cl2.log" "Check Server" \
	"$(discuss 0 "Checked [127.0.0.1:$LU]")"
grep -aq "hearth: page Checked \[127.0.0.1:$LU\]" "$tmp/cl2.log" ||
	fail "the server's thread was not opened ($tmp/cl2.log)"
grep -aq "hearth: page A thread about" "$tmp/cl2.log" && fail "the form again ($tmp/cl2.log)"
echo "ok: Discuss opens the server's thread"

# [OVERLAY_DISCUSS]: the overlay's Discuss in the game leaves it, and the
# Hearth asks whether it is about the server or its game; a thread about
# the game, made as its form's Send would make it, is what the game's
# choice opens
HEARTH_REQS='{"cmd":"new_thread","game":true,"subject":"game:unknown:devtest","title":"devtest","body":"About it","kind":""}' \
	OVERLAY=1 pause "$tmp/cl" "$tmp/cl5.log" "Check Server" \
	"keypress F9" "wait_log 5000 trusted overlay shown" "delay 500" "event scan" \
	"mouse_pos 690 15" "mouse_click left" \
	"wait_log 30000 Connect succeeded (127.0.0.1:$HE)" \
	"wait_log 30000 hearth: page What is it about?" "delay 300" \
	"mouse_pos 300 98" "mouse_click left" 'wait_log_any 20000 hr: {"id":1001,' \
	"wait_log 10000 hearth: page devtest"
grep -aq "scan scan: mouse visible" "$tmp/cl5.log" ||
	fail "the mouse is not free with the overlay open ($tmp/cl5.log)"
grep -aq "hr discuss: .*game:unknown:devtest" "$tmp/cl5.log" ||
	fail "the Hearth was not handed the game ($tmp/cl5.log)"
grep -aq "hearth: page What is it about?" "$tmp/cl5.log" ||
	fail "no choice between the server and the game ($tmp/cl5.log)"
grep -aq 'hr: {"id":1001,"ok":true' "$tmp/cl5.log" ||
	fail "the game's thread was not made ($tmp/cl5.log)"
grep -aq "hearth: page devtest" "$tmp/cl5.log" ||
	fail "the game's thread was not opened ($tmp/cl5.log)"
echo "ok: the overlay's Discuss leaves the game and offers the server or the game"

# Typed in: no button; listed but no ID: no button
pause "$tmp/cl" "$tmp/cl3.log" ""
grep -aq 'text "Leave the game"' "$tmp/cl3.log" || fail "no pause menu ($tmp/cl3.log)"
grep -aq 'text "Discuss (leave server)"' "$tmp/cl3.log" && fail "Discuss for a typed address"
pause "$tmp/out" "$tmp/cl4.log" "Check Server"
grep -aq 'text "Leave the game"' "$tmp/cl4.log" || fail "no pause menu ($tmp/cl4.log)"
grep -aq 'text "Discuss (leave server)"' "$tmp/cl4.log" && fail "Discuss with no ID"
echo "PASS: Discuss goes to the server's thread or a new one; not for a typed address or without an ID"
