#!/bin/bash
# tier: quick
# cost: ~150 s (2026-10-29)
# covers: 3rdparty/Urho3D/Source/Urho3D/UI/LineEdit.cpp src/client/web/index.html client/core/uistack/init.lua util/web_drive.js apps/hearth/main/client_lua/init.lua
# [TEXT_KEYS], the text field's keys and clicks, by the ui scan's text,
# cursor and selection after each step:
#   1. Single-line, launch_menu's "Join a Buildat server" Address: Ctrl+A
#      selects all; typing replaces it; Ctrl+Left by word, Shift+Ctrl+Right
#      selects a word (foo_bar is one, wörld is one); Alt+Backspace and
#      Ctrl+Backspace delete back a word, Ctrl+Delete forward; a double-click
#      selects the word, a third click everything.
#   2. Multi-line, Hearth's reply field: Ctrl+A there is the field's (the
#      text selected, nothing sent); a triple-click selects the line; Home and
#      Alt+Backspace at a line's start join it to the one above, past its
#      trailing spaces.
#   [HEARTH_PAGE_KEYS]: in 2, 120 lines; Page Down twice, Page Up, Shift+
#      Page Down move by the rows the page shows of the field less two;
#      Up and Down keep their column past a short and an empty line until
#      another key, and a wrapped paragraph moves by its rows; native and
#      in Chrome.
#   [TEXT_UNDO]: in 1, "alpha beta" typed over the selection and "beta"
#      pasted over "alpha"; Ctrl+Z twice, Ctrl+Y, Ctrl+Shift+Z, the text,
#      cursor and selection each time. In 2, Ctrl+Z undoes the join.
#   3. The web page's word rule (its wordLeft run by node), and in Firefox
#      (util/text_keys_web.json) Alt+Backspace, Ctrl+Z and Ctrl+Shift+Z in
#      the floorplanner's login name field.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   util/text_keys_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp text_keys; t=$CHECK_TMP
cd "$here/Build"

# The field at x,y in scan $2 of log $1: its text, cursor and selection
field(){ # log label x,y
	grep -a "scan $2: " "$1" | grep -a -A1 "ui  *LineEdit at $3 " | grep -av "^--" |
		sed 's/.* size [0-9x]* //' | tr '\n' ' ' | sed 's/ *$//'
}
want(){ # log label x,y expected
	local got
	got=$(field "$1" "$2" "$3")
	[ "$got" = "$4" ] || fail "$2: '$got', not '$4'"
}
ctrl(){ echo "keydown ctrl\nkeypress $1\nkeyup ctrl\ndelay 200\n"; }

# 1. Single-line. The 200-300 ms delays are settles: the field drawn after
# a key, a click or the screen's line; the 1 s before the triple click
# keeps it from being read as the double click's third
s='wait_log_any 20000 rows in\ndelay 300\ntext join a buildat\nwait_log 5000 rows for "join a buildat"\nkeypress Return\nwait_log 5000 Join a Buildat server: shown\ndelay 300\n'
s+="$(ctrl A)event scan s1\ntext hello wörld foo_bar, baz\ndelay 200\n$(ctrl Left)event scan s2\n"
s+="$(ctrl Left)keydown shift\n$(ctrl Right)keyup shift\nevent scan s3\n"
s+='keypress End\nkeydown alt\nkeypress Backspace\nkeyup alt\ndelay 200\nevent scan s4\n'
s+="$(ctrl Backspace)event scan s5\nkeypress Home\n$(ctrl Delete)event scan s6\n"
s+='mouse_pos 772 285\ndelay 300\nmouse_click left\nmouse_click left\ndelay 200\nevent scan s7\n'
s+="delay 1000\nmouse_click left\nmouse_click left\nmouse_click left\ndelay 200\nevent scan s8\nscreenshot $t/single.png\n"
# [TEXT_UNDO]: typed over the selection, "beta" copied and pasted over
# "alpha", then back and forth
s+="text alpha beta\ndelay 200\nkeypress End\nkeydown shift\n$(ctrl Left)keyup shift\n$(ctrl C)"
s+="keypress Home\nkeydown shift\n$(ctrl Right)keyup shift\n$(ctrl V)event scan u1\n"
s+="$(ctrl Z)event scan u2\n$(ctrl Z)event scan u3\n$(ctrl Y)event scan u4\n"
s+="keydown shift\n$(ctrl Z)keyup shift\nevent scan u5\nquit\n"
printf "$s" > "$t/single.cmds"
# A Starport not asked about yet, never fetched: the "Public servers" line
# is one line high, as the field's x,y above take it (the default one, a
# closed port in a check, is fetched unasked and its error adds a line)
mkdir -p "$t/cl" && echo '{"starports": ["http://127.0.0.1:9"]}' > "$t/cl/starport.json"
timeout 60 bin/buildat -m launch_menu -D "$t/cl" -w 1280x720 -l 3 \
	-o sound_mute=1 -c @"$t/single.cmds" > "$t/single.log" 2>&1
grep -aq "Command sequence complete" "$t/single.log" || fail "the single-line drive"
grep -aq "Lua runtime error" "$t/single.log" && fail "a Lua error in the single-line drive"
L=$t/single.log; A=749,277
want $L s1 $A 'text "localhost" cursor 9 text "localhost" selection 0+9'
want $L s2 $A 'text "hello wörld foo_bar, baz" cursor 21 text "hello wörld foo_bar, baz"'
want $L s3 $A 'text "hello wörld foo_bar, baz" cursor 19 text "hello wörld foo_bar, baz" selection 12+7'
want $L s4 $A 'text "hello wörld foo_bar, " cursor 21 text "hello wörld foo_bar, "'
want $L s5 $A 'text "hello wörld " cursor 12 text "hello wörld "'
want $L s6 $A 'text " wörld " cursor 0 text " wörld "'
want $L s7 $A 'text " wörld " cursor 6 text " wörld " selection 1+5'
want $L s8 $A 'text " wörld " cursor 7 text " wörld " selection 0+7'
echo "ok: single-line: Ctrl+A, by word, the word deletes, the double and triple click"
want $L u1 $A 'text "beta beta" cursor 4 text "beta beta"'
want $L u2 $A 'text "alpha beta" cursor 5 text "alpha beta" selection 0+5'
want $L u3 $A 'text " wörld " cursor 7 text " wörld " selection 0+7'
want $L u4 $A 'text "alpha beta" cursor 5 text "alpha beta" selection 0+5'
want $L u5 $A 'text "beta beta" cursor 4 text "beta beta"'
echo "ok: undo: Ctrl+Z twice back over a paste and a typing, Ctrl+Y and Ctrl+Shift+Z forward"

# 2. Multi-line, Hearth's reply field
# The web client served too, for [HEARTH_PAGE_KEYS] in Chrome below
web=(); [ -f "$here/web/buildat.js" ] && web=(-W "$here/web")
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" "${web[@]}" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
hearth(){ # log requests commands [env...]
	local log=$1 reqs=$2
	printf "$3" > "$t/hearth.cmds"
	shift 3
	env BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" \
		-w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$SERVER_PORT \
		-c @"$t/hearth.cmds" > "$log" 2>&1
}
hearth "$t/setup.log" '{"cmd":"new_topic","name":"Keys"}
{"cmd":"new_thread","topic":1,"title":"Keys","body":"first"}' 'wait_log_any 30000 "id":1002,"ok":\nquit\n'
grep -aq '"id":1001,.*"ok":true' "$t/setup.log" || fail "the thread: $(grep -a 'hr: ' "$t/setup.log" | head -2)"
m='wait_log 20000 accounts: ntfy asked\nwait_log_any 10000 hearth: page Keys\ndelay 500\nkeypress Escape\ndelay 300\nmouse_pos 290 180\nmouse_click left\ndelay 200\ntext one two  x\nkeypress Backspace\nkeypress Return\ntext three four\ndelay 300\nevent scan m1\n'
m+="$(ctrl A)event scan m2\nmouse_pos 290 201\ndelay 300\nmouse_click left\nmouse_click left\nmouse_click left\ndelay 200\nevent scan m3\n"
m+='keypress Home\nkeydown alt\nkeypress Backspace\nkeyup alt\ndelay 200\nevent scan m4\n'
m+="$(ctrl Z)event scan m5\n"
# [HEARTH_PAGE_KEYS]: 120 lines "L001".."L120", five characters each
# with the break, so line n starts at 5(n-1); Page Down and Up from the top
p="$(ctrl A)"
for i in $(seq -w 1 120); do p+="text L$i\n"; [ $i = 120 ] || p+='keypress Return\n'; done
m+="${p}delay 300\n$(ctrl Home)event scan p1\nkeypress PageDown\ndelay 200\nevent scan p2\n"
m+='keypress PageDown\ndelay 200\nevent scan p3\nkeypress PageUp\ndelay 200\nevent scan p4\n'
m+='keydown shift\nkeypress PageDown\nkeyup shift\ndelay 200\nevent scan p5\n'
m+="screenshot $t/pages.png\n"
# The goal column: lines A (24 letters, 0-24), B "ab" (25-27), an empty one
# (28), D as A (29-53) and a paragraph of 60 words wrapping over
# rows (54-293). Down from A's end passes B and the empty line and lands
# at D's end; Up comes back the same; Left ends the run. The paragraph's
# Up moves by its wrapped rows.
P=$(seq -f 'w%02g' -s ' ' 1 60)
m+="$(ctrl A)text abcdefghijklmnopqrstuvwx\nkeypress Return\ntext ab\nkeypress Return\nkeypress Return\n"
m+="text abcdefghijklmnopqrstuvwx\nkeypress Return\ntext $P\ndelay 300\n$(ctrl Home)keypress End\ndelay 200\nevent scan g0\n"
for g in 1:Down 2:Down 3:Down 4:Up 5:Up 6:Up 7:Down 8:Left 9:Down 10:Down; do
	m+="keypress ${g#*:}\ndelay 200\nevent scan g${g%:*}\n"
done
m+="$(ctrl End)event scan g11\nkeypress Up\ndelay 200\nevent scan g12\nkeypress Up\ndelay 200\nevent scan g13\n"
m+="screenshot $t/goal.png\nquit\n"
hearth "$t/multi.log" "" "$m" BUILDAT_HEARTH_OPEN=1
grep -aq "Lua runtime error" "$t/multi.log" && fail "a Lua error in the multi-line drive"
# The text's line break is a line break in the log too
focus(){ grep -a -A1 "scan $1: focus" "$t/multi.log" | grep -av "^--" | tr '\n' '|' | sed 's/.* size [0-9x]* //; s/|loka.*//; s/|$//'; }
wantm(){ [ "$(focus $1)" = "$2" ] || fail "$1: '$(focus $1)', not '$2'"; }
wantm m1 'text "one two  |three four" cursor 20 selection 0+0'
wantm m2 'text "one two  |three four" cursor 20 selection 0+20'
wantm m3 'text "one two  |three four" cursor 20 selection 10+10'
wantm m4 'text "one twothree four" cursor 7 selection 0+0'
wantm m5 'text "one two  |three four" cursor 10 selection 0+0'
curl -s "http://127.0.0.1:$SERVER_PORT/t/1" | grep -q "three" && fail "Ctrl+A in the reply field sent it"
echo "ok: multi-line: Ctrl+A the field's, the triple-click a line, Alt+Backspace at a line's start joins it, Ctrl+Z parts them"
# [HEARTH_PAGE_KEYS]: the page shows 27 of the field's rows at 800x600
# (pages.png), so a page is 25: line 26, 51, back to 26, and selected to 51
# The scan's text is 120 lines: its cursor and selection are on the last
wantp(){
	local got
	got=$(awk -v l="scan $1: focus" 'index($0, l) { on = 1 } on && /" cursor / { sub(/.*" cursor/, "cursor"); print; exit }' "$t/multi.log")
	[ "$got" = "$2" ] || fail "$1: '$got', not '$2'"
}
wantp p1 'cursor 0 selection 0+0'
wantp p2 'cursor 125 selection 0+0'
wantp p3 'cursor 250 selection 0+0'
wantp p4 'cursor 125 selection 0+0'
wantp p5 'cursor 250 selection 125+125'
echo "ok: multi-line: Page Down and Up by the rows the page shows less two, Shift+Page Down selects"
# The paragraph's five rows at 800x600 (goal.png): Up from its end goes
# after "w46" and then to "w33"
for g in 0:24 1:27 2:28 3:53 4:28 5:27 6:24 7:27 8:26 9:28 10:30 11:293 12:237 13:182; do
	wantp g${g%:*} "cursor ${g#*:} selection 0+0"
done
echo "ok: multi-line: Up and Down keep the column past a short and an empty line, Left ends it, a paragraph by its wrapped rows"
# And in Chrome at 800x600, its larger text 15 rows shown: a page is 13.
# The stand-in's selection is the field's, synced each frame
if [ ${#web[@]} -gt 0 ] && command -v google-chrome > /dev/null; then
	ev(){ echo "[\"wait\", 300], [\"eval\", \"'$1 ' + document.getElementById('text').selectionStart + ' ' + document.getElementById('text').selectionEnd\"],"; }
	{
		echo '[["viewport", 800, 600], ["nav", "${URL}app#open=/t/1"],'
		echo '["waitlog", "accounts: the login page shown", 120], ["wait", 500],'
		echo '["type", "admin"], ["key", "Tab"], ["type", "checkpass12"], ["key", "Enter"],'
		echo '["waitlog", "accounts: ntfy asked", 30], ["waitlog", "hearth: page Keys", 30],'
		echo '["wait", 500], ["key", "Escape"], ["wait", 500], ["click", 490, 360], ["wait", 300], ["selall"],'
		for i in $(seq -w 1 120); do echo "[\"type\", \"L$i\"],"; [ $i = 120 ] || echo '["key", "Enter"],'; done
		echo '["wait", 500], ["chord", "Ctrl+Home"],'; ev p1
		echo '["key", "PageDown"],'; ev p2
		echo '["key", "PageDown"],'; ev p3
		echo '["key", "PageUp"],'; ev p4
		echo '["chord", "Shift+PageDown"],'; ev p5
		echo '["shot", "${OUT}/pages.png"], ["selall"],'
		# The goal column's lines and paragraph, as natively; the paragraph
		# five rows of 12 or 13 words (goal.png): after "w48", "w36"
		echo '["type", "abcdefghijklmnopqrstuvwx"], ["key", "Enter"], ["type", "ab"], ["key", "Enter"], ["key", "Enter"],'
		echo "[\"type\", \"abcdefghijklmnopqrstuvwx\"], [\"key\", \"Enter\"], [\"type\", \"$P\"],"
		echo '["wait", 500], ["chord", "Ctrl+Home"], ["key", "End"],'; ev g0
		for g in 1:Down 2:Down 3:Down 4:Up 5:Up 6:Up 7:Down 8:Left 9:Down 10:Down; do
			echo "[\"key\", \"${g#*:}\"],"; ev g${g%:*}
		done
		echo '["chord", "Ctrl+End"],'; ev g11
		echo '["key", "Up"],'; ev g12
		echo '["key", "Up"],'; ev g13
		echo '["shot", "${OUT}/goal.png"]]'
	} > "$t/pages.json"
	WEB_DRIVE_URL=http://127.0.0.1:$SERVER_PORT/ "$here/util/web_drive.sh" chrome hearth \
		"$t/pages.json" "$t/web_pages" > "$t/web_pages.out" 2>&1 ||
		fail "the Chrome page keys drive: $(tail -3 "$t/web_pages.out")"
	got=$(grep -a '^eval: "p' "$t/web_pages.out" | tr '\n' '|')
	[ "$got" = 'eval: "p1 0 0"|eval: "p2 65 65"|eval: "p3 130 130"|eval: "p4 65 65"|eval: "p5 65 130"|' ] ||
		fail "Page Up and Down in Chrome: $got"
	echo "ok: the web client in Chrome: Page Down and Up by the rows shown less two, Shift+Page Down selects"
	got=$(grep -a '^eval: "g' "$t/web_pages.out" | sed 's/^eval: "\(g[0-9]*\) \([0-9]*\) \2"$/\1:\2/' | tr '\n' ' ')
	[ "$got" = 'g0:24 g1:27 g2:28 g3:53 g4:28 g5:27 g6:24 g7:27 g8:26 g9:28 g10:30 g11:293 g12:245 g13:197 ' ] ||
		fail "the goal column in Chrome: $got"
	echo "ok: the web client in Chrome: Up and Down keep the column, Left ends it, a paragraph by its wrapped rows"
else
	echo "skip: no web/ or no google-chrome for the page keys"
fi

# 3. The web page's word rule, its own function run by node
if command -v node > /dev/null; then
	sed -n '/^\tfunction wordLeft(v, a){$/,/^\t}$/p' "$here/src/client/web/index.html" > "$t/wl.js"
	[ -s "$t/wl.js" ] || fail "no wordLeft in index.html"
	cat >> "$t/wl.js" <<'JS'
const eq = (v, a, want) => { const got = wordLeft(v, a); if(got !== want) { console.log(`FAIL: web wordLeft(${JSON.stringify(v)}, ${a}) = ${got}, not ${want}`); process.exit(1); } };
const s = "hello wörld foo_bar, ";
eq(s, s.length, 12);
eq(s, 12, 6);
eq("one two  \nthree", 10, 7);
eq("", 0, 0);
JS
	node "$t/wl.js" || exit 1
	echo "ok: the web page's Alt+Backspace word rule"
else
	echo "skip: no node for the web page's word rule"
fi
# The web client's name field in Firefox and Chrome (web/ from
# util/build_web.sh): Chrome's chords are web_drive's own key events, the
# modifiers pressed as keys of their own
for br in firefox google-chrome; do
	if [ -f "$here/web/buildat.js" ] && command -v $br > /dev/null; then
		"$here/util/web_drive.sh" ${br#google-} floorplanner "$here/util/text_keys_web.json" \
			"$t/web_$br" > "$t/web_$br.out" 2>&1 || fail "the $br drive: $(tail -3 "$t/web_$br.out")"
		got=$(grep -a "^eval: " "$t/web_$br.out" | tr '\n' '|')
		[ "$got" = 'eval: "typed alpha beta"|eval: "word alpha "|eval: "undone alpha beta"|eval: "redone alpha "|' ] ||
			fail "the web field in $br: $got"
		echo "ok: the web client in $br: Alt+Backspace, Ctrl+Z and Ctrl+Shift+Z in a field"
	else
		echo "skip: no web/ or no $br for the web field"
	fi
done
echo "PASS: undo and redo; Ctrl+A, the word moves and deletes and the clicks, single- and multi-line; Page Up and Down and the column Up and Down keep; the web client's Alt+Backspace and undo (see $t/*.png)"
