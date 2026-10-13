#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# [VL_ACHIEVE_BG]: VoxeLibre's achievements form keeps its backdrop on
# every item of its list. An item with progress adds a progress bar as a
# background[] of its own, and the form's backdrop was drawn only for a
# form with no background[] at all, so a click on such an item took it
# away. The fixture does what a click on the list does -- shows the form
# again with that item -- an item without a bar, then one with, and holds
# it; the client shoots every second, and each shot with the bar in it
# must have the backdrop's grey around it -- VoxeLibre's own light panel
# since the server sends the formspec prepend ([VL_INV_PARITY]), where it
# was the client's dark one. Vanilla, 1280x720.
#
#   builtin/luanti/test/vl_achieve_bg.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
out="$here/local/vl_achieve_bg"; mkdir -p "$out"
save=buildat_test_vl_achieve_bg
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running"; exit 77
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save" "$out"/s*.png
cat > "$out/fixture.lua" <<'LUA'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.set_timeofday(0.5)
	core.after(6, function()
		local plain, bar
		for i, a in ipairs(awards._order_awards(name)) do
			local def = awards.def[a.name]
			if def and def.getProgress and not def.secret then
				bar = bar or i
			elseif def and not def.secret then
				plain = plain or i
			end
		end
		awards.show_to(name, name, plain, false)
		core.after(3, function()
			awards.show_to(name, name, bar, false)
			core.log("action", "vl_achieve_bg: the item with a bar, " .. bar)
		end)
	end)
end)
LUA
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 29796 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
# The form shown plain and then with the bar; 500 ms for it to be drawn,
# then a shot a second while the form is held
{ echo "wait_log 90000 form awards:awards opened"
	echo "wait_log 10000 form awards:awards opened"; echo "delay 500"
	for i in $(seq -w 1 5); do
		echo "screenshot $out/s$i.png"; echo "delay 1000"
	done
	echo quit; } > "$out/cmds.txt"
timeout 120 bin/buildat -s localhost:29796 -w 1280x720 -l 3 \
	-o sound_mute=1 -c @"$out/cmds.txt" > "$out/cli.log" 2>&1
grep -aq 'vl_achieve_bg: the item with a bar' "$out/srv.log" ||
	{ echo "FAIL: the fixture did not show the item with a bar"; exit 1; }
python3 - "$out" <<'PY'
import glob, sys
from PIL import Image
shots = with_bar = 0
for path in sorted(glob.glob(sys.argv[1] + "/s*.png")):
    im = Image.open(path).convert("RGB")
    dark = lambda p: max(im.getpixel(p)) < 70
    near = lambda p, c: all(abs(a - b) <= 16 for a, b in
            zip(im.getpixel(p), c))
    # The list's box at two points (a shadowed world passed for one), and
    # the progress bar's grey under the description
    if not dark((700, 400)) or not dark((900, 300)) or \
            not near((330, 495), (157, 157, 157)):
        continue
    with_bar += 1
    # The panel's grey, whatever is behind
    backdrop = [p for p in ((320, 420), (560, 440), (330, 250))
            if not near(p, (208, 208, 208))]
    if backdrop:
        print("FAIL: %s: no backdrop at %s" % (path, backdrop))
        sys.exit(1)
if with_bar == 0:
    print("FAIL: no shot shows the form with the bar")
    sys.exit(1)
print("PASS: the achievements form keeps its backdrop with a progress bar "
      "(%d shots)" % with_bar)
PY
