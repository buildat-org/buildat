#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-12)
# covers: extensions/ui_utils/init.lua client/extensions/starport/init.lua client/extensions/aitta/init.lua
# [AITTA_FILTER_POP]: a local Aitta with one package, not installed. The
# launcher's "Apps from Aitta", its filter picked Installed, Updates, Not
# installed and All, three times over: no error dialog, each pick a page
# of its own (a new dropdown opened each time), the status matching the
# filter.
#   apps/aitta/filter_pop_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp aitta_filter_pop; t=$CHECK_TMP
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
d="$t/apps/pkg"
mkdir -p "$d"
cp -r ../apps/minigame/main ../apps/minigame/launcher "$d/"
printf '{"author": "tester", "name": "pkg", "version": "1.0.0",
	"engine_api": 1, "license_code": "MIT", "license_media": "CC0-1.0",
	"description": "a filter check"}\n' > "$d/meta.json"
zip=$("$b" aitta pack "$d" "$t/key" "$t/out" 2>/dev/null) || fail "pack"
"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "listed: tester/pkg" || fail "publish"
echo "{\"aittas\": [\"$A\"]}" > "$t/managed.json"
# The Aitta allowed already ([AITTA_NET_DESC]'s check has the dialog)
mkdir -p "$t/cl"
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","%s","Aitta","%s","%s","","",""\n' \
	"$A" $(date +%s) $(date +%s) > "$t/cl/network_addresses.csv"
picks="Installed Updates Not_installed All"
{
	printf 'delay 4000\ntext apps from aitta\ndelay 1000\nkeypress Return\n'
	printf 'wait_log 15000 aitta status: 1 packages\ndelay 1000\n'
	for _ in 1 2 3; do
		for f in $picks; do
			printf 'click DropDownList "▼"\ndelay 700\nclick Text "%s"\ndelay 1200\n' "${f//_/ }"
		done
	done
	echo quit
} > "$t/cmds"
BUILDAT_STARPORT_MANAGED="$t/managed.json" timeout 120 bin/buildat \
	-m launch_menu -D "$t/cl" -w 1280x700 -u 1.4 -l 3 -o sound_mute=1 \
	-c @"$t/cmds" > "$t/c.log" 2>&1
grep -aq "Command sequence complete" "$t/c.log" ||
	fail "the drive ($(grep -a "Command seq" "$t/c.log" | tail -1))"
grep -a "error shown in a dialog" "$t/c.log" && fail "an error dialog ($t/c.log)"
# One page a pick: dropdown_1 to _12 opened in turn
opened=$(grep -a "ui_utils: dropdown_[0-9]* open" "$t/c.log" | sed 's/.*dropdown_\([0-9]*\) open/\1/' | tr '\n' ' ')
[ "$opened" = "$(seq -s ' ' 1 12) " ] || fail "the dropdowns opened: $opened ($t/c.log)"
# The status after each pick: 0 of 1 for Installed and Updates, the one
# for Not installed and All
got=$(grep -a "aitta status: " "$t/c.log" | tail -12 | sed 's/.*aitta status: //' | tr '\n' '|')
want=$(for _ in 1 2 3; do printf '1 packages, 0 shown|1 packages, 0 shown|1 packages|1 packages|'; done)
[ "$got" = "$want" ] || fail "the statuses: $got ($t/c.log)"
echo "PASS: Aitta's filter picked twelve times: a page of its own each time, no error, the list as the filter says"
