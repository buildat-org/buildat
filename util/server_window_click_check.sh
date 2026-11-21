#!/bin/bash
# tier: full
# cost: ~3 min (2026-11-21)
# covers: apps/vanilla/main/client_lua/pause.lua builtin/accounts/client_lua/accounts.lua apps/hearth/main/client_lua/init.lua
# [SERVER_WINDOW_CLICK]: the Server window opened from vanilla's Settings
# stays open for a click inside it. Vanilla on the minimal game, natively,
# at UI size automatic and 150 %: pause menu, Settings..., scrolled,
# Server...; a click on the sidebar's "Open to LAN" and "Account" and one
# on the page: Settings not shown again; a click far off the window:
# Settings back.
# [UI_SERVER_NARROW]: Hearth's admin (the setup code), the Server window
# its login's ntfy question opens, by the window's own scan lines:
#   - at a phone's size (390x844, UI scale 1): the window fills the
#     screen; its fixed header row has "< Server", the title and the ×,
#     nothing else over the ×; "< Server" shows the sidebar (the page
#     hidden; the header "Server" and the ×); Account, then Change
#     password...: "< My account", which goes back to My account; the ×
#     closes the window.
#   - at a desktop's (1100x1000): the header has the page's title and
#     the ×, no "< Server", nothing else over the ×; the × closes it.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#   util/server_window_click_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp server_window_click; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"
mkdir -p "$t/uv/apps/vanilla/saves/sw/luanti"
echo "enable_damage = false" > "$t/uv/apps/vanilla/saves/sw/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=sw start_server "$t/v.log" \
	"STATUS Listening" 120 auto bin/buildat_server -u launcher=1 -A 127.0.0.1 \
	-m ../apps/vanilla -D "$t/uv" -C "$t/cv" -l 3 ||
	fail "the vanilla server did not start ($t/v.log)"
CHECK_PIDS+=($SERVER_PID)
for size in auto 1.5; do
	# A page of the Server window says it is shown; a click on its page
	# must bring no Settings back, the one off it must
	cat > "$t/$size.cmds" <<C
wait_log 180000 load: the world is in
keypress Escape
wait_log 5000 pause: the menu shown
delay 300
click Button "Settings..."
wait_log 5000 Game settings shown
delay 1000
mouse_pos 550 500
$(for _ in $(seq 30); do echo "mouse_wheel -1"; done)
# The frames after the input: the list scrolled before the click looks
delay 500
click Button "Server..."
wait_log 5000 server window: the page
delay 300
click Button "Open to LAN"
wait_log 5000 server window: the page
delay 300
click Button "Account"
wait_log 5000 server window: the page
delay 300
mouse_pos 650 650
mouse_click left
wait_log_absent 1000 Game settings shown
screenshot $t/${size}_inside.png
mouse_pos 15 500
mouse_click left
wait_log 5000 Game settings shown
delay 500
screenshot $t/${size}_off.png
quit
C
	timeout 240 bin/buildat -o launch_ui=launch_menu -w 1100x1000 -u 1 -l 3 \
		-o sound_mute=1 -o ui_size=$size -C "$t/c$size" -D "$t/u$size" \
		-s 127.0.0.1:"$SERVER_PORT" -c @"$t/$size.cmds" > "$t/$size.log" 2>&1
	grep -a "Command sequence failed" "$t/$size.log" && fail "the drive at $size ($t/$size.log)"
	python3 - "$t/$size.log" <<'PY' || fail "UI size $size ($t/$size.log)"
import sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
shown = [i for i, l in enumerate(lines) if "Game settings shown: " in l]
off = [i for i, l in enumerate(lines) if "command: mouse_pos 15 500" in l]
assert len(shown) == 2 and off, "%d times Settings shown" % len(shown)
assert shown[1] > off[0], "Settings back before the click off the window"
assert not any("pause: a press off" in l for l in lines), "pause took a press"
PY
	echo "ok: UI size $size"
done
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null

# [UI_SERVER_NARROW] Hearth's admin
start_server "$t/h.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/hearth -D "$t/h" -l 3 ||
	fail "Hearth did not start ($t/h.log)"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -ao "setup code [A-Z0-9]*" "$t/h.log" | cut -d' ' -f3)
hearth(){ # name size [client args...]: the commands in $t/<name>.cmds
	local n=$1 size=$2
	shift 2
	BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
	BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" \
		-w $size "$@" -l 3 -o sound_mute=1 -s 127.0.0.1:$SERVER_PORT \
		-c @"$t/$n.cmds" > "$t/$n.log" 2>&1
	grep -aq "Command sequence complete" "$t/$n.log" ||
		fail "the $n drive ($t/$n.log): $(grep -ao 'Command sequence failed.*' "$t/$n.log" | head -1)"
}
H='server window: the header'
cat > "$t/phone.cmds" <<C
wait_log 60000 accounts: ntfy asked
wait_log_any 5000 $H < Server | Pushes to your phone (ntfy) | ×
delay 300
event scan page
screenshot $t/phone_page.png
click Button "< Server"
wait_log 5000 $H - | Server | ×
delay 300
event scan sidebar
screenshot $t/phone_sidebar.png
click Button "Account"
wait_log 5000 $H < Server | My account | ×
delay 300
click Button "Change password..."
wait_log 5000 $H < My account | Change password | ×
delay 300
screenshot $t/phone_nested.png
click Button "< My account"
wait_log 5000 $H < Server | My account | ×
delay 300
click Button "×"
wait_log 5000 server window: closed
quit
C
hearth phone 390x844 -u 1
cat > "$t/desk.cmds" <<C
wait_log 60000 accounts: ntfy asked
wait_log_any 5000 $H - | Pushes to your phone (ntfy) | ×
delay 300
event scan page
screenshot $t/desk_page.png
click Button "×"
wait_log 5000 server window: closed
quit
C
hearth desk 1100x1000
python3 - "$t" <<'PY' || fail "the Server window's header (see above; $t)"
import re, sys
t = sys.argv[1]
def scan(log, label):
    """The window's rectangle and its elements, each (depth, kind, rect,
    text, hidden by itself or under a hidden one)"""
    win, els, hidden_at = None, [], None
    for l in open(f"{t}/{log}.log", errors="replace"):
        m = re.search(rf"scan {label}: server window at (-?\d+),(-?\d+) size (\d+)x(\d+)", l)
        if m:
            win, els, hidden_at = tuple(map(int, m.groups())), [], None
            continue
        m = re.search(rf"scan {label}: ui( +)(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)(.*)", l)
        if not m or win is None:
            continue
        d = len(m.group(1))
        if hidden_at is not None and d <= hidden_at:
            hidden_at = None
        hid = hidden_at is not None or " hidden" in m.group(7)
        if hid and hidden_at is None:
            hidden_at = d
        tx = re.search(r' text "(.*?)"', m.group(7))
        els.append((d, m.group(2), tuple(map(int, m.groups()[2:6])),
            tx and tx.group(1), hid))
    assert win, f"{log}: no scan {label} of the window"
    return win, els
def over(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and \
        a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
# The ×: one, at the window's top right, nothing else shown over it; a
# "< ..." in the header row or none
def header(log, label, back):
    win, els = scan(log, label)
    xs = [i for i, e in enumerate(els) if e[3] == "×" and not e[4]]
    assert len(xs) == 1, f"{log}: {len(xs)} ×s shown"
    xb = els[xs[0] - 1][2]
    wx, wy, ww, wh = win
    assert xb[0] + xb[2] >= wx + ww - 16 and xb[1] <= wy + 16, \
        f"{log}: the × at {xb}, not the window's top right {win}"
    hit = [e for i, e in enumerate(els) if i not in (xs[0], xs[0] - 1) and
        not e[4] and e[1] in ("Text", "Button", "LineEdit") and over(e[2], xb)]
    assert not hit, f"{log}: over the × {xb}: {hit}"
    backs = [e for e in els if e[3] and e[3].startswith("< ") and not e[4]]
    if back:
        assert backs and backs[0][3] == back and backs[0][2][1] < xb[1] + xb[3], \
            f"{log}: no {back} in the header row: {backs}"
    else:
        assert not backs, f"{log}: a back in the header: {backs}"
    return win, els, xb
win, els, xb = header("phone", "page", "< Server")
assert win[0] <= 4 and win[1] <= 4 and win[2] >= 390 - 8 and win[3] >= 844 - 8, \
    f"phone: the window {win} does not fill the 390x844 screen"
title = [e for e in els if e[3] and e[3].startswith("Pushes") and not e[4]]
assert title and title[0][2][1] < xb[1] + xb[3], f"phone: the title not in the header: {title}"
print(f"ok: phone: the window {win} fills the screen; < Server, {title[0][3]!r}, the × at {xb}")
win, els, xb = header("phone", "sidebar", None)
shown = [e[3] for e in els if e[3] in ("Account", "Health") and not e[4]]
assert shown == ["Account", "Health"], f"phone: the sidebar not shown: {shown}"
assert any(e[1] == "ScrollView" and e[4] for e in els), "phone: the page shown with the sidebar"
print("ok: phone: < Server showed the sidebar, the page hidden, the × still there")
win, els, xb = header("desk", "page", None)
title = [e for e in els if e[3] == "Pushes to your phone (ntfy)" and not e[4]]
assert title and title[0][2][1] < xb[1] + xb[3], f"desk: the title not in the header: {title}"
print(f"ok: desk: the window {win}; the title and the × at {xb} in its header")
PY
for n in phone desk; do
	grep -aq "close_glyph: closing" "$t/$n.log" || fail "$n: the × did not close the window"
done
echo "PASS: clicks inside the Server window keep it; one off it goes back to Settings; its header row on a phone and a desktop (shots: $t/*.png)"
