#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-16)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/editor.lua builtin/kit/client_lua/field_entry.lua src/client/state.cpp
# drives: builtin/kit/client_lua/editor.lua builtin/kit/client_lua/field_entry.lua
# [KIT_AGENT_VISUALS] An entity's comments, the builders' notes on it, on
# Workbench: kitboss (the admin, by the setup code) on a headless weston's
# Xwayland of the check's own, kitbob (a player, no edit rights) joining:
#   1. a kit/timer selected: the inspector's Comments button plain, the
#      field hidden; Comments shows it, two lines typed (Return a newline),
#      Save comments: the server sets them (36 bytes, the newline in), the
#      button cyan; Comments hides the field again; Ctrl+Z takes them back
#      (plain); 40 lines set: the field's scroll bar, a click on it
#      scrolls them ([KIT_AGENT_FEEDBACK_1117], $t/scrolled.png); an edit
#      sets the two lines again;
#   2. kitbob's edit of them refused; every packet kitbob's client got
#      (BUILDAT_PACKET_DUMP) without the text, kitboss's with it;
#   3. a scene "notes" with a commented timer exported (its
#      composition.json has them), removed, added again from the file
#      (the scene list's Add from a file...): its state has them;
#   4. the server again from its save: the timer's button cyan;
#   5. the web client (headless Chrome as a phone, touch, 412x915, the
#      touch mode; skipped without web/ or Chrome): a New game's World
#      selected, Comments, the field tapped opens the field entry mode (its
#      scroll bar there), two lines typed, its Apply: the server sets
#      them, the button cyan.
# The button's colour read from the screenshots, kept with KEEP_TMP=1:
# $t/plain.png, $t/cyan.png (the field shown with the text), $t/hidden.png,
# $t/restart.png, $t/web/entry.png, $t/web/cyan.png
#   util/kit_comments_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_comments; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
check_build
sock=buildat-notes-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
CLIENT=
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		[ -z "$CLIENT" ] || kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
}
cmd() { printf '%s\n' "$@" >&3; }
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
edit() # <regex in the server's log> <kit:edit JSON>
{
	local m
	m=$(mark "$SL")
	cmd "event kit_edit $2"
	await "$SL" "$m" 10 "$1"
}
ID= # placed's
placed() # <type> <name>: ID the new entity's
{
	local m
	m=$(mark "$SL")
	cmd "event kit_edit {\"op\": \"place\", \"type\": \"$1\", \"pos\": [2, 9, 2]}"
	await "$SL" "$m" 10 "An edit by kitboss: placed $1 [0-9]+|An edit \(place\) by peer [0-9]+ refused"
	ID=$(tail -c +$((m + 1)) "$SL" | grep -aoP "An edit by kitboss: placed \S+ \K[0-9]+" | head -1)
	[ -n "$ID" ] || fail "no id of the placed $1 ($SL)"
	edit "An edit by kitboss: renamed $ID to $2" "{\"op\": \"rename\", \"id\": $ID, \"name\": \"$2\"}"
}
R= # where's
where() # <tag>: R the inspector's Comments button, "x y w h" (pixels)
{
	local m
	m=$(mark "$CL")
	cmd "frames 3" "event kit_ui_where $1"
	await "$CL" "$m" 10 "kit editor: the inspector comments at [0-9]+ [0-9]+ [0-9]+ [0-9]+"
	R=$(tail -c +$((m + 1)) "$CL" | grep -aoP "kit editor: the inspector comments at \K[0-9]+ [0-9]+ [0-9]+ [0-9]+" | tail -1)
}
server() # <log>: Workbench in $t/srv
{
	SL=$1
	start_server "$SL" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/srv" -l 3 \
		--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
	SRV=$SERVER_PID
	CHECK_PIDS+=($SRV)
}
boss() # <name> [env...]: kitboss in $t/cu_<name>, its commands from a fifo (fd 3), the tools on, Stopped
{
	local n=$1
	shift
	mkfifo "$t/$n.cmd"
	sleep 900 > "$t/$n.cmd" &
	CHECK_PIDS+=($!)
	CL=$t/$n.log
	env "$@" DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
		timeout 600 bin/buildat -C "$t/client_cache" -D "$t/cu_$n" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 \
		-c - < "$t/$n.cmd" > "$CL" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
	exec 3> "$t/$n.cmd"
	await "$CL" 0 120 "Joined as kitboss"
	# (the server's first join's)
	[ -z "$NTFY" ] || cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" \
		'click Button "Don'"'"'t add"'
	await "$CL" 0 60 "player physics enabled"
	await "$CL" 0 30 "kit editor: edit rights: yes"
	step 20 "kit editor: edit mode on" "frames 3" "keypress F6"
	await "$CL" 0 20 "kit editor: the server is (Running|Ended)"
	if grep -a "kit editor: the server is" "$CL" | tail -1 | grep -q Running; then
		step 10 "kit editor: the server is Ended" 'event kit_edit {"op": "stop"}'
	fi
}
# cyan <png> <x y w h>: the pixels of the focus colour (#26d9ff) in the
# rectangle, 3 px in from each side (a focused button's border)
cyan()
{
	python3 -I - "$@" <<'PY'
import struct, sys, zlib
d = open(sys.argv[1], "rb").read(); p = 8; idat = b""
while p < len(d):
    n, k = struct.unpack(">I4s", d[p:p + 8])
    if k == b"IHDR": w, h, bd, ct = struct.unpack(">IIBB", d[p + 8:p + 18])
    if k == b"IDAT": idat += d[p + 8:p + 8 + n]
    p += 12 + n
bpp = 4 if ct == 6 else 3
raw = zlib.decompress(idat); s = w * bpp + 1
x0, y0, rw, rh = map(int, sys.argv[2:6])
prev = bytearray(w * bpp); hits = 0
for y in range(min(h, y0 + rh - 3)):
    f = raw[y * s]; row = bytearray(raw[y * s + 1:(y + 1) * s])
    for i in range(len(row)):
        a = row[i - bpp] if i >= bpp else 0; b = prev[i]; c = prev[i - bpp] if i >= bpp else 0
        if f == 1: row[i] = (row[i] + a) & 255
        elif f == 2: row[i] = (row[i] + b) & 255
        elif f == 3: row[i] = (row[i] + (a + b) // 2) & 255
        elif f == 4:
            pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
            row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    if y >= y0 + 3:
        for x in range(x0 + 3, min(w, x0 + rw - 3)):
            r, g, bl = row[x * bpp:x * bpp + 3]
            hits += r < 110 and g > 150 and bl > 200
    prev = row
print(hits)
PY
}
NOTE="Spawn zqxnote7731 timer.
Second line"
NOTE2="Imported zqximport4419 note."

# 1. kitboss: the inspector's Comments
server "$t/srv.log"
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
NTFY=1
boss boss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_ADMIN="setting open_registration on" \
	BUILDAT_PACKET_DUMP=$t/boss.packets
await "$SL" 0 30 "kitboss set open_registration to 1"

placed kit/timer "Spawn timer"
T=$ID
step 10 "kit editor: comments of $T: 0 bytes, the button plain, the field hidden" \
	"frames 3" "event kit_select $T"
where plain
RP=$R
cmd "frames 5" "screenshot $t/plain.png"
step 10 "kit editor: comments of $T: 0 bytes, the button plain, the field shown" \
	"frames 3" 'click Button "Comments"'
m=$(mark "$SL") mc=$(mark "$CL")
cmd "frames 3" 'click LineEdit "comments"' "frames 3" "text Spawn zqxnote7731 timer." \
	"keypress Return" "text Second line" "frames 3"
step 10 "kit editor: comments of $T saved, ${#NOTE} bytes" 'click Button "Save comments"'
await "$SL" "$m" 10 "An edit by kitboss: set $T's comments"
tail -c +$((m + 1)) "$SL" | grep -a "An edit by kitboss: set $T's comments" | head -1 |
	grep -qF "(${#NOTE} bytes)" || fail "not the two lines typed: $(grep -a "set $T's comments" "$SL" | head -1) ($SL)"
await "$CL" "$mc" 10 "kit editor: comments of $T: ${#NOTE} bytes, the button cyan, the field shown"
where cyan
RC=$R
cmd "frames 5" "screenshot $t/cyan.png"
step 10 "kit editor: comments of $T: ${#NOTE} bytes, the button cyan, the field hidden" \
	"frames 3" 'click Button "Comments"'
cmd "frames 5" "screenshot $t/hidden.png"
echo "ok: typed in the field (Return a newline), saved by its Save, the button cyan"
m=$(mark "$SL")
step 10 "kit editor: comments of $T: 0 bytes, the button plain, the field hidden" \
	"frames 3" "keydown ctrl" "keypress z" "keyup ctrl"
await "$SL" "$m" 10 "An undo by kitboss: 1 entities put back"
# [KIT_AGENT_FEEDBACK_1117] 40 lines: the field's scroll bar (more than a
# field's height of text), a click on it scrolls the text down
long=$(python3 -c 'print("\\n".join("Line %d" % i for i in range(40)))')
edit "An edit by kitboss: set $T's comments" "{\"op\": \"comments\", \"id\": $T, \"text\": \"$long\"}"
step 10 "kit editor: comments's scroll bar: [1-9][0-9.]* views more" "frames 3" \
	'click Button "Comments"'
step 10 "kit editor: comments scrolled to [1-9][0-9]* by its bar" "frames 5" \
	'click ScrollBar "comments bar"'
cmd "frames 3" "screenshot $t/scrolled.png"
step 10 "kit editor: comments of $T: [0-9]+ bytes, the button cyan, the field hidden" \
	"frames 3" 'click Button "Comments"'
echo "ok: 40 lines: the field's scroll bar, a click on it scrolled them"
m=$(mark "$CL")
edit "An edit by kitboss: set $T's comments \(${#NOTE} bytes\)" \
	"{\"op\": \"comments\", \"id\": $T, \"text\": \"Spawn zqxnote7731 timer.\\nSecond line\"}"
await "$CL" "$m" 10 "kit editor: comments of $T: ${#NOTE} bytes, the button cyan, the field hidden"
echo "ok: Ctrl+Z took them back, an edit set them again"

# 2. kitbob, a player, joins as they are there, every packet his client
# gets kept; his edit of them refused
mkfifo "$t/bob.cmd"
sleep 900 > "$t/bob.cmd" &
CHECK_PIDS+=($!)
BL=$t/bob.log
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitbob \
	BUILDAT_PACKET_DUMP=$t/bob.packets timeout 600 bin/buildat -C "$t/client_cache" \
	-D "$t/cu_bob" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 \
	-c - < "$t/bob.cmd" > "$BL" 2>&1 &
BOB=$!
CHECK_PIDS+=($BOB)
exec 4> "$t/bob.cmd"
await "$BL" 0 120 "Joined as kitbob"
await "$BL" 0 60 "player physics enabled"
await "$BL" 0 30 "kit editor: the server is (Ended|Running)"
! grep -aq "kit editor: edit rights: yes" "$BL" || fail "kitbob may edit ($BL)"
m=$(mark "$SL")
printf '%s\n' "event kit_edit {\"op\": \"comments\", \"id\": $T, \"text\": \"by bob\"}" >&4
await "$SL" "$m" 10 "An edit \(comments\) by peer [0-9]+ refused"
echo "ok: kitbob's edit of them refused"

# 3. Exported, removed, added again
step 20 "kit editor: in the scene notes " 'event kit_edit {"op": "new_scene", "name": "notes"}'
placed kit/timer "Note holder"
edit "An edit by kitboss: set $ID's comments \(${#NOTE2} bytes\)" \
	"{\"op\": \"comments\", \"id\": $ID, \"text\": \"$NOTE2\"}"
step 20 "kit editor: Exported to .*notes\.scene\.zip" 'event kit_edit {"op": "export_scene", "scene": "notes"}'
z=$t/cu_boss/exports/notes.scene.zip
python3 -I - "$z" "$NOTE2" <<'PY' || fail "the export's composition.json has no comments ($z)"
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
def has(v):
    if isinstance(v, dict):
        return v.get("comments") == sys.argv[2] or any(has(x) for x in v.values())
    return isinstance(v, list) and any(has(x) for x in v)
names = [n for n in z.namelist() if n.endswith("composition.json")]
assert names and any(has(json.loads(z.read(n))) for n in names), z.namelist()
PY
step 20 "kit editor: in the scene world " 'event kit_edit {"op": "scene", "name": "world"}'
edit "An edit by kitboss: removed the scene notes" '{"op": "remove_scene", "name": "notes"}'
o=$(wc -c < "$t/boss.packets")
# (the bar's scene list, nearest; the inspector's lists are nearer the
# corner. Scenes... only with two scenes)
m=$(mark "$SL")
cmd "frames 3" 'click DropDownList "▼" 250 15' "delay 300" "frames 3"
step 10 "The file picker at .*/exports" 'click Text "Add from a file..."'
step 60 "kit editor: Added the scene notes\S* " "frames 3" 'click Button "notes.scene.zip"'
await "$SL" "$m" 10 "kitboss adds the scene notes"
# (as notes_2: the removed one's name kept for its undo; there, unless the
# add took him there already)
sn=$(grep -aoP "kit editor: Added the scene \K\S+" "$CL" | tail -1)
cmd "event kit_edit {\"op\": \"scene\", \"name\": \"$sn\"}"
for i in $(seq 50); do
	tail -c +$((o + 1)) "$t/boss.packets" | grep -qa zqximport4419 && break
	sleep 0.2
done
tail -c +$((o + 1)) "$t/boss.packets" | grep -qa zqximport4419 ||
	fail "the scene added from its export: no comments in its state ($t/boss.packets)"
echo "ok: a scene exported with a commented entity, removed, added again: the comments in both"
step 20 "kit editor: in the scene world " 'event kit_edit {"op": "scene", "name": "world"}'

# kitbob out, kitboss out, the server saved and gone
printf 'sync 2000\nquit\n' >&4
exec 4>&-
wait $BOB
cmd "sync 2000" "quit"
exec 3>&-
wait $CLIENT
CLIENT=
kill -INT $SRV 2>/dev/null
wait $SRV 2>/dev/null
n=$(grep -ac "^kit:edit_state [0-9]" "$t/bob.packets")
[ "$n" -ge 1 ] || fail "kitbob's client got no state ($t/bob.packets)"
grep -aq zqxnote7731 "$t/boss.packets" ||
	fail "kitboss's packets have no comments: the dump sees nothing ($t/boss.packets)"
! grep -aq "zqxnote7731\|zqximport4419" "$t/bob.packets" ||
	fail "kitbob, a player, was sent the comments: $(grep -ao "^[a-z_]*:[a-z_]* [0-9]*" "$t/bob.packets" | sort | uniq -c | sort -rn | head -3) ($t/bob.packets)"
echo "ok: kitbob's client got $n states and $(grep -ac "^[a-z_]*:[a-z_]* [0-9]" "$t/bob.packets") packets, none with the comments; kitboss's had them"

# 4. From the save
server "$t/srv2.log"
NTFY=
boss boss2 BUILDAT_JOIN_CREATE=0
step 10 "kit editor: comments of $T: ${#NOTE} bytes, the button cyan, the field hidden" \
	"frames 3" "event kit_select $T"
where restart
RR=$R
cmd "frames 5" "screenshot $t/restart.png" "sync 2000" "quit"
exec 3>&-
wait $CLIENT
CLIENT=
kill -INT $SRV 2>/dev/null
wait $SRV 2>/dev/null
echo "ok: the comments kept in the save"

# The button's colour in the screenshots
for s in "plain.png $RP 0" "cyan.png $RC 1" "hidden.png $RC 1" "restart.png $RR 1"; do
	set -- $s
	[ -f "$t/$1" ] || fail "no $t/$1"
	c=$(cyan "$t/$1" $2 $3 $4 $5) || fail "the PNG $t/$1"
	echo "  $1: $c cyan pixels in the button at $2 $3 $4 $5"
	if [ "$6" = 1 ]; then
		[ "$c" -ge 15 ] || fail "the Comments button not cyan in $t/$1"
	else
		[ "$c" -le 2 ] || fail "the Comments button cyan in $t/$1 (none set)"
	fi
done
echo "ok: the button plain with none, cyan with some, in the screenshots"

# 5. The web client as a phone (headless Chrome; skipped without web/ or
# Chrome): the field entry mode's
if command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	cat > "$t/phone.json" <<'J'
[
	["nav", "${URL}?pref=kit_editor_font=100&pref=kit_ui_mode=2"],
	["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
	["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as webboss", 30],
	["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
	["tap", "Button", "Don't add"], ["frames", 3],
	["waitlog_any", "world_menu: the list shown, 0 worlds", 30], ["frames", 3],
	["tap", "Button", "New game..."],
	["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
	["tap", "Button", "Create"],
	["waitlog", "player physics enabled", 120],
	["waitlog_any", "kit editor: edit rights: yes", 10], ["frames", 5],
	["key", "F6"], ["waitlog", "kit editor: touch shell on", 20],
	["waitlog", "kit editor: touch shell: pixels", 10], ["frames", 10],
	["event", "kit_select 3"], ["waitlog", "kit editor: selected 3", 10],
	["waitlog_any", "kit editor: touch shell: the inspector pane", 10], ["frames", 10],
	["waitlog_any", "kit editor: comments of 3: 0 bytes, the button plain, the field hidden", 10],
	["event", "kit_inspector_show inspector comments"], ["frames", 5],
	["tap", "Button", "Comments"],
	["waitlog", "kit editor: comments of 3: 0 bytes, the button plain, the field shown", 10],
	["frames", 5], ["event", "kit_inspector_show comments"], ["frames", 5],
	["tap", "LineEdit", "comments"],
	["waitlog", "kit editor: field entry: comments comments \\(long text\\)", 10],
	["waitlog", "kit editor: field entry: laid out", 10], ["frames", 3],
	["waitlog_any", "kit editor: entry field's scroll bar: ", 10],
	["type", "Phone zqxweb5512 note"], ["key", "Enter"], ["type", "line two"], ["frames", 5],
	["shot", "${OUT}/entry.png"],
	["tap", "Button", "entry apply"],
	["waitlog", "kit editor: comments of 3 saved, 30 bytes", 10],
	["waitlog_any", "kit editor: field entry: closed, applied", 10],
	["waitlog_any", "kit editor: comments of 3: 30 bytes, the button cyan, the field shown", 10],
	["frames", 5], ["event", "kit_inspector_show inspector comments"], ["frames", 5],
	["event", "kit_ui_where cyan"], ["waitlog", "kit editor: the inspector comments at", 10],
	["frames", 3], ["shot", "${OUT}/cyan.png"]
]
J
	env -u BUILDAT_WORKBENCH_PROJECT TOUCH=1 WEB_DRIVE_VIEWPORT=412x915@1 \
		"$here/util/web_drive.sh" chrome workbench "$t/phone.json" "$t/web" > "$t/web.txt" 2>&1 ||
		fail "the web client as a phone: $(tail -2 "$t/web.txt") ($t/web/page.log)"
	grep -aq "An edit by webboss: set 3's comments (30 bytes)" "$t/web/server.log" ||
		fail "the phone's comments not set ($t/web/server.log)"
	r=$(grep -aoP "kit editor: the inspector comments at \K[0-9]+ [0-9]+ [0-9]+ [0-9]+" "$t/web/page.log" | tail -1)
	c=$(cyan "$t/web/cyan.png" $r) || fail "the PNG $t/web/cyan.png"
	echo "  web/cyan.png: $c cyan pixels in the button at $r"
	[ "$c" -ge 15 ] || fail "the phone's Comments button not cyan ($t/web/cyan.png)"
	echo "ok: the web client as a phone: typed in the field entry mode, applied, the button cyan"
else
	echo "(no web part: no web/buildat.wasm or Chrome)"
fi
echo "PASS: an entity's comments: the inspector's button plain or cyan, its field shown and hidden, typed and saved, undone; never sent to a player; in a scene's export and back; in the save; on the web as a phone. Screenshots in $t"
