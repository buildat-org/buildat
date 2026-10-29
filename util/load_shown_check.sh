#!/bin/bash
# tier: broken
# broken: back to full; a 15 s still stretch at a phone's CPU; dev fails it
#   too, passing some runs (local/runs/dev_baseline)
# cost: ~12 min (2026-10-11)
# covers: src/client/state.cpp src/client/web/index.html builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua
# [LOAD_SHOWN]: the web client's start says what it is doing. Vanilla on
# VoxeLibre in Chrome as a phone, its CPU six times slower
# (util/web_drive.js's cpu and watch steps): from the page opening to the
# world drawn, with an empty cache and then with it full, the page as
# drawn never stays the same for 15 s; no file comes twice (a module's
# announce after the connect's asked for them again) and the cached ones
# are not asked for.
# simplified: 15 s, not the 2 s the item wants: the game's first scripts
# run in one frame, about 10 s at this CPU (2.6 s of it the Luanti
# texture modifiers composed again at every start), with "Starting the
# game..." up. Run across frames they would want a game's handlers kept
# from running in a half-loaded script.
# Needs mineclone2 in the desk's games.
#   util/load_shown_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || skip "no mineclone2"
command -v "${CHROME:-google-chrome}" > /dev/null || skip "no Chrome"
[ -f "$here/web/buildat.wasm" ] || skip "no web/ (util/build_web.sh)"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp load_shown; t=$CHECK_TMP
trap check_cleanup EXIT
mkdir -p "$t/srv/shared/vanilla/games"
cp -r "$G" "$t/srv/shared/vanilla/games/"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=ls start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 \
	-W "$here/web" || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
# The 10 s after the first world is two of the page's 5 s IndexedDB
# saves (index.html's setInterval): the cache written before the reload.
# simplified: waited by time, as no save says it is done; a console line
# from index.html's save() once a save started after the world is written
# would be the event (each save saying so would be one every 5 s).
# The second page's own start before its watch: the first one's last
# lines come in after the navigation
# Each page joins by the login (check_lib.sh), the first as the server's
# admin, the second with an account of its own: watched up to the login
# page, and from the login to the world
login1=$(web_login_steps lsplayer "$t/srv.log") || fail "$login1"
login2=$(web_login_steps lsplayer2)
world='["watch", "settle: \\d+ to mesh, ([2-9]\\d\\d|\\d{4,}) chunks in scene", 900, 15000]'
cat > "$t/steps.json" <<J
[
 ["cpu", 6],
 ["nav", "\${URL}"],
 ["watch", "accounts: hello: ", 900, 15000],
$login1
 $world,
 ["wait", 10000],
 ["nav", "\${URL}"],
 ["waitlog", "I __main  : buildat [0-9]", 120],
 ["watch", "accounts: hello: ", 900, 15000],
$login2
 $world
]
J
TOUCH=1 WEB_DRIVE_VIEWPORT=400x800@2 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome vanilla "$t/steps.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 ||
	fail "the drive: $(grep "watch: still\|web_drive.js" "$t/drive.txt" | tail -4)"
L=$t/drive/page.log
grep -aq "not requested" "$L" && fail "files came twice: $(grep -ac "not requested" "$L") ($L)"
read -r cached all < <(grep -ao "[0-9]* of [0-9]* announced files are cached" "$L" |
	awk '$3 > 1000' | tail -1 | awk '{print $1, $3}')
[ -n "${all:-}" ] && [ "$cached" -gt $((all * 9 / 10)) ] ||
	fail "the second start had ${cached:-?} of ${all:-?} files cached ($L)"
echo "PASS: at a phone's CPU nothing stood 15 s from the page to the world, empty or cached ($cached of $all); no file came twice"
