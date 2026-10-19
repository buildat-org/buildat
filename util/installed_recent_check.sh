#!/bin/bash
# tier: full
# cost: ~40s (2026-10-09)
# covers: client/api.lua
# [INSTALLED_RECENT]: a game or an app just installed is first on the
# launcher's recent list. Four launcher starts on one user path:
#   1. a game and an app already there (an upgraded client): all seen,
#      nothing noted in the launch history;
#   2. a game added: noted;
#   3. an app added: noted, and first on "Continue" (a screenshot kept);
#   4. a new version of that app: not new, the history unchanged.
#
#   util/installed_recent_check.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/util/check_lib.sh"
t=$(mktemp -d); c=$t/cl
fail() { echo "FAIL: $*"; echo "kept $t"; exit 1; }
app() { # name version
	mkdir -p "$c/installed/someone/$1/$2/launcher"
	echo "return function(ctx) return {{id = \"play\", label = \"$1\"," \
		"run = function() end}} end" > "$c/installed/someone/$1/$2/launcher/init.lua"
}
# Home's rows logged, then a second for them drawn
start() { # name
	printf 'wait_log_any 20000 rows in\ndelay 1000\nscreenshot %s\nquit\n' "$t/$1.png" > "$t/cmds"
	(cd "$here" && timeout 40 Build/bin/buildat -o launch_ui=launch_menu -D "$c" \
		-w 1024x768 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/$1.log" 2>&1) ||
		fail "$1: the client exited $? (see $t/$1.log)"
}
history() { cut -d' ' -f2 "$c/launch_history.csv" 2>/dev/null | tr '\n' ' '; }

mkdir -p "$c/shared/vanilla/games/oldgame/mods"; app old_app 1.0
start r1
[ -z "$(history)" ] || fail "an upgrade noted: $(history)"
grep -qx "installed/someone.old_app/play" "$c/launch_seen.csv" ||
	fail "the app not seen on the first start"
mkdir -p "$c/shared/vanilla/games/newgame/mods"
start r2
[ "$(history)" = "app/vanilla/newgame " ] || fail "the game: $(history)"
sleep 1; app new_app 1.0 # the history's times are seconds: a later one
start r3
[ "$(history)" = "installed/someone.new_app@1.0/play app/vanilla/newgame " ] ||
	fail "the app: $(history)"
app new_app 1.1
start r4
[ "$(history)" = "installed/someone.new_app@1.0/play app/vanilla/newgame " ] ||
	fail "a new version noted: $(history)"
cp "$t/r3.png" "$here/local/installed_recent.png"
rm -rf "$t"
echo "PASS: an upgrade notes nothing; a new game and a new app are first, a new version is not new (Continue: local/installed_recent.png)"
