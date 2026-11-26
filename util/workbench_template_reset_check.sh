#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-27)
# covers: apps/workbench/main/** builtin/storage/** builtin/world_menu/**
# [KIT_TEMPLATE_RESET] A game made from a template, the template changed
# after, and the resets. The template is the check's own, installed in its
# user dir (<user>/installed/<fp>/reset_tmpl/1.0.0): a scene, a ground and
# a marker entity of its own type local/marker.
#   1. Server A, BUILDAT_WORKBENCH_TEMPLATE: the game g made from it; kitboss
#      (the admin) places a lever and puts an edited marker type. No notice.
#   2. The template changed (its marker type, a second marker entity);
#      server B: kitboss's notice names marker (notice.png); its Reset
#      types..., confirmed: a backup in the trash (g-<date>_1, the edit in
#      it), the template's marker in g, the lever kept.
#   3. kitboss told of the reset, no notice; Games... has the two resets
#      (games.png); Reset game, confirmed: a second backup, g's composition
#      the template's (its second marker, no lever).
#   4. Games...: the first backup restored beside g (as its entry's name, g
#      taken) and played: the edit and the lever back.
# Screenshots: $t/notice.png, confirm_types.png, games.png (KEEP_TMP=1 keeps)
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp workbench_template_reset; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

fp=0123456789abcdef0123
tm=$t/user/installed/$fp/reset_tmpl/1.0.0
mkdir -p "$tm/types"
cat > "$tm/meta.json" <<'EOF'
{
	"kind": "template",
	"author": "check",
	"name": "reset_tmpl",
	"title": "Reset check",
	"version": "1.0.0",
	"engine_api": 2,
	"kit_api": 1,
	"license_code": "CC0-1.0",
	"license_media": "CC0-1.0",
	"description": "A check's template: a ground and a marker."
}
EOF
echo "A check's template, CC0." > "$tm/LICENSE"
comp() # <extra entity JSON or "">
{
	cat > "$tm/composition.json" <<EOF
{
	"kit": 1,
	"api": 1,
	"entities": [
		{"id": 2, "name": "world", "kind": "scene"},
		{"id": 3, "parent": 2, "name": "the ground", "components": [{"type": "kit/terrain", "version": 2, "params": {"generator": "flat", "surface": "voxels", "biome": "grassland", "decorations": false, "width": 16, "depth": 16}}]},
		{"id": 4, "parent": 2, "name": "the marker", "pos": [2, 1, 2], "components": [{"type": "local/marker", "version": 1, "params": {}}]}$1
	],
	"next_id": 6
}
EOF
}
marker() # <first line>
{
	printf -- '%s\nreturn {version = 1, about = {what = "A check'"'"'s marker."}, component = true, params = {}}\n' "$1" > "$tm/types/marker.lua"
}
comp ""
marker "-- V1"

# A save's rows, read only: the marker type's source and by, the authored
# entities' names
rows() # <save.sqlite>
{
	python3 -I - "$1" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
def get(store, key):
	r = db.execute("SELECT value FROM store WHERE store=? AND key=?", (store, key)).fetchone()
	return r[0].decode() if isinstance(r and r[0], bytes) else (r[0] if r else "")
m = json.loads(get("kit", "type:local/marker") or "{}")
a = json.loads(get("kit", "authored") or "{}")
print("marker=%s by=%s" % (m.get("source", "").split("\n")[0], m.get("by", "")))
print("names=%s" % ",".join(sorted(e.get("name", "") for e in a.get("entities", []))))
print("hash=%s" % get("workbench", "template_hash")[:12])
PY
}
saves() { find "$t/user" -type d -name saves -path "*workbench*" | head -1; }

s=
server() # <log name>
{
	s=$t/$1.log
	BUILDAT_WORKBENCH_PROJECT=g BUILDAT_WORKBENCH_TEMPLATE=$fp/reset_tmpl \
		start_server "$s" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
		fail "the server did not come up ($s)"
	CHECK_PIDS+=($SERVER_PID)
}
stop_server()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
client() # <name> [env...]: its commands in $t/<name>.cmds; 0 when the drive ran to its quit
{
	local n=$1
	shift
	sed -i "s|@T@|$t|g" "$t/$n.cmds"
	env "$@" timeout 300 bin/buildat -C "$t/client_cache" -D "$t/cu_$n" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 \
		-c @"$t/$n.cmds" > "$t/$n.log" 2>&1
	! grep -aq "Command sequence failed" "$t/$n.log" &&
		grep -aq "command: quit" "$t/$n.log"
}
JOINED='wait_log_any 60000 player physics enabled
wait_log_any 30000 kit editor: edit rights:'
GONE='Disconnected from server: The game g is being reset to its template'

# 1.
server srv_a
grep -aq 'workbench: the project from the template '$fp/reset_tmpl "$s" ||
	fail "g not made from the template ($s)"
cat > "$t/boss1.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
$JOINED
wait_log_any 30000 kit editor: state:
event kit_edit {"op": "place", "type": "kit/lever", "pos": [5, 1, 5]}
wait_log 10000 entities, 1 to undo
event kit_type {"op": "put", "name": "marker", "source": "-- EDITED\nreturn {version = 1, about = {what = \"An edited marker.\"}, component = true, params = {}}\n"}
wait_log 10000 entities, 1 to undo
quit
EOF
wait_for_log "$s" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$s" | head -1)
[ -n "$code" ] || fail "no setup code ($s)"
client boss1 BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" ||
	fail "kitboss in g ($t/boss1.log)"
grep -aq 'to kitboss, the template: .*"changed":false.*"notice":false' "$s" ||
	fail "a notice in a game just made ($s)"
stop_server
sv=$(saves)
[ -n "$sv" ] && [ -f "$sv/g/save.sqlite" ] || fail "no saves dir with g ($t/user)"
r=$(rows "$sv/g/save.sqlite")
echo "$r" | grep -q "marker=-- EDITED by=kitboss" || fail "the edit not in g: $r"
echo "$r" | grep -q "names=.*kit/lever\|names=.*lever" || fail "the lever not in g: $r"
h1=$(echo "$r" | grep -o 'hash=.*')
[ "$h1" != "hash=" ] || fail "no template hash recorded: $r"
echo "ok: g made from the template ($h1), a lever placed and marker edited, no notice"

# 2.
marker "-- V2"
comp ',
		{"id": 5, "parent": 2, "name": "the second marker", "pos": [4, 1, 2], "components": [{"type": "local/marker", "version": 1, "params": {}}]}'
server srv_b
cat > "$t/boss2.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
$JOINED
wait_log_any 30000 confirm dialog: The template Reset check has changed
frames 3
screenshot @T@/notice.png
click Button "Reset types..."
wait_log 5000 confirm dialog: Reset the types to the template Reset check?
frames 3
screenshot @T@/confirm_types.png
expect_error $GONE
click Button "Reset types"
wait_log 60000 $GONE
quit
EOF
client boss2 BUILDAT_JOIN_NAME=kitboss || fail "the notice and Reset types ($t/boss2.log)"
# (a dialog's lines each a line of the log)
grep -aA1 "confirm dialog: The template Reset check has changed" "$t/boss2.log" |
	grep -q "^Its types edited here: marker\.$" ||
	fail "the notice does not name marker ($t/boss2.log)"
grep -aA4 "confirm dialog: Reset the types" "$t/boss2.log" | grep -q "^Edited here, and lost: marker\.$" &&
	grep -aA4 "confirm dialog: Reset the types" "$t/boss2.log" |
	grep -q "^A backup copy of the game goes to the trash first" ||
	fail "the confirmation ($t/boss2.log)"
wait_for_log "$s" 'workbench: "g" reset_types done' 120 || fail "Reset types not done ($s)"
e1=$(grep -aoP 'Save g copied to .*/trash/\K\S+' "$s" | head -1)
[ -n "$e1" ] && [ -f "$sv/trash/$e1/save.sqlite" ] || fail "no backup in the trash ($s)"
case "$e1" in g-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_1) ;; *) fail "the backup's name: $e1";; esac
r=$(rows "$sv/trash/$e1/save.sqlite")
echo "$r" | grep -q "marker=-- EDITED by=kitboss" || fail "the edit not in the backup $e1: $r"
r=$(rows "$sv/g/save.sqlite")
echo "$r" | grep -q "marker=-- V2 by=the template" || fail "the template's marker not in g: $r"
echo "$r" | grep -q "lever" || fail "Reset types took the lever: $r"
echo "$r" | grep -q "the second marker" && fail "Reset types took the composition: $r"
echo "ok: the notice named marker; Reset types: the template's marker, the lever kept, the backup $e1 with the edit"

# 3.
cat > "$t/boss3.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
$JOINED
wait_log_any 30000 workbench: said: The types reset to the template Reset check
keypress Escape
wait_log 5000 pause: the menu shown
frames 3
click Button "Games..."
wait_log 10000 world_menu: the list shown, 1 worlds, 1 in the trash
frames 3
screenshot @T@/games.png
click Button "Reset game to template..."
wait_log 5000 confirm dialog: Reset the game to the template Reset check?
frames 3
expect_error $GONE
click Button "Reset game"
wait_log 60000 $GONE
quit
EOF
client boss3 BUILDAT_JOIN_NAME=kitboss || fail "Games...' Reset game ($t/boss3.log)"
grep -aq "confirm dialog: The template" "$t/boss3.log" && fail "a notice again after the reset ($t/boss3.log)"
wait_for_log "$s" 'workbench: "g" reset_game done' 120 || fail "Reset game not done ($s)"
e2=$(grep -aoP 'Save g copied to .*/trash/\K\S+' "$s" | sed -n 2p)
case "$e2" in "${e1%_1}_2") ;; *) fail "the second backup's name: \"$e2\" ($s)";; esac
r=$(rows "$sv/g/save.sqlite")
echo "$r" | grep -q "the second marker" || fail "the template's composition not in g: $r"
echo "$r" | grep -q "lever" && fail "the lever kept by Reset game: $r"
echo "$r" | grep -q "marker=-- V2 by=the template" || fail "the template's marker not in g after Reset game: $r"
echo "ok: Reset game from Games...: the template's composition, a second backup $e2"

# 4.
cat > "$t/boss4.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
$JOINED
keypress Escape
wait_log 5000 pause: the menu shown
frames 3
click Button "Games..."
wait_log 10000 world_menu: the list shown, 1 worlds, 2 in the trash
frames 3
click Button "g (in the trash, ${e1:2:10} backup 1)"
wait_log 5000 confirm dialog: The game g is in the trash
click Button "Restore"
wait_log 10000 world_menu: said: g restored as $e1 (the name was taken)
frames 3
click Button "$e1"
wait_log 5000 world_menu: the list shown
frames 3
expect_error Disconnected from server: The server is switching
click Button "Play"
wait_log 60000 Disconnected from server: The server is switching to the game $e1
quit
EOF
client boss4 BUILDAT_JOIN_NAME=kitboss || fail "the restore ($t/boss4.log)"
wait_for_log "$s" "workbench: switched to \"$e1\"" 120 || fail "$e1 did not start ($s)"
r=$(rows "$sv/$e1/save.sqlite")
echo "$r" | grep -q "marker=-- EDITED by=kitboss" || fail "the edit not back in $e1: $r"
echo "$r" | grep -q "lever" || fail "the lever not back in $e1: $r"
[ -f "$sv/g/save.sqlite" ] || fail "g gone with the restore"
stop_server
echo "PASS: a game from a template told its builder of the template's change, naming the edited type; Reset types and Reset game each put a backup (${e1%_1}_<n>) into the trash first and gave the template's types, then its composition; the first backup restored beside the game with the edit and the lever"
# vim: set noet ts=4 sw=4:
