#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [BOX_PLAYTEST_2] (8): the key that opens a form must not type into the
# field the form focuses. VoxeLibre's creative inventory (E) focuses its
# search field; after the press the field must be empty. A real key is a
# KeyDown and a TextInput in one frame and the sequencer's keypress is
# only the first, so the text is injected beside it. Prints PASS or FAIL;
# the log is under local/form_key/.
#
#   builtin/luanti/test/form_key.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
out="$here/local/form_key"
mkdir -p "$out"
save="buildat_test_form_key"
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
cat > "$out/fixture.lua" <<'LUA'
core.settings:set("creative_mode", "true")
core.settings:set("time_speed", "0")
core.settings:set("mobs_spawn", "false")
LUA
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 400 29785 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap "kill -INT $srv 2>/dev/null" EXIT
# The 2 s after the settle: VoxeLibre's inventory formspec arrives a few
# ticks after the join and nothing marks it on the client. The form's
# field is focused, and its scan done, in the frames after "opened"
cat > "$out/cmds.txt" <<CMDS
wait_log 60000 the server put the player
wait_log 60000 scene, 0 undrawn within 2
delay 2000
keypress E
text e
wait_log 10000 opened
delay 500
event scan
quit
CMDS
bin/buildat -s localhost:29785 -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	{ echo "FAIL: the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"; exit 1; }
kill -INT "$srv" 2>/dev/null
# A poll: the server's exit
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
edits=$(grep -a "scan scan: ui.*LineEdit" "$out/cli.log" | sed 's/.*text \("[^"]*"\).*/\1/')
echo "fields: $edits"
if [ -z "$edits" ]; then echo "FAIL: no form field on the screen"; exit 1; fi
if echo "$edits" | grep -q '"[^"]'; then echo "FAIL: the key typed into the field"; exit 1; fi
echo "PASS: the form's field is empty after the key that opened it"
