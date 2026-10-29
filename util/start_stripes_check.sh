#!/bin/bash
# tier: full
# cost: ~8 min (three compiles of every builtin module, 2026-10-18)
# covers: src/server/state.cpp extensions/launch_menu/screens.lua extensions/ui_utils/init.lua
# [START_STRIPES_ETA]: the compile's percentage and the launcher's start in
# the stripes. A server on an empty build path compiles every module and
# writes compile_times.txt, a line a module; its builds removed (the
# times kept), a second start's STATUS lines carry percentages that never
# fall and end at 100. The launcher starting vanilla on an empty cache
# shows "Starting vanilla... <p>%" in the stripes, and Escape cancels the
# start: the server stopped.
#   util/start_stripes_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp start_stripes; t=$CHECK_TMP
# A cache of its own: the checks' shared one holds every module built, and
# a server loads those as they are
export BUILDAT_CACHE_PATH="$t/cache"
cd "$here/Build"
for n in 1 2; do
	start_server "$t/srv$n.log" "STATUS Listening" 900 auto \
		bin/buildat_server -m "$here/apps/floorplanner" -r "$t/build" \
		-D "$t/srv" -l 3 || fail "the server, run $n ($t/srv$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	if [ $n = 1 ]; then
		# A boxed server builds into its app's own cache, not -r's
		tf=$(find "$t/cache" "$t/build" -name compile_times.txt 2>/dev/null | head -1)
		times=$([ -n "$tf" ] && wc -l < "$tf")
		compiled=$(grep -ao "Compiled [0-9]* of" "$t/srv1.log" | awk '{print $2}')
		[ -n "$times" ] && [ "$times" -ge "${compiled:-99}" ] && [ "${compiled:-0}" -ge 2 ] ||
			fail "compile_times.txt: ${times:-none} lines for ${compiled:-no} compiled ($t/srv1.log)"
		find "$(dirname "$tf")" -mindepth 1 ! -name compile_times.txt -delete
	fi
done
pcts=$(grep -ao "STATUS Compil[a-z]* .*, [0-9]*%)" "$t/srv2.log" | sed 's/.*, \([0-9]*\)%)$/\1/' | tr '\n' ' ')
echo "the second start's percentages: $pcts"
echo "$pcts" | awk '{ for(i = 2; i <= NF; i++) if($i < $(i - 1)) exit 1;
	exit !(NF >= 3 && $NF == 100) }' ||
	fail "the percentages fell, or did not end at 100: $pcts ($t/srv2.log)"
# The launcher on an empty cache: the stripes with a percentage, then
# Escape
printf '%s\n' "wait_log_any 600000 (compiling)" "delay 1500" \
	"screenshot $t/start.png" "keypress Escape" \
	"wait_log 15000 Local server stopped" quit > "$t/c.cmds"
BUILDAT_CACHE_PATH="$t/cache2" timeout 700 bin/buildat -o launch_ui=launch_menu \
	-a app/vanilla/contentdb -w 1024x640 -l 3 -L "$t/client.log" \
	-c @"$t/c.cmds" > /dev/null 2>&1 ||
	fail "the launcher's drive: $(grep -a 'Command sequence failed' "$t/client.log" | head -1) ($t/client.log)"
grep -aqE "launch_menu: start: Starting [a-z]*\.\.\. [0-9]+% \(compiling\)" "$t/client.log" ||
	fail "no percentage in the stripes ($t/client.log)"
srv=$(grep -a "Started pid [0-9]*: .*buildat_server" "$t/client.log" | head -1 |
	sed 's/.*Started pid \([0-9]*\):.*/\1/')
[ -n "$srv" ] && ! kill -0 "$srv" 2>/dev/null ||
	fail "Escape did not stop the server (${srv:-no pid}) ($t/client.log)"
echo "the launcher: $(grep -a "launch_menu: start: " "$t/client.log" | tail -1 | sed 's/.*launch_menu: //')"
check_cleanup
echo "PASS: compile times kept, the start's percentage rising to 100, the launcher's start in the stripes, Escape cancels"
