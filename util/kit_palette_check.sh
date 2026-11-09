#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-09)
# covers: builtin/kit/client_lua/editor.lua builtin/kit/types/*.lua builtin/kit/types/*.prefab.json
# [KIT_PALETTE_SECTIONS] The editor's Place tab on a fresh Workbench save,
# kitboss (the admin) at 1024x700:
#   1. its sections (World, Building, ... by about.group, a stock prefab's
#      group), World folded by its header and opened again;
#   2. the filter: "light", "fog", "sky" and "rendering" find kit/environment
#      (its about text, its keywords), "creature" finds [kit/creature].
#   util/kit_palette_check.sh          native
#   util/kit_palette_check.sh web      the same in headless Chrome
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
mode=${1:-native}
check_tmp kit_palette; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
web=""
if [ "$mode" = web ]; then
	command -v "${CHROME:-google-chrome}" > /dev/null || skip "no Chrome"
	[ -f "$here/web/buildat.wasm" ] || skip "no web build (util/build_web.sh)"
	web="-W $here/web"
fi
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 $web ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)

finds=(light fog sky rendering)
if [ "$mode" = web ]; then
	steps=$(web_login_steps webboss "$t/srv.log") || fail "$steps"
	{
		echo '['
		echo ' ["nav", "${URL}"],'
		echo "$steps"
		cat <<'J'
 ["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
 ["click", "Button", "Don't add"], ["frames", 3],
 ["waitlog_any", "player physics enabled", 120],
 ["waitlog_any", "kit editor: edit rights: yes", 20],
 ["key", "F6"], ["waitlog_any", "kit editor: state: 1 entities", 20], ["frames", 5],
 ["click", "Button", "section World"], ["waitlog", "the palette's section World closed", 10], ["frames", 3],
 ["shot", "${OUT}/closed.png"],
 ["click", "Button", "section World"], ["waitlog", "the palette's section World open", 10], ["frames", 3],
J
		for f in "${finds[@]}" creature; do
			echo " $(pal_find_web "$f") [\"waitlog_any\", \"the palette for \\\"$f\\\"\", 10],"
		done
		echo ' ["shot", "${OUT}/found.png"], ["sync", 3000]'
		echo ']'
	} > "$t/web.json"
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/web.json" "$t/drive" \
		> "$t/drive.txt" 2>&1 || fail "the web drive ($(tail -2 "$t/drive.txt"), $t/drive)"
	b=$t/drive/page.log
else
	b=$t/kitboss.log
	{
		cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: state: 1 entities, 0 to undo
frames 5
click Button "section World"
wait_log_any 5000 the palette's section World closed
frames 3
EOF
		echo "screenshot $t/closed.png"
		printf 'click Button "section World"\nwait_log_any 5000 the palette'"'"'s section World open\nframes 3\n'
		for f in "${finds[@]}" creature; do
			pal_find "$f"
			printf 'wait_log_any 5000 the palette for "%s"\n' "$f"
		done
		printf 'screenshot %s\nquit\n' "$t/found.png"
	} > "$t/kitboss.cmds"
	wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
	[ -n "$code" ] || fail "no setup code ($t/srv.log)"
	BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
		run_client 60 "$b" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_kitboss" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -u 1 \
		-c @"$t/kitboss.cmds" || fail "the client failed ($b, $t/srv.log)"
fi
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null

# 1. The sections, the fold
sec=$(grep -aoP "kit editor: the palette's sections: \K.*" "$b" | tail -1)
[ -n "$sec" ] || fail "no sections logged ($b)"
for g in World Building Logic Game Players Creatures Vehicles Items UI; do
	echo "$sec" | grep -qE "(^|, )$g [0-9]+" || fail "no section $g in: $sec ($b)"
done
echo "$sec" | grep -q "Other" && fail "a stock type in Other: $sec ($b)"
all=$(grep -aoP 'kit editor: the palette for "": \K\d+' "$b" | head -1)
world=$(echo "$sec" | grep -oP 'World \K\d+')
grep -aqF "kit editor: the palette for \"\": $((all - world))" "$b" ||
	fail "World folded did not hide its $world of $all ($b)"
echo "ok: sections $sec; World folded and opened ($t/closed.png)"
# 2. The filter
for f in "${finds[@]}"; do
	grep -aP "kit editor: the palette for \"$f\": \d+: " "$b" | grep -qF "kit/environment" ||
		fail "\"$f\" did not find kit/environment ($b)"
done
grep -aP 'kit editor: the palette for "creature": \d+: ' "$b" | grep -qF "[kit/creature]" ||
	fail "\"creature\" did not find [kit/creature] ($b)"
echo "ok: the filter finds kit/environment by ${finds[*]}, [kit/creature] by its name ($t/found.png)"
echo "PASS: the Place tab's sections and filter ($mode)"
