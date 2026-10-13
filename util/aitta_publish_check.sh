#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-07)
# covers: client/extensions/aitta/publish.lua src/client/app.cpp client/launch_grid.lua apps/aitta/main/main.cpp apps/aitta/main/client_lua/init.lua
# [AITTA_PUBLISH_UI]: publishing without a terminal, at 800x600, on a
# fresh user path and a local Aitta. Settings -> Developer's "Publish an
# app or extension" (found by typing "publish"):
#   1. "New app..." refuses a bad name with its reason, then makes hello
#      in <user>/dev_apps; the form refuses a bad author with its reason;
#   2. the key is made, bound on the Aitta by the handover (the Aitta's
#      Bind form filled in), and the screen then says it is bound;
#   3. packed and published; the same version again refused in words
#      with "Raise the version", which publishes as 0.1.1;
#   4. an extension the same way;
#   5. hello played from its Dev tile; both releases installed from "Apps
#      from Aitta" on a second client.
# Keys drive the publish screen (Tab, Return: its layout moves with the
# paths in it); the mouse the Aitta's page and Apps from Aitta, whose
# layouts are fixed.
#   util/aitta_publish_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
t=$(mktemp -d "/tmp/buildat_publish.XXXXXX")
pid=
cleanup(){
	[ -n "$pid" ] && kill $pid 2>/dev/null
	[ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "$t"
}
trap cleanup EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here/Build"

start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
pid=$SERVER_PID
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

# A user path with only this Aitta, its address already allowed
user(){
	mkdir -p "$t/$1"
	echo "{\"starports\": [], \"aittas\": [\"http://127.0.0.1:$P\"]}" \
		> "$t/$1/starport.json"
	local now; now=$(date +%s)
	printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","","%s","%s","","",""\n' \
		$P $now $now > "$t/$1/network_addresses.csv"
}
user u
user u2
# client <user> <name> <cmd lines...>: the commands, a scan after each
# "scan", and the log in <name>.log
client(){
	local u=$1 n=$2; shift 2
	printf '%s\n' "$@" quit | sed "s#^shot #screenshot $t/#" > "$t/$n.cmds"
	BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin \
	BUILDAT_AITTA_PASSWORD=checkpass BUILDAT_AITTA_CODE=$code \
		timeout 240 bin/buildat -o launch_ui=launch_menu -D "$t/$u" \
		-C "$t/c_$u" -w 800x600 -l 3 -o sound_mute=1 -c @"$t/$n.cmds" \
		> "$t/$n.log" 2>&1 ||
		fail "the $n drive ($n.log): $(grep -ao 'Command sequence failed.*' "$t/$n.log" | head -1)"
}
tabs(){ for _ in $(seq "$1"); do echo "keypress Tab"; done; }
backs(){ for _ in $(seq "$1"); do echo "keypress BackSpace"; done; }
# A dropdown: open it and pick its first choice. The delays are the frames
# its list takes to open and close, which nothing logs
pick1(){ echo "delay 100"; echo "keypress Space"; echo "delay 500"; echo "keypress Down"; echo "delay 100"; echo "keypress Return"; echo "delay 300"; }
said(){ grep -aqF "text \"$2" "$t/$1.log"; }
# The launcher's search for <what>, and its first row run: <first wait>
# is the launcher drawn (its rows logged), at the start or back from a world
open(){ echo "$2"; echo "text $1"; echo "wait_log 10000 rows for \"$1\" in"
	echo "keypress Return"; }
START="wait_log_any 60000 rows in"
# A page of the publish screen drawn; the 300 ms after it are its layout's
# frames before a key or a scan reads it
page(){ echo "wait_log $2 aitta publish: $1"; echo "delay 300"; }

# 1, 2: the app, the form, the key, the bind; then 3
mapfile -t cmds < <(
	open publish "$START"; page "the package page" 10000
	# "New app...", the focused button on an empty page
	echo "keypress Return"; page "a new app's name asked" 5000
	echo "text Bad-Name"; echo "keypress Return"; page "not made" 5000
	echo "event scan"
	backs 8; echo "text hello"; echo "keypress Return"
	page "the package page, hello" 5000
	# The page with hello: hello, New app, New extension, Open folder,
	# then the fields from Author; the reason under it in the frames
	# after the typing
	tabs 4; echo "text Bad"; echo "delay 500"; echo "event scan"
	backs 3; echo "text tester"
	tabs 3; echo "text Says hello."
	tabs 1; pick1; tabs 1; pick1
	# Audience, Home Hearth, Changelog, Icon, Screenshot, Save, Next
	tabs 7; echo "keypress Return"; page "the key page, no key" 5000
	# Page 2: "Create my publishing key" has the focus; the Aitta asked
	# about it
	echo "keypress Return"; page "the key page, The key is not bound" 20000
	echo "event scan"
	# Show the file, Bind on...: the world joined, logged in
	tabs 1; echo "keypress Return"; echo "wait_log 60000 accounts: ntfy asked"
	echo "delay 1000" # the question's window drawn after the line
	# The admin's ntfy question first, in the Aitta's window: Later, back
	# to the Aitta's page ([NTFY_ASK_OVER_GAME])
	echo "mouse_pos 437 134"; echo "mouse_click left"
	echo "wait_log 10000 aitta: home, no author"; echo "delay 500"
	echo "shot bind.png"; echo "event scan"
	# The Aitta's page: Bind, then Back to the launcher
	echo "mouse_pos 422 177"; echo "mouse_click left"
	echo "wait_log 10000 aitta: home, author tester"; echo "delay 500"
	echo "mouse_pos 422 139"; echo "mouse_click left"
	open publish "wait_log 30000 launch_menu: back to Home"
	page "the package page" 10000
	tabs 16; echo "keypress Return"; page "the key page, The key is bound" 20000
	echo "event scan"
	# Show the file, Back, Pack and publish
	tabs 2; echo "keypress Return"; page "published tester/hello/0.1.0" 20000
	echo "event scan"
	tabs 2; echo "keypress Return"; page "not published" 20000
	echo "event scan"
	echo "shot duplicate.png"
	# Show the file, Back, Pack and publish, Raise the version
	tabs 3; echo "keypress Return"; page "raised to 0.1.1" 5000
	tabs 2; echo "keypress Return"; page "published tester/hello/0.1.1" 20000
	echo "event scan"
	# 4. Back; hello, New app, New extension
	tabs 1; echo "keypress Return"; page "the package page" 5000
	tabs 2; echo "keypress Return"; page "a new extension's name asked" 5000
	echo "text hello_ext"; echo "keypress Return"
	page "the package page, hello_ext" 5000
	# Package, New app, New extension, Open folder, Author; a frame on
	# the field before typing, the focus coming from a dropdown
	tabs 4; echo "delay 100"; echo "text tester"; tabs 3; echo "text Says hello too."
	tabs 1; pick1; tabs 1; pick1
	tabs 7; echo "keypress Return"; page "the key page, The key is bound" 20000
	tabs 2; echo "keypress Return"; page "published tester/hello_ext/0.1.0" 20000
	echo "event scan"
	echo "shot extension.png"
)
client u publish "${cmds[@]}"
said publish "A name is 1 to 40 of a-z, 0-9 and _" ||
	fail "New app... did not refuse Bad-Name with its reason (publish.log)"
[ -f "$t/u/dev_apps/hello/main/client_lua/init.lua" ] ||
	fail "New app... made no hello in dev_apps"
grep -aqE 'text ".*author.*: 1 to 40 of a-z' "$t/publish.log" ||
	fail "the form did not refuse the author \"Bad\" with its reason"
grep -q '"author" : "tester"' "$t/u/dev_apps/hello/meta.json" ||
	fail "the form did not save the author ($(cat "$t/u/dev_apps/hello/meta.json"))"
[ -f "$t/u/aitta_keys/tester.key" ] || fail "no key made"
said publish "The key is not bound on" || fail "the screen did not say the key is not bound yet"
grep -aq "admin bound the author name tester" "$t/srv.log" ||
	fail "the key was not bound on the Aitta (bind.png)"
said publish "The key is bound to tester on" ||
	fail "the screen did not say the key is bound after the bind"
grep -aq "Listed tester/hello/0.1.0" "$t/srv.log" || fail "0.1.0 not published"
said publish "Published tester/hello/0.1.0" || fail "the screen did not say 0.1.0 was published"
said publish "0.1.0 is already published: raise the version" ||
	fail "the duplicate was not refused in words (duplicate.png)"
grep -aq "Listed tester/hello/0.1.1" "$t/srv.log" ||
	fail "\"Raise the version\" did not publish 0.1.1"
echo "ok: an app made, its manifest checked, a key made and bound, published, a duplicate refused, raised"
grep -aq "Listed tester/hello_ext/0.1.0" "$t/srv.log" ||
	fail "the extension was not published (extension.png)"
echo "ok: an extension published the same way"

# 5. Played from its tile; installed on another client
mapfile -t cmds < <(open hello "$START"; echo "wait_log 60000 hello started")
client u play "${cmds[@]}"
grep -aq "module_path: .*/dev_apps/hello" "$t/play.log" ||
	fail "the Dev tile did not start dev_apps/hello (play.log)"
# Not the wait's own line
grep -a "hello started" "$t/play.log" | grep -qv "wait_log" ||
	fail "hello's client Lua did not run (play.log)"
# Apps from Aitta lists hello (0.1.1, its newest) and the extension:
# each selected and installed from its panel ([AITTA_PAGE_LAYOUT])
# The list's rows are made right after its releases are logged; the page
# is drawn again, and the list fetched again, after each install
LISTED="wait_log 20000 aitta page: tester/hello_ext"
mapfile -t cmds < <(open aitta "$START"
	echo "$LISTED"; echo "delay 500"; echo "shot aitta.png"
	# The first row's panel is filled with the list. No click on its row:
	# a click there and Install's in one frame read as a double click,
	# which installs too
	echo "wait_log_any 5000 aitta panel: tester/hello 0.1.1"
	echo "click Button \"Install\""
	echo "wait_log 20000 aitta status: Installed tester/hello 0.1.1"
	echo "$LISTED"; echo "delay 500"
	echo "click Button \"tester/hello_ext\""
	echo "wait_log 5000 aitta panel: tester/hello_ext 0.1.0"
	echo "click Button \"Install\""
	echo "wait_log 20000 aitta status: Installed tester/hello_ext 0.1.0"
	echo "delay 500"; echo "shot installed.png")
client u2 install "${cmds[@]}"
[ -d "$t/u2/installed/tester/hello/0.1.1" ] ||
	fail "0.1.1 was not installed from Apps from Aitta (aitta.png)"
[ -f "$t/u2/installed/tester/hello_ext/0.1.0/init.lua" ] ||
	fail "the extension was not installed from Apps from Aitta (installed.png)"
echo "PASS: made, played, checked, keyed, bound, published, refused, raised, an extension; both installed elsewhere"
