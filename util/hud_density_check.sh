#!/bin/bash
# tier: full
# cost: ~5 min (2026-10-11)
# covers: extensions/luanti_client/res/hotbar.lua extensions/luanti_client/res/hud_draw.lua extensions/luanti_client/res/formspec.lua
# [HUD_DENSITY]: the HUD at the screen's density, the hotbar's one row
# capped to its width. Vanilla on VoxeLibre in Chrome as a phone (density
# 2.75, touch), hotbar.lua logging the row in the frame's pixels and
# hud_draw.lua each statbar's extent:
#   - sideways (2400x1080 device pixels), VoxeLibre's 9 slots: a slot's
#     picture is Luanti Android's 48 x 2.75 = 132;
#   - upright (1080x2400): one row, its picture behind it on the screen
#     and the row at least 90 % of the width;
#   - 32 slots (hud_set_hotbar_itemcount), upright and sideways: one row,
#     the same;
#   - every statbar on the screen;
#   - natively (density 1) at 1280x720: the picture 48, as before.
# The screenshots are copied to /tmp/buildat_hud_density_shots for an eye.
# Needs mineclone2 in the desk's games.
#   util/hud_density_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || { echo "SKIP: no mineclone2"; exit 0; }
command -v "${CHROME:-google-chrome}" > /dev/null || { echo "SKIP: no Chrome"; exit 0; }
[ -f "$here/web/buildat.wasm" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp hud_density; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/srv
mkdir -p "$d/shared/vanilla/games" "$d/apps/vanilla/saves/hd/luanti"
cp -r "$G" "$d/shared/vanilla/games/"
cat > "$d/shared/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.after(5, function() core.chat_send_player(name, "hd: ready") end)
	core.after(25, function()
		local p = core.get_player_by_name(name)
		if p then
			p:hud_set_hotbar_itemcount(32)
			core.chat_send_player(name, "hd: wide")
		end
	end)
end)
L
echo "enable_damage = false" > "$d/apps/vanilla/saves/hd/luanti/world.mt"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=hd \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$d.cache" -l 3 \
	-W "$here/web" || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
# 873x393 CSS pixels at 2.75 is 2401x1081
cat > "$t/steps.json" <<'J'
[
 ["nav", "${URL}"],
 ["waitlog", "chat: hd: ready", 600], ["wait", 2000],
 ["shot", "${OUT}/sideways9.png"],
 ["viewport", 393, 873], ["wait", 3000],
 ["shot", "${OUT}/upright9.png"],
 ["waitlog", "chat: hd: wide", 400], ["wait", 2000],
 ["shot", "${OUT}/upright32.png"],
 ["viewport", 873, 393], ["wait", 3000],
 ["shot", "${OUT}/sideways32.png"]
]
J
TOUCH=1 WEB_DRIVE_VIEWPORT=873x393@2.75 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome vanilla "$t/steps.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the drive: $(tail -2 "$t/drive.txt")"
L=$t/drive/page.log
mkdir -p /tmp/buildat_hud_density_shots
cp "$t"/drive/*.png /tmp/buildat_hud_density_shots/
# "n picture row0 row1 bg0 bg1 width", one line per change
rows(){ grep -aoP 'hotbar: \K\d+ slots, picture \d+, row -?\d+ to \d+, background -?\d+ to \d+, of \d+' "$1" |
	sed 's/ slots, picture / /; s/, row / /; s/ to / /g; s/, background / /; s/, of / /'; }
rows "$L" > "$t/rows.txt"
python3 - "$t/rows.txt" <<'PY' || fail "the hotbar ($t/rows.txt, $L)"
import sys
rows = [list(map(int, l.split())) for l in open(sys.argv[1]) if l.strip()]
def last(n, wide):
    m = [r for r in rows if r[0] == n and (r[6] > 2000) == wide]
    assert m, "no row of %d slots %s" % (n, "sideways" if wide else "upright")
    return m[-1]
s9 = last(9, True)
assert s9[1] == 132, "sideways 9: picture %d, not 132" % s9[1]
for n, wide in ((9, False), (32, False), (32, True)):
    r = last(n, wide)
    assert r[4] >= 0 and r[5] <= r[6], "%s: the picture off the screen" % r
    assert r[2] >= 0 and r[3] - r[2] >= 0.9 * r[6], \
        "%s: the row not 90 %% of the width" % r
    print("ok: %d slots %s: picture %d, row %d of %d" % (n,
        "sideways" if wide else "upright", r[1], r[3] - r[2], r[6]))
PY
bad=$(grep -aoP 'hud: statbar \S+ from \K-?\d+ to \d+ of \d+' "$L" | awk '$1 < 0 || $3 > $5')
[ -z "$bad" ] || fail "a statbar off the screen: $bad ($L)"
[ "$(grep -ac "hud: statbar" "$L")" -gt 0 ] || fail "no statbar drawn ($L)"
# Natively, density 1
printf 'wait_log 300000 chat: hd: ready\ndelay 2000\nquit\n' > "$t/n.cmds"
timeout 400 "$here/Build/bin/buildat" -C "$t/nc" -D "$t/nu" -s 127.0.0.1:$SERVER_PORT \
	-w 1280x720 -l 3 -o sound_mute=1 -c @"$t/n.cmds" > "$t/native.log" 2>&1
grep -a "Command sequence failed" "$t/native.log" && fail "the native drive ($t/native.log)"
read -r n pic _ < <(rows "$t/native.log" | tail -1)
[ "${pic:-}" = 48 ] || fail "natively the picture is ${pic:-?}, not 48 ($t/native.log)"
echo "PASS: the hotbar at the density (132 sideways), one row fitting the width upright and at 32 slots, the statbars on the screen, natively 48 as before"
