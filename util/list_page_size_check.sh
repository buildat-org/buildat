#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-30)
# covers: extensions/ui_utils/init.lua extensions/launch_menu/preferences.lua src/client/app.cpp src/client/app_lua.h
# [LIST_PAGE_SIZE]: Page Up and Down move at most what is in sight and at
# most page_size items. A game of its own (made here) shows 60 rows in a
# list_view 300 px high, eight in sight:
#   1. a menu (vertical_menu): Page Down three times and Page Up; each
#      moves the selection by 3 with -o page_size=3, by the 8 in sight
#      with page_size=50;
#   2. after Escape, a keyboard_page over the same rows: the view scrolls
#      by 3 rows with page_size=3, by page_step's rows shown less
#      two with 50, and the focus with it.
#   3. 1 and 2 with page_size=3 in Chrome (web/ from util/build_web.sh,
#      the preference by ?pref=).
#
#   util/list_page_size_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp list_page_size; t=$CHECK_TMP

mkdir -p "$t/lpk/main/client_lua"
cat > "$t/lpk/main/meta.json" <<'J'
{
	"engine_api": 2,
	"kind": "check",
	"disable_cpp": true,
	"client_main": "init.lua",
	"dependencies": [
		{"module": "network"},
		{"module": "client_lua"}
	]
}
J
cat > "$t/lpk/main/client_lua/init.lua" <<'L'
local log = buildat.Logger("lpk")
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
-- 60 rows in a view 300 high: eight in sight
local function rows(win)
	local view = ui_utils.list_view(win, 300, 300,
			{row_height = 28, follow_focus = true})
	local out = {}
	for i = 1, 60 do
		out[i] = view:row({label = string.format("row%02d", i)})
		-- The label's name is what the page key's log line gives
		out[i]:GetChild(1):SetName(string.format("row%02d", i))
	end
	view:fit()
	return out
end
local root = uistack.main:push({desc = "lpk menu"})
local menu = ui_utils.vertical_menu(root, {on_key = function(key)
	if key ~= magic.KEY_ESCAPE then
		return
	end
	uistack.main:pop(root)
	local w = magic.ui.root:CreateChild("Window")
	w.defaultStyle = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")
	w:SetStyleAuto()
	w:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(16, 16, 16, 16))
	w:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	rows(w)
	ui_utils.keyboard_page(w)
	log:info("lpk: page up")
	return true
end})
for _, b in ipairs(rows(menu.window)) do
	menu:add(b, function() end)
end
log:info("lpk: menu up")
L

start_server "$t/srv.log" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -A 127.0.0.1 -m "$t/lpk" -D "$t/s" \
	-C "$t/s.cache" -l 3 -W "$here/web" || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)

keys='delay 300\n'
for k in PageDown PageDown PageDown PageUp; do keys+="keypress $k\ndelay 250\n"; done
printf "wait_log_any 60000 lpk: menu up\n${keys}keypress Escape\nwait_log 5000 lpk: page up\n${keys}quit\n" > "$t/cmds"

# verify <log> <page_size>: the menu's moves and the page's
verify(){
	python3 - "$1" "$2" <<'PY'
import re, sys
log, n = open(sys.argv[1], errors="replace").read(), int(sys.argv[2])
menu = re.findall(r"page key: menu (\d+) -> (\d+) of (\d+), (\S+) in sight, at most (\d+)", log)
assert len(menu) == 4, "%d menu page lines, not 4" % len(menu)
for a, b, total, seen, most in menu:
    assert int(most) == n, "page_size read as %s, not %d" % (most, n)
    assert 3 < int(seen) < 50, "%s rows in sight: neither cap shown" % seen
    want = min(n, int(seen))
    assert abs(int(b) - int(a)) == want, "menu %s -> %s, not by %d" % (a, b, want)
shown = int(menu[0][3])
page = re.findall(r"page key: (\d+) -> (\d+) of (\d+), view (\d+), focus (\S+)", log)
assert len(page) == 4, "%d keyboard page lines, not 4" % len(page)
for a, b, total, h, focus in page:
    h = int(h)
    r = h // 20
    # 60 rows 2 apart: the rows' pitch from the list's height
    pitch = (int(total) + 2) // 60
    step = min((r - 2 if r > 4 else r - 1) * 20, n * pitch)
    assert abs(int(b) - int(a)) == step, "page %s -> %s, not by %d (view %d)" % (a, b, step, h)
# Going down the focus is the first row in sight: page_size rows on
# while that is fewer than are in sight, else no more than are in sight
f = [int(x[4][3:]) for x in page[:3]]
if n < shown:
    assert f == [1 + n, 1 + 2 * n, 1 + 3 * n], "the focus going down: %s" % f
else:
    assert all(0 < y - x <= shown + 1 for x, y in zip([1] + f, f)), "the focus going down: %s" % f
print("menu " + " ".join("%s->%s" % (a, b) for a, b, _, _, _ in menu) +
    "; page " + " ".join("%s->%s (%s)" % (a, b, fo) for a, b, _, _, fo in page))
PY
}

for n in 3 50; do
	run_client 60 "$t/c$n.log" timeout 90 "$here/Build/bin/buildat" -C "$t/c" \
		-D "$t/u" -w 800x600 -l 3 -o sound_mute=1,page_size=$n \
		-s "127.0.0.1:$SERVER_PORT" -c @"$t/cmds" ||
		fail "the native drive, page_size=$n ($t/c$n.log)"
	got=$(verify "$t/c$n.log" $n) || fail "native, page_size=$n: $got ($t/c$n.log)"
	echo "ok: native, page_size=$n: $got"
done

if [ ! -f "$here/web/buildat.wasm" ] ||
		! command -v "${CHROME:-google-chrome}" > /dev/null; then
	echo "PASS: native (the web SKIPPED: no web/ or Chrome)"; exit 0
fi
{
	echo '[["viewport", 800, 600], ["nav", "${URL}?pref=page_size=3"],'
	echo '["waitlog", "lpk: menu up", 120], ["wait", 300],'
	for k in PageDown PageDown PageDown PageUp; do echo "[\"key\", \"$k\"], [\"wait\", 300],"; done
	echo '["key", "Escape"], ["waitlog", "lpk: page up", 10], ["wait", 300],'
	for k in PageDown PageDown PageDown PageUp; do echo "[\"key\", \"$k\"], [\"wait\", 300],"; done
	echo '["shot", "${OUT}/web.png"]]'
} > "$t/web.json"
WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" "$here/util/web_drive.sh" chrome \
	lpk "$t/web.json" "$t/web" > "$t/web.out" 2>&1 ||
	fail "the Chrome drive: $(tail -3 "$t/web.out")"
got=$(verify "$t/web/page.log" 3) || fail "Chrome, page_size=3: $got ($t/web/page.log)"
echo "ok: Chrome, page_size=3: $got"
echo "PASS: Page Up and Down by page_size (3) or the rows in sight (8 of 60 at 50) in a menu and a keyboard page, native and in Chrome"
