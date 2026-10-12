#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-10)
# covers: client/extensions/aitta/init.lua
# [AITTA_PAGE_LAYOUT]: a local Aitta with 14 packages, more than fit, one
# with a long name and description. The launcher's "Apps from Aitta":
#   1. Every package is a row; the wheel over the list reaches the last;
#      a click on it fills the panel (its name, version, licences, its
#      description; Install, Report...).
#   2. Install from the panel installs it; the dropdown's Installed then
#      lists that one only.
#   3. Typing filters the list.
#   4. Nothing outside the window (ui scans, wide and at a phone's size,
#      where the panel is under the list).
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   apps/aitta/page_layout_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp aitta_layout; t=$CHECK_TMP
b="$here/Build/bin/buildat"

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
A=http://127.0.0.1:$P
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'delay 8000\nquit\n' > "$t/reqs.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$code \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl0" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$t/bind.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"
LONG=a_package_with_a_long_name_to_the_end
publish(){ # name description
	local d="$t/apps/$1"
	mkdir -p "$d"
	cp -r ../apps/minigame/main ../apps/minigame/launcher "$d/"
	printf '{"author": "tester", "name": "%s", "version": "1.0.0",
		"engine_api": 1, "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "%s"}\n' "$1" "$2" > "$d/meta.json"
	zip=$("$b" aitta pack "$d" "$t/key" "$t/out" 2>/dev/null) || fail "pack $1"
	"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "listed: tester/$1" ||
		fail "publish $1"
}
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
	publish "pkg$i" "Package number $i."
	# The Aitta's 30 uploads a minute, three a publish
	[ $i = 09 ] && sleep 61
done
publish "$LONG" "$(printf 'A long description that goes on. %.0s' $(seq 8))"
publish zz_last "The last one by name."

echo "{\"aittas\": [\"$A\"]}" > "$t/managed.json"
# The Aitta allowed already: the dialog is [AITTA_NET_DESC]'s check's
mkdir -p "$t/cl"
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","%s","Aitta","%s","%s","","",""\n' \
	"$A" $(date +%s) $(date +%s) > "$t/cl/network_addresses.csv"
# The UI scale given: 1.4 at 1280x700 leaves room for 12 rows, 1 at
# 400x760 is a phone's narrow layout
drive(){ # size scale log commands
	printf "$4" > "$t/cmds"
	BUILDAT_STARPORT_MANAGED="$t/managed.json" timeout 120 bin/buildat \
		-m launch_menu -D "$t/cl" -w "$1" -u "$2" -l 3 -o sound_mute=1 \
		-c @"$t/cmds" > "$3" 2>&1
	grep -aq "Command sequence complete" "$3" ||
		fail "the drive ($(grep -a "Command seq\|aitta \(status\|panel\)" "$3" | tail -3))"
}
open='delay 4000\ntext apps from aitta\ndelay 1000\nkeypress Return\nwait_log 15000 aitta status: 14 packages\ndelay 1000\n'
# Outside: the window outside the frame, or one of its parts down to the
# list's and the panel's viewports outside the window (what is in a
# viewport is clipped by it, so scrolled-away rows are not counted)
outside(){ # log label
	grep -a "scan $2: " "$1" | python3 -c '
import re, sys
win, frame, bad = None, None, []
for l in sys.stdin:
	f = re.search(r"frame (\d+)x(\d+)", l)
	if f:
		frame = tuple(map(int, f.groups()))
	m = re.search(r"ui( +)(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)", l)
	if not m:
		continue
	depth, t = len(m.group(1)), m.group(2)
	x, y, w, h = map(int, m.groups()[2:])
	if win is None:
		if t == "Window":
			win = (x, y, x + w, y + h)
			if x < 0 or y < 0 or x + w > frame[0] or y + h > frame[1]:
				bad.append("the window " + str(win) + " in " + str(frame))
		continue
	# The close glyph sits on the corner of the window, its text box over
	# the edge ([CLOSE_GLYPH])
	if "text \"×\"" in l:
		continue
	if depth <= 7 and w and h and (x < win[0] - 1 or y < win[1] - 1 or
			x + w > win[2] + 1 or y + h > win[3] + 1):
		bad.append(l.strip()[-120:])
print("\n".join(bad[:5]))'
}

# 1. Wide: the rows, the wheel, a click
drive 1280x700 1.4 "$t/wide.log" "${open}event scan wide\nscreenshot $t/wide.png\nmouse_pos 300 250\nmouse_wheel -40\ndelay 500\nscreenshot $t/wheel.png\nclick Button \"tester/zz_last\"\ndelay 1500\nscreenshot $t/last.png\nquit\n"
n=$(grep -a "scan wide: " "$t/wide.log" | grep -ac 'Text at .* text "tester/')
[ "$n" -ge 5 ] || fail "rows in the scan: $n"
for i in 01 12; do
	grep -aq "aitta page: tester/pkg$i 1.0.0" "$t/wide.log" || fail "pkg$i not listed"
done
grep -aq "aitta panel: tester/zz_last 1.0.0" "$t/wide.log" ||
	fail "the wheel did not reach the last ($(grep -a 'aitta panel' "$t/wide.log" | tail -2))"
o=$(outside "$t/wide.log" wide)
[ -z "$o" ] || fail "outside the window, wide: $o"
echo "ok: the rows, the wheel to the last, its panel; inside the window"

# 2. Install from the panel; the Installed filter
drive 1280x700 1.4 "$t/inst.log" "${open}click Button \"tester/pkg01\"\ndelay 1000\nclick Button \"Install\"\nwait_log 15000 aitta status: Installed\ndelay 1000\nscreenshot $t/installed.png\nclick DropDownList \"▼\"\ndelay 500\nkeypress Down\ndelay 200\nkeypress Return\ndelay 1500\nevent scan filtered\nquit\n"
grep -aq "aitta status: Installed tester/pkg01 1.0.0" "$t/inst.log" ||
	fail "the install: $(grep -a 'aitta status' "$t/inst.log" | tail -2)"
[ -d "$t/cl/installed/tester/pkg01/1.0.0" ] || fail "not installed on disk"
rows=$(grep -a "scan filtered: " "$t/inst.log" | grep -ao 'Text at .* text "tester/[a-z0-9_]*"' | grep -o 'tester/[a-z0-9_]*' | sort -u | tr '\n' ' ')
[ "$rows" = "tester/pkg01 " ] || fail "Installed lists: $rows"
echo "ok: installed from the panel; Installed lists it only"

# 3. Typing filters
drive 1280x700 1.4 "$t/type.log" "${open}click LineEdit \"\"\ndelay 300\ntext pkg1\ndelay 1000\nscreenshot $t/typed.png\nquit\n"
grep -aq "aitta status: 3 of 14 packages" "$t/type.log" ||
	fail "typing: $(grep -a 'aitta status' "$t/type.log" | tail -2)"
echo "ok: typing filters"

# 4. At a phone's size
drive 400x760 1 "$t/narrow.log" "${open}event scan narrow\nscreenshot $t/narrow.png\nquit\n"
o=$(outside "$t/narrow.log" narrow)
[ -z "$o" ] || fail "outside the window, narrow: $o"
echo "PASS: a scrolling list of packages and the selection's panel; install, the filter, typing; inside the window wide and narrow (see $t/*.png)"
