#!/bin/bash
# tier: full
# cost: ~2.5 min (2026-10-30)
# covers: extensions/ui_utils/init.lua extensions/launch_console/init.lua extensions/luanti_client/init.lua extensions/luanti_client/res/chat_line.lua extensions/luanti_client/res/form_session.lua extensions/luanti_client/res/formspec_ui.lua apps/hearth/main/client_lua/init.lua
# [SCROLL_PAGE_KEYS]: Page Up and Down scroll what is read by the rows
# shown less two (ui_utils' page_step: one at four rows or fewer):
#   1. Hearth's admin: the Server window's Health page (a long dialog),
#      Page Down twice and Page Up; then a thread whose first message is
#      taller than the view, Page Up from its end to its top: each press
#      moves the view by the step, and the focus stays on the long
#      message while it is in sight, not jumped over to the one above.
#      Before both, the Server window the admin's login question opened
#      before Hearth's frame: Down, Up and Page Down are that window's,
#      not the frame's under it ([KEYPAGE_NEWEST_WRONG]).
#   2. The launch console's API text: Page Down twice, Page Up.
#   3. luanti_client on official Luanti's devtest: 30 chat lines, the
#      chat line open, Page Up twice and Page Down page back over them 6
#      lines (8 shown) at a time; a form's scroll_container paged and the
#      bar's value sent (skipped without luanti or devtest).
#   4. 1's thread in Chrome (web/ from util/build_web.sh).
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   util/scroll_page_keys_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp scroll_page_keys; t=$CHECK_TMP
lsrv=
trap '[ -n "$lsrv" ] && kill $lsrv 2>/dev/null; check_cleanup' EXIT
cd "$here/Build"

# steps <log> <step> <what>: the "page key:" lines' moves, each the step
# or what was left to the end
steps(){
	python3 - "$@" <<'PY'
import re, sys
log, want, what = sys.argv[1], int(sys.argv[2]), sys.argv[3]
moves = [tuple(map(int, m.groups())) for m in re.finditer(
		r"page key: (-?\d+) -> (-?\d+) of (\d+), view (\d+)",
		open(log, errors="replace").read())]
if not moves:
	sys.exit("%s: no page key lines" % what)
for a, b, total, h in moves:
	step = abs(b - a)
	if step != want and not (b == 0 or b == total - h):
		sys.exit("%s: %d -> %d, not by %d (view %d)" % (what, a, b, want, h))
print(" ".join("%d->%d" % (a, b) for a, b, _, _ in moves))
PY
}
# The step for a view h px high in 20 px lines, as page_step has it
step20(){ local r=$(($1 / 20)); echo $(( (r > 4 ? r - 2 : r - 1) * 20 )); }

# 1. Hearth: the Health page and a long thread
web=(); [ -f "$here/web/buildat.js" ] && web=(-W "$here/web")
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" "${web[@]}" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
mkdir -p "$t/cl" && echo '{"starports": ["http://127.0.0.1:9"]}' > "$t/cl/starport.json"
hearth(){ # log requests commands [env...]
	local log=$1 reqs=$2
	printf "$3" > "$t/hearth.cmds"
	shift 3
	run_client 60 "$log" env BUILDAT_HEARTH_NAME=admin \
		BUILDAT_HEARTH_PASSWORD=checkpass12 BUILDAT_HEARTH_CREATE=1 \
		BUILDAT_HEARTH_CODE=$code BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -o launch_ui=launch_menu \
		-D "$t/cl" -w 800x600 -l 4 -o sound_mute=1 \
		-s 127.0.0.1:$SERVER_PORT -c @"$t/hearth.cmds"
}
# The first message 60 paragraphs long, then three short replies
body=$(for i in $(seq -w 1 60); do printf 'Line %s of the long one\\n\\n' $i; done)
hearth "$t/setup.log" '{"cmd":"new_topic","name":"Keys"}
{"cmd":"new_thread","topic":1,"title":"Long","body":"'"$body"'end"}
{"cmd":"reply","thread":1,"body":"short one"}
{"cmd":"reply","thread":1,"body":"short two"}
{"cmd":"reply","thread":1,"body":"short three"}' 'wait_log_any 30000 "id":1005,"ok":\nquit\n'
grep -aq '"id":1005,.*"ok":true' "$t/setup.log" ||
	fail "the thread: $(grep -a '"ok":false' "$t/setup.log" | head -2)"
# The setup code's admin is asked for a ntfy topic first, the Server
# window over Hearth's frame built after it: Down, Up and Page Down are
# the window's ([KEYPAGE_NEWEST_WRONG]). That window closed, the thread
# from its last message up; then the Server window over Hearth by its
# Server button, its Health page
m='wait_log 20000 accounts: ntfy asked\nwait_log_any 5000 server window: the page ntfy\n'
m+='wait_log_any 10000 hearth: page Long\ndelay 500\n'
for k in Down Down Up Right PageDown; do m+="keypress $k\ndelay 200\n"; done
m+="screenshot $t/ntfy.png\n"
m+='keypress Escape\nwait_log 5000 server window: closed\n'
m+='wait_log_any 10000 hearth: page Long\ndelay 1000\nclick Text "short three"\ndelay 300\n'
for i in 1 2 3 4 5 6 7; do m+="keypress PageUp\ndelay 300\nscreenshot $t/thread$i.png\n"; done
m+='keypress PageDown\ndelay 300\nclick Button "Server"\nwait_log 5000 server window: the page account\n'
m+='click Button "Health"\nwait_log 5000 server window: the page health\ndelay 1000\n'
m+='click Button "Refresh"\ndelay 300\nkeypress PageDown\ndelay 300\n'
m+="screenshot $t/health1.png\nkeypress PageDown\ndelay 300\nscreenshot $t/health2.png\n"
m+='keypress PageUp\ndelay 300\nquit\n'
hearth "$t/hearth.log" "" "$m" BUILDAT_HEARTH_OPEN=1 ||
	fail "the Hearth drive ($t/hearth.log): $(grep -a "Command sequence failed\|run_client:" "$t/hearth.log" | tail -1)"
grep -aq "Lua runtime error" "$t/hearth.log" && fail "a Lua error in the Hearth drive ($t/hearth.log)"
sed -n '/the page health/,$p' "$t/hearth.log" > "$t/health.log"
# The early Server window's keys: the first Down to its sidebar, then
# Down and Up between its entries (Hearth's are Home, Search...); Right to
# its page, Page Down that page's view
sed -n "/I hearth .*: hearth: page Long/,/I accounts: server window: closed/p" "$t/hearth.log" > "$t/early.log"
python3 - "$t/early.log" <<'PY' || fail "the early Server window's keys ($t/early.log)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
to = re.findall(r"keyboard: to (.*)", log)
pk = re.findall(r"page key: .*", log)
print("  early Server window: " + " | ".join(to) + "; " + "; ".join(pk))
sw = {"Account", "> Pushes (ntfy)", "Accounts", "Starports", "Listing",
		"ID logins", "Statistics", "Health", "Add now", "Later", "Don't add"}
assert len(to) == 2 and to[0] != to[1] and set(to) <= sw, "Down and Up: %s" % to
assert len(pk) == 1, "Page Down: %s" % pk
PY
sed -n '/server window: closed/,/the page account/p' "$t/hearth.log" > "$t/thread.log"
hv=$(grep -aom1 "page key: .*, view [0-9]*" "$t/health.log" | sed 's/.*view //')
[ -n "$hv" ] || fail "no page key in the Health page ($t/hearth.log)"
got=$(steps "$t/health.log" $(step20 $hv) "the Health page") || fail "$got"
[ "$(grep -ac "page key:" "$t/health.log")" = 3 ] || fail "the Health page: not three moves: $got"
echo "ok: the Server window's Health page, view $hv: $got"
tv=$(grep -aom1 "page key: .*, view [0-9]*" "$t/thread.log" | sed 's/.*view //')
[ -n "$tv" ] || fail "no page key in the thread ($t/hearth.log)"
got=$(steps "$t/thread.log" $(step20 $tv) "the thread") || fail "$got"
echo "ok: Hearth's thread, view $tv: $got"
# The long message (m1) focused from the press that reached it to the top
python3 - "$t/thread.log" <<'PY' || fail "the thread's focus"
import re, sys
f = re.findall(r"page key: (\d+) -> (\d+) of \d+, view \d+, focus (\S+)",
		open(sys.argv[1], errors="replace").read())
ups = [x for x in f]
print("  focus: " + " ".join("%s@%s" % (x[2], x[1]) for x in ups))
i = next((k for k, x in enumerate(ups) if x[2] == "m1"), None)
assert i is not None, "the long message never focused"
up = [x for x in ups[i:] if int(x[1]) < int(x[0])]
assert len(up) >= 3 and all(x[2] == "m1" for x in up), \
	"the focus left the long message going up"
assert up[-1][1] == "0", "Page Up did not reach the top"
PY
echo "ok: the long message kept the focus over $(grep -ac 'focus m1' "$t/thread.log") presses"

# 2. The launch console's API text, from its input field
printf 'wait_log_any 20000 lines of the API document\ndelay 300\nkeypress PageDown\ndelay 200\nkeypress PageDown\ndelay 200\nscreenshot %s/console.png\nkeypress PageUp\ndelay 200\nquit\n' "$t" > "$t/console.cmds"
run_client 60 "$t/console.log" timeout 60 bin/buildat -m launch_console -D "$t/cl" \
	-w 800x600 -l 3 -o sound_mute=1 -c @"$t/console.cmds" ||
	fail "the console drive ($t/console.log)"
got=$(grep -ao "console: page .* shown" "$t/console.log" | sed 's/console: page //' | tr '\n' '|')
n=$(grep -aom1 "at the top, [0-9]* shown" "$t/console.log" | grep -o "[0-9]* shown" | cut -d' ' -f1)
[ -n "$n" ] && [ "$n" -gt 4 ] || fail "the console: $got"
p=$((n - 2))
[ "$got" = "1, line $((p + 1)) at the top, $n shown|1, line $((2 * p + 1)) at the top, $n shown|-1, line $((p + 1)) at the top, $n shown|" ] ||
	fail "the console's API text: $got"
echo "ok: the launch console's API text, $n lines shown, by $p: $got"

# 3. luanti_client: the chat's lines and a form's scroll_container
G="$BUILDAT_USER_PATH/shared/vanilla/games/devtest"
if ! command -v luanti > /dev/null || [ ! -d "$G" ]; then
	echo "skip: luanti_client: no luanti or devtest"
else
	mkdir -p "$t/games" "$t/w/worldmods/spk"
	cp -r "$G" "$t/games/"
	cat > "$t/w/worldmods/spk/init.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.after(1, function()
		for i = 1, 30 do
			core.chat_send_player(name, string.format("spk line %02d", i))
		end
	end)
end)
-- Thirty rows 0.6 apart in a container 3 high: 15 units, 150 of the bar's
core.register_chatcommand("spkform", {func = function(name)
	local rows = {}
	for i = 1, 30 do
		rows[#rows + 1] = string.format("label[0.2,%.1f;row %d]", 0.3 + (i - 1) * 0.6, i)
	end
	core.show_formspec(name, "spk", "size[6,4]" ..
		"scroll_container[0.3,0.3;5,3;bar;vertical;0.1]" .. table.concat(rows) ..
		"scroll_container_end[]scrollbaroptions[max=150]" ..
		"scrollbar[5.4,0.3;0.3,3;vertical;bar;0]" ..
		"button_exit[0.5,3.5;5,0.4;done;Done]")
	return true
end})
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname == "spk" and fields.bar then
		core.log("action", "spk: bar=" .. fields.bar)
	end
end)
L
	echo "name = spk" > "$t/w/worldmods/spk/mod.conf"
	printf 'gameid = devtest\nbackend = sqlite3\n' > "$t/w/world.mt"
	P=$((30200 + RANDOM % 300))
	LUANTI_GAME_PATH="$t/games" MINETEST_GAME_PATH="$t/games" \
		luanti --server --world "$t/w" --port $P > "$t/l.log" 2>&1 &
	lsrv=$!
	for _ in $(seq 150); do
		grep -q "listening on" "$t/l.log" && break
		kill -0 $lsrv 2>/dev/null || fail "luanti died ($(tail -3 "$t/l.log"))"
		sleep 0.2
	done
	grep -q "listening on" "$t/l.log" || fail "luanti did not come up ($t/l.log)"
	mkdir -p "$t/lcl"
	now=$(date +%s)
	echo "\"true\",\"udp://127.0.0.1:$P\",\"\",\"$now\",\"$now\",\"\",\"\",\"\"" \
		> "$t/lcl/network_addresses.csv"
	{
		echo "wait_log_any 60000 chat: spk line 30"; echo "delay 300"
		echo "keypress T"; echo "wait_log 5000 chat: the line opened"; echo "delay 200"
		echo "keypress PageUp"; echo "delay 200"; echo "keypress PageUp"; echo "delay 200"
		echo "screenshot $t/chat_back.png"
		echo "keypress PageDown"; echo "delay 200"; echo "screenshot $t/chat_down.png"
		echo "keypress Escape"; echo "delay 300"
		echo "keypress T"; echo "wait_log 5000 chat: the line opened"; echo "delay 200"
		echo "text /spkform"; echo "keypress Return"; echo "wait_log 10000 form spk opened"
		echo "delay 500"; echo "mouse_pos 10 10"; echo "delay 200"
		echo "keypress PageDown"; echo "delay 300"; echo "keypress PageDown"; echo "delay 300"
		echo "screenshot $t/form.png"
		echo "keypress PageUp"; echo "delay 500"; echo "quit"
	} > "$t/lc.cmds"
	(cd "$here/Build" && BUILDAT_LUANTI_ADDRESS=127.0.0.1:$P BUILDAT_LUANTI_CONNECT=1 \
		BUILDAT_LUANTI_NAME=spkcheck timeout 120 bin/buildat -m luanti_client \
		-D "$t/lcl" -w 800x600 -l 3 -o sound_mute=1 -c @"$t/lc.cmds" > "$t/lc.log" 2>&1) ||
		fail "luanti_client's drive ($t/lc.log): $(grep -a "Command sequence failed" "$t/lc.log" | tail -1)"
	# The newest line shown 6 back, 12, 6: a line that came meanwhile is
	# added under the ones read
	got=$(grep -ao "chat: page .* of [0-9]*" "$t/lc.log" | sed 's/chat: page //' | tr '\n' '|')
	l=($(grep -ao "chat: page .* of [0-9]*" "$t/lc.log" | awk '{ print $7, $9 }'))
	[ ${#l[@]} = 6 ] && [ ${l[0]} = $((l[1] - 6)) ] && [ ${l[2]} = $((l[0] - 6)) ] &&
		[ ${l[4]} = $((l[2] + 6)) ] || fail "luanti_client's chat, 8 lines shown: $got ($t/lc.log)"
	echo "ok: luanti_client's chat, 8 lines shown, pages by 6: $got"
	python3 - "$t/lc.log" "$t/l.log" <<'PY' || fail "luanti_client's form ($t/lc.log)"
import math, re, sys
f = re.findall(r"form: page (-?\d+), bar (\d+) -> (\d+) \(view (\d+) px, ([\d.]+) px a unit\)",
		open(sys.argv[1], errors="replace").read())
assert len(f) == 3, "%d form page lines" % len(f)
for d, a, b, h, per in f:
	rows = int(h) // 16
	px = (rows - (2 if rows > 4 else 1)) * 16
	# The logged view and unit are rounded: a unit either way
	want = max(0, min(150, int(a) + int(d) * int(px / float(per))))
	assert abs(int(b) - want) <= 1, "%s -> %s, not %d" % (a, b, want)
sent = re.findall(r"spk: bar=(\S+)", open(sys.argv[2], errors="replace").read())
assert sent and sent[-1] == "CHG:" + f[-1][2], "the server got %s" % sent
print("ok: luanti_client's form: " + " ".join("%s->%s" % (a, b) for _, a, b, _, _ in f) +
		", view %s px; the server got %s" % (f[0][3], ", ".join(sent)))
PY
fi

# 4. 1's thread in Chrome, from its top down: Right to the page's first
# item (Back), then Page Down through the long message
if [ ${#web[@]} -gt 0 ] && command -v google-chrome > /dev/null; then
	{
		echo '[["viewport", 800, 600], ["nav", "${URL}app#open=/t/1"],'
		echo '["waitlog", "accounts: the login page shown", 120], ["wait", 500],'
		echo '["type", "admin"], ["key", "Tab"], ["type", "checkpass12"], ["key", "Enter"],'
		echo '["waitlog_any", "accounts: ntfy asked", 30], ["waitlog_any", "hearth: page Long", 30],'
		echo '["waitlog_any", "server window: the page ntfy", 30], ["wait", 500],'
		echo '["key", "Escape"], ["waitlog", "server window: closed", 10], ["wait", 500],'
		echo '["key", "Right"], ["wait", 500],'
		for i in 1 2 3 4; do echo "[\"key\", \"PageDown\"], [\"wait\", 400], [\"shot\", \"\${OUT}/web$i.png\"],"; done
		echo '["wait", 100]]'
	} > "$t/web.json"
	WEB_DRIVE_URL=http://127.0.0.1:$SERVER_PORT/ "$here/util/web_drive.sh" chrome hearth \
		"$t/web.json" "$t/web" > "$t/web.out" 2>&1 ||
		fail "the Chrome drive: $(tail -3 "$t/web.out")"
	wv=$(grep -aom1 "page key: .*, view [0-9]*" "$t/web/page.log" | sed 's/.*view //')
	[ -n "$wv" ] || fail "no page key in Chrome ($t/web/page.log)"
	got=$(steps "$t/web/page.log" $(step20 $wv) "Chrome's thread") || fail "$got"
	python3 - "$t/web/page.log" <<'PY' || fail "the thread's focus in Chrome ($t/web/page.log)"
import re, sys
f = re.findall(r"page key: (\d+) -> (\d+) of \d+, view \d+, focus (\S+)",
		open(sys.argv[1], errors="replace").read())
print("  focus: " + " ".join("%s@%s" % (x[2], x[1]) for x in f))
assert len(f) == 4 and all(int(b) > int(a) for a, b, _ in f), "not four moves down"
assert [x[2] for x in f[:3]] == ["m1"] * 3, "the long message not kept"
PY
	echo "ok: Chrome, view $wv: $got"
else
	echo "skip: no web/ or no google-chrome for the web leg"
fi
echo "PASS: Page Up and Down by the rows shown less two in Hearth's thread (native and Chrome), the Server window's Health page, the launch console's API text$( [ -d "$G" ] && echo ", luanti_client's chat and a form's scroll_container") (see $t/*.png)"
