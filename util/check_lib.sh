# SPDX-License-Identifier: Apache-2.0 OR MIT
# The checks' kit ([CHECK_KIT]), sourced by every check and drive: the
# runners' contract (fail, skip, the PASS:/FAIL:/SKIP: line and its exit
# status), servers and clients started and waited on, waits for a log
# line, the checks' own processes, temp directories, the permission
# store -- and, what it began as, a user and a cache path of the checks'
# own, so that the desk's playtesting and a check never share saves,
# settings, a local server's pid file or module builds (user, 2026-10-04).
# The binaries take BUILDAT_USER_PATH and BUILDAT_CACHE_PATH as their
# defaults (src/boot/autodetect.cpp); a -D or -C given still wins.
#
#   . "$(dirname "$0")/../util/check_lib.sh"
_check_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# CHECK_USER_PATH another, for a run beside one that holds the checks' own
# (a script that refuses to start next to a running buildat looks only there)
export BUILDAT_USER_PATH="${CHECK_USER_PATH:-$_check_root/local/check/user}"
export BUILDAT_CACHE_PATH="$_check_root/local/check/cache"
mkdir -p "$BUILDAT_USER_PATH/shared/vanilla" "$BUILDAT_CACHE_PATH"
# A server or client a check starts goes when its parent does
# ([CHECK_SERVER_ORPHANS]): a check SIGKILLed past its EXIT trap left its
# server running. Started under `timeout N`, the parent is timeout, which
# lives on up to N seconds.
export BUILDAT_DIE_WITH_PARENT=1
# builtin/luanti's self-checks (the shapes, the registry, the map's round
# trip) run only when asked ([LUANTI_SELFCHECKS_OFF]): every check asks
export BUILDAT_LUANTI_SELFCHECKS=1
# Kit's and floorplanner's editor text at 100 %, where the checks measured
# their clicks; the default is 80 ([KIT_EDITOR_FONT]). A native client only.
export BUILDAT_TEST_EDITOR_FONT="${BUILDAT_TEST_EDITOR_FONT:-100}"
# [KIT_PHONE_EDITING] Kit's editor in its desktop layout, a touch client's
# too (BUILDAT_TOUCH=1 is the touch mode's otherwise): where the checks'
# clicks were measured. A native client only; util/web_drive.js asks the
# page for the same.
export BUILDAT_TEST_KIT_UI_MODE="${BUILDAT_TEST_KIT_UI_MODE:-1}"
# The ci mode ([CI_TIER] 3): under BUILDAT_CI a client draws unlit unless
# the runner names a mode -- a third to a quarter of pbr's cost on
# llvmpipe (the item's table). Without the variable nothing changes.
# simplified: the render mode only; the window stays each runner's -w (the
# runners click at UI coordinates), the view range each server's
[ -n "${BUILDAT_CI:-}" ] && export BUILDAT_RENDER_MODE="${BUILDAT_RENDER_MODE:-unlit}"
# Nothing leaves the machine under it ([CI_TIER] 4): the public Luanti
# server list, which the serverlist extension and apps/play fetch
# unasked, asked of a closed loopback port unless a runner serves its own
# simplified: luanti_client's official-list page is hard-coded and only
# fetched when opened; its runner (servers_ui.sh) is "needs: network"
[ -n "${BUILDAT_CI:-}" ] && export \
	BUILDAT_SERVERLIST_URL="${BUILDAT_SERVERLIST_URL:-http://127.0.0.1:9}" \
	BUILDAT_LUANTI_LIST="${BUILDAT_LUANTI_LIST:-http://127.0.0.1:9}"
# The client's default Starport, Aitta and Hearth, which count as accepted
# for its own fetches ([LIVELY_MENU]), and the servers' default Starport:
# a closed loopback port unless a runner serves its own, so no check
# reaches the public ones
export BUILDAT_STARPORT_DEFAULT="${BUILDAT_STARPORT_DEFAULT:-https://127.0.0.1:9}" \
	BUILDAT_AITTA_DEFAULT="${BUILDAT_AITTA_DEFAULT:-https://127.0.0.1:9}" \
	BUILDAT_HEARTH_DEFAULT="${BUILDAT_HEARTH_DEFAULT:-https://127.0.0.1:9}"
# The Luanti games and textures the checks play, from the desk's user path:
# hard links, so nothing is copied and a boxed server (Landlock is by path)
# can read them, which it could not through a symlink out of its user path.
# The checks only read them; a write into a linked file would reach the desk.
# simplified: linked once; a game the desk updates later is not seen until
# local/check/user/shared/vanilla/<dir> is removed and linked again
_check_link_games() # <from: a shared/vanilla>
{
	local d
	for d in games texture_packs textures; do
		[ -d "$1/$d" ] && [ ! -e "$BUILDAT_USER_PATH/shared/vanilla/$d" ] &&
			{ cp -al "$1/$d" "$BUILDAT_USER_PATH/shared/vanilla/$d" 2>/dev/null || {
			# Across file systems (a CHECK_USER_PATH in /tmp): copied
			rm -rf "$BUILDAT_USER_PATH/shared/vanilla/$d"
			cp -r "$1/$d" "$BUILDAT_USER_PATH/shared/vanilla/$d"; }; }
	done
}
_check_link_games "$_check_root/user/shared/vanilla"

# **A runner's own user path, emptied each run** ([BOX_SHARED_USER_SAVES]):
# local/check/runs/<the runner's path>, all of it removed at the call but
# the games and texture packs, linked once (~0.5 s) from the user path
# it had (the desk's, linked above, or a parent runner's). Saves,
# settings and the address store are the run's own: a save of a newer
# format that another branch's run left in the shared user path (the
# check box runs the branches in one slot) is not read. Exported as
# CHECK_USER_PATH, so a script the runner starts that sources this file
# shares it. The compiled modules stay shared (BUILDAT_CACHE_PATH).
# Under the tree, not /tmp: the links need one file system, and a boxed
# server reads nothing through a symlink out of its user path.
# simplified: one directory a runner, so the same runner twice at once in
# one tree shares it; a mktemp'd name and a removal at exit if that is
# ever wanted.
#   check_user          right after sourcing this file
check_user()
{
	local u from=$BUILDAT_USER_PATH/shared/vanilla
	u=$(realpath --relative-to="$_check_root" "$0") || fail "check_user: no runner at $0"
	u="$_check_root/local/check/runs/$(echo "${u%.sh}" | tr / _)"
	export CHECK_USER_PATH=$u BUILDAT_USER_PATH=$u
	mkdir -p "$u/shared/vanilla"
	find "$u" -mindepth 1 -maxdepth 1 ! -name shared -exec rm -rf {} +
	find "$u/shared" -mindepth 1 -maxdepth 1 ! -name vanilla -exec rm -rf {} +
	find "$u/shared/vanilla" -mindepth 1 -maxdepth 1 ! -name games \
		! -name texture_packs ! -name textures -exec rm -rf {} +
	_check_link_games "$from"
}

# An address a scripted client may connect to without the network
# permission dialog, which a command file cannot answer: an accepted entry
# in the checks' own store, fresh for the week it is valid.
#   check_allow udp://127.0.0.1:30030
check_allow()
{
	local now; now=$(date +%s)
	mkdir -p "$BUILDAT_USER_PATH"
	printf '"true","%s","","%s","%s","","",""\n' "$1" "$now" "$now" \
		>> "$BUILDAT_USER_PATH/network_addresses.csv"
}

# **The checks' own processes, never the desk's.** A check's client and
# server -- and a server its client starts -- carry BUILDAT_USER_PATH in
# their environment from here; a playtest's do not. So "is a server up",
# "which pid is the server" and "stop the server" ask about these alone,
# and a check neither waits on, nor reads, nor kills the user's game. A
# scripted client's window is told apart by its WM_CLASS
# (doc/client_commands.txt), so a playtest is no reason to skip a check.
#
#   check_pgrep buildat_server         the pids, one a line; 1 if none
#   check_pkill [-SIG] buildat_server
check_pgrep()
{
	local p found=1
	for p in $(pgrep -x "$1"); do
		grep -qzxF "BUILDAT_USER_PATH=$BUILDAT_USER_PATH" \
				"/proc/$p/environ" 2>/dev/null || continue
		echo "$p"
		found=0
	done
	return $found
}

check_pkill()
{
	local sig=-TERM pids
	[ "${1#-}" != "$1" ] && { sig=$1; shift; }
	pids=$(check_pgrep "$1") || return 1
	kill "$sig" $pids
}
# For a python body's subprocess: bash -c "check_pgrep buildat_server"
export -f check_pgrep check_pkill

# **A check fails on a build older than the tree** ([BUILD_IS_TREE]): the
# git hash the build was made at (Build/lib/libbuildat_core.so's, which
# both binaries load; "web": web/buildat.wasm's) and
# git's diff from it to HEAD over what that build compiled in -- natively
# src, 3rdparty and CMakeLists.txt; the web bundle packs what
# CMakeLists.txt's WEB_PRELOAD names too, and no other builtin/ path
# ([STALE_GUARD_BUILTIN]: a module's server code is the server's, read at
# its start). Called by start_server and run_client before their first start and
# by util/web_drive.sh. BUILDAT_STALE_OK=1 lets a deliberate run through.
# A hash git does not know (a git archive, a rebased build) is passed.
# simplified: uncommitted changes are not seen, the hash being a commit's;
# the binary's "-dirty" marker is the upgrade if that ever matters.
#   check_build [web] [file]   file: read in place of the build's (a check)
check_build()
{
	local root=$_check_root f h changed paths="src 3rdparty CMakeLists.txt"
	f=$root/Build/lib/libbuildat_core.so
	if [ "${1:-}" = web ]; then
		f=$root/web/buildat.wasm paths="$paths client extensions
			builtin/luanti/client_data builtin/voxel_shading/client_data
			builtin/client_lua/client_lua/wasm_main.lua"
	elif [ -z "${2:-}" ]; then
		[ -z "${CHECK_BUILD_DONE:-}" ] || return 0
		CHECK_BUILD_DONE=1
	fi
	f=${2:-$f}
	[ -f "$f" ] || return 0
	h=$(grep -aom1 'buildat-git-hash:[0-9a-z-]*' "$f" | sed 's/^buildat-git-hash://;s/-dirty$//')
	[ -n "$h" ] || h=none
	changed=$(git -C "$root" diff --name-only "$h" HEAD -- $paths 2>/dev/null) ||
		{ [ "$h" = none ] || return 0; changed="(built before [BUILD_IS_TREE])"; }
	[ -n "$changed" ] || return 0
	changed=$(echo $changed | cut -c1-300)
	if [ -n "${BUILDAT_STALE_OK:-}" ]; then
		echo "check_build: BUILDAT_STALE_OK: ${f#"$root"/} is of $h; changed since: $changed" >&2
		return 0
	fi
	fail "the build is older than the tree: rebuild (${f#"$root"/} is of $h; changed since: $changed)"
}

# **A check's server, started and waited for** ([CHECK_START_SERVER]):
#
#   start_server <log> <ready-regex> <timeout_s> <port|auto> <command...>
#
# runs the command with "-P <port>" added, its output ANSI-stripped into
# <log>, and waits until <log> matches <ready-regex> (grep -E). Sets
# SERVER_PID (the server itself, not a pipe's end) and SERVER_PORT.
# **The port is checked first**: one already listened on (a desk server
# on 29500, another check) fails at once, naming it -- before, the check
# waited out its timeout as "did not come up", or talked to the other
# server. "auto" picks a free one in 29700-29999. A server that exits
# while waited for fails at once too. Returns 1 when the server did not
# come up, 2 when the port is taken, with the reason (and the log's tail)
# on stderr; the caller says FAIL. A check with a verdict of its own on a
# server that did not come up (a SKIP) keeps it, and still fails on a
# taken port:
#   start_server ... || [ $? = 1 ] || exit 1
#   VAR=x start_server ...  sets VAR for the server, as for any command
port_taken()
{
	# Without ss every port would read as free and never listened on
	command -v ss > /dev/null || fail "port_taken needs ss (iproute2)"
	ss -Hltnu "( sport = :$1 )" 2>/dev/null | grep -q .
}
# **The official Luanti server** ([LUANTI_SERVER_START]): the tree in
# LUANTI (~/projects/luanti) and its server LUANTI_SERVER_BIN (LUANTI_BIN
# when given, as the runners took it, else that tree's bin/luanti-refshots).
#   start_luanti_server <world> <config> <log> [timeout s, 120]
# Up when its log says so and its port is bound; its address allowed to
# the client (check_allow). Sets LUANTI_PID -- in
# CHECK_PIDS, which check_cleanup stops -- and LUANTI_PORT, a free one, so
# two runs at once neither collide nor stop each other's; 1 if it did not
# come up
LUANTI=${LUANTI:-$HOME/projects/luanti}
LUANTI_SERVER_BIN=${LUANTI_BIN:-$LUANTI/bin/luanti-refshots}
start_luanti_server()
{
	local _i
	for _i in $(seq 50); do
		LUANTI_PORT=$((30000 + RANDOM % 1000))
		port_taken $LUANTI_PORT || break
	done
	# The client connects only to an address it was told is fine
	check_allow "udp://127.0.0.1:$LUANTI_PORT"
	( cd "$LUANTI" && exec "$LUANTI_SERVER_BIN" --server --world "$1" \
		--port "$LUANTI_PORT" --config "$2" > "$3" 2>&1 ) &
	LUANTI_PID=$!
	CHECK_PIDS+=($LUANTI_PID)
	for _i in $(seq $((${4:-120} * 5))); do
		grep -q "Server for gameid" "$3" 2>/dev/null && port_taken $LUANTI_PORT &&
			return 0
		kill -0 $LUANTI_PID 2>/dev/null || return 1
		sleep 0.2
	done
	return 1
}

start_server()
{
	local log=$1 ready=$2 timeout=$3 port=$4 _i
	shift 4
	check_build
	if [ "$port" = auto ]; then
		for _i in $(seq 50); do
			port=$((29700 + RANDOM % 300))
			port_taken $port || break
		done
	fi
	if port_taken $port; then
		echo "start_server: port $port is taken: $(ss -Hltnup "( sport = :$port )" 2>/dev/null | head -1)" >&2
		return 2
	fi
	SERVER_PORT=$port
	# [CHECK_STOP_STATUS] check_cleanup reads this log for a crash. Only in
	# the check's own shell: a subshell's trap would clean up the parent's
	# temp directory and pids at its exit
	# simplified: a server started in a subshell, or under a check's own EXIT
	# trap that does not call check_cleanup, goes unread
	_CHECK_SERVER_LOGS+=("$(realpath -m "$log")")
	if [ "$BASHPID" = "$$" ] && [ -z "$(trap -p EXIT)" ]; then
		trap check_cleanup EXIT
	fi
	"$@" -P "$port" > "$log" 2>&1 &
	SERVER_PID=$!
	for _i in $(seq $((timeout * 5))); do
		grep -qaE "$ready" "$log" 2>/dev/null && return 0
		if ! kill -0 $SERVER_PID 2>/dev/null; then
			echo "start_server: the server exited before \"$ready\" ($log):" >&2
			tail -15 "$log" >&2
			return 1
		fi
		sleep 0.2
	done
	grep -qaE "$ready" "$log" 2>/dev/null && return 0
	echo "start_server: no \"$ready\" in $timeout s ($log):" >&2
	tail -15 "$log" >&2
	return 1
}

# **The kit** ([CHECK_KIT]): what a check needs besides a server, once.
#
# The contract a check keeps, so that a
# machine can read the result and not only a person ([CI_RUNS] (1)).
#
#   exit 0   the check passed
#   exit 1   the check failed
#   exit 77  the check could not run at all -- media that is not there, a
#            server already up, a game that is not installed
#
# and a last line beginning PASS:, FAIL: or SKIP: saying which. run_all
# reads both ([RUN_ALL_VERDICT]): a SKIP: line is a skip whatever the
# status, and 0 with no PASS: line, or bash's 2 on a syntax error, fails.
#
# **The trap this is for**: a runner that prints its verdict and then goes
# on to list its pictures or grep its log exits with *that* command's
# status, which is a green light with the fault written inside it. Nine
# runners did (2026-09-22). So the verdict's status is kept the moment it
# is made and the runner exits by it:
#
#   python3 - "$out" <<'PY'
#   ...
#   PY
#   verdict_keep
#   ls "$out"/*.png            # whatever else the run wants to print
#   verdict_exit
#
# verdict_keep has to be the very next line after the command that made
# the verdict, since it reads $?.
SKIP=77
# world.mt lines for a web check's world: the least the server keeps,
# sends and runs, so that what a check measures is the page and not a
# browser choking on the world (user, 2026-10-14). Below the "Server
# performance..." form's minimum (4, 4, 4, 100): the buildat server reads
# a range below 4 blocks as one 64-node section, Luanti as given.
WEB_WORLD_MT='max_block_send_distance = 2
max_block_generate_distance = 2
active_object_send_range_blocks = 2
liquid_loop_max = 10'
# A web page's way into vanilla's launcher server: not the launcher's own
# client, it joins by builtin/accounts' login ([GUEST_NAME_REUSE]). The
# steps, for a steps file after its nav, that make an account and wait
# for its join: with the server's log, its first admin by the setup code
# there, else an ordinary account (an admin's pause menu has "Who may talk" over View range, 10 CSS
# px). By the keyboard, as a tap would take a touch page fullscreen before
# the world's first pick: from the name, Tab past the password and Join to
# "Create a new account"; the make page's fields in Tab order and "Create
# account" after them, the name typed over the one a page that joined
# before puts in. The 1 s settles: a page that does not fit is
# scaled down 500 ms after the last key (src/client/app.cpp's
# update_ui_fit). The frames between keys and texts: keys sent at once
# put the texts in the wrong fields in a run as a phone at 873x393
# (2026-10-29). The last key is a gesture: a game that wants fullscreen
# takes the page fullscreen with it as the world starts, and a headless
# fullscreen page is not resized (?pref=web_address_bar=show keeps it).
#   steps=$(web_login_steps <name> [server log]) || fail "$steps"
web_login_steps(){
	local code=""
	if [ -n "${2:-}" ]; then
		# accounts may log it after the server's Listening
		wait_for_log "$2" "setup code [A-Z0-9]+" 30
		code=$(grep -ao "setup code [A-Z0-9]*" "$2" | head -1 | cut -d' ' -f3)
		[ -n "$code" ] || { echo "no setup code ($2)"; return 1; }
	fi
	cat <<J
 ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "$1"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
J
	# The code's field is there while the server has no admin
	[ -z "$code" ] ||
		echo ' ["type", "'"$code"'"], ["frames", 2], ["key", "Tab"], ["frames", 2],'
	echo ' ["key", "Enter"], ["waitlog", "Joined as '"$1"'", 30],'
}
# [KIT_PALETTE_SECTIONS] The Kit editor's Place tab narrowed by its filter to
# <text> (an entry's name; a prefab's without its brackets), so a click on
# the entry finds it whatever the palette's length or sections. The filter
# runs as the text changes, the frames are its rebuild's.
#   pal_find <text>                  a native drive's lines
#   pal_find_web <text> [click|tap]  web_drive steps, a comma after
pal_find(){
	printf 'click Button "palette filter clear"\nframes 2\nclick LineEdit "palette filter"\nframes 2\ntext %s\nframes 3\n' "$1"
}
pal_find_web(){
	local c=${2:-click}
	echo "[\"$c\", \"Button\", \"palette filter clear\"], [\"frames\", 2], [\"$c\", \"LineEdit\", \"palette filter\"], [\"frames\", 2], [\"type\", \"$1\"], [\"frames\", 3],"
}
fail(){ echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit $SKIP; }

# [CI_TIER] 4: under BUILDAT_CI a runner whose verdict needs pixels, or
# the LAN or a machine outside the run, says so on a "# needs: pixels" /
# "# needs: network" line and is skipped with that reason; without the
# variable it runs
_needs=$(grep -m1 '^# needs:' "$0" 2>/dev/null)
[ -n "${BUILDAT_CI:-}" ] && [ -n "$_needs" ] && skip "BUILDAT_CI: ${_needs#\# }"

# A temp directory of the check's own in $CHECK_TMP, removed at its exit
# with the pids in CHECK_PIDS stopped first; KEEP_TMP=1 keeps it and says
# where. A check with a trap of its own calls check_cleanup from it.
# **A failed check keeps its logs** (user, 2026-10-30): its *.log and
# screenshots copied to local/check/failed/<dir>, not the worlds and
# caches (kept /tmp dirs filled the quota once); run_all prunes them by
# age. simplified: "failed" is the exit status the trap sees, so a check
# whose own trap runs commands before check_cleanup keeps nothing
#   check_tmp starport; CHECK_PIDS+=($SERVER_PID)
# **A server that crashed fails the check** ([CHECK_STOP_STATUS]): a check's
# stop ignores the exit status and a pass deletes the logs, so a crash as a
# server stopped went unseen. Read off the log, not the exit status, so a
# crash under the cleanup's own kill counts too. CHECK_CRASH_OK=1 for a check
# that crashes one on purpose.
# simplified: what prints nothing (SIGKILL, the OOM killer) goes unseen
CHECK_PIDS=()
_CHECK_SERVER_LOGS=()
_CHECK_CRASH_RE='^Crash: |ERROR: AddressSanitizer'
check_tmp()
{
	CHECK_TMP=$(mktemp -d "/tmp/buildat_$1.XXXXXX")
	trap check_cleanup EXIT
}
check_cleanup()
{
	local status=$? p i killed=("${CHECK_PIDS[@]}") crashed=
	for p in "${CHECK_PIDS[@]}"; do kill "$p" 2>/dev/null; done
	# A local server a failed drive's client started and did not stop
	# (2026-10-13: one outlived world_mods_check and made the next checks
	# skip): any buildat process working in this check's directory. By
	# its name and PID, so the shell running this never matches.
	if [ -n "${CHECK_TMP:-}" ]; then
		for p in $(ps -eo pid=,comm=,args= | awk -v d="$CHECK_TMP" \
				'$2 ~ /^buildat/ && index($0, d) { print $1 }'); do
			kill "$p" 2>/dev/null; killed+=("$p")
		done
	fi
	# **Gone before the next check starts** (2026-10-13: a Starport still
	# exiting held its port, and the next check's bound nothing): up to
	# 10 s for them to exit, then a kill they cannot ignore
	for p in "${killed[@]}"; do
		for i in $(seq 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.2; done
		kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
	done
	if [ "$status" = 0 ] && [ -z "${CHECK_CRASH_OK:-}" ]; then
		for p in "${_CHECK_SERVER_LOGS[@]}"; do
			grep -aqE "$_CHECK_CRASH_RE" "$p" 2>/dev/null || continue
			echo "FAIL: a server crashed ($p):"
			grep -aE -A15 "$_CHECK_CRASH_RE" "$p" | head -30
			crashed=1 status=1
		done
	fi
	if [ -z "${CHECK_TMP:-}" ]; then
		[ -z "$crashed" ] || exit 1
		return 0
	fi
	if [ "$status" != 0 ] && [ -z "${KEEP_TMP:-}" ]; then
		local kept="$_check_root/local/check/failed/$(basename "$CHECK_TMP")"
		mkdir -p "$kept" && (cd "$CHECK_TMP" && find . -type f \
				\( -name '*.log' -o -name '*.png' -o -name '*.cmds' \) \
				-size -20M -exec cp --parents {} "$kept" \;)
		echo "logs kept in $kept"
	fi
	if [ -n "${KEEP_TMP:-}" ]; then echo "kept $CHECK_TMP"; else rm -rf "$CHECK_TMP"; fi
	[ -z "$crashed" ] || exit 1
}

# **The game's clock** ([CHECK_TIME_SCALE]): a server run with
# --sim-rate <n> ticks 1/30 s of game time each, n times as often as the
# wall clock's (0: as fast as they go), and writes its game seconds to
# <user path>/game_clock. A ceiling, never assumed reached: on a slower
# machine the game is the same, only slower, so a wait on the game's
# time is given in its seconds (wait_for_log's fourth argument, a drive's
# game_clock command), the wall clock only a hang's net. CHECK_RATE is the
# rate with a client attached, short of the CPU's (the fans);
# CHECK_RATE_HEADLESS a server's alone.
#   game_seconds <user path>          the seconds, empty before the first
#   game_rate <user path> <n>         the rate from now on (the offset kept)
CHECK_RATE=${CHECK_RATE:-12}
CHECK_RATE_HEADLESS=${CHECK_RATE_HEADLESS:-0}
game_seconds()
{
	cat "$1/game_clock" 2>/dev/null
}
game_rate()
{
	local off
	off=$(awk '{ print $1; exit }' "$1/sim_clock" 2>/dev/null)
	echo "${off:-0} $2" > "$1/sim_clock"
}

# **The machine's speed** ([CHECK_TIMING_LIMITS]): a limit on what is a
# performance (a handler's ms, a generation's seconds, a budget) is given
# for this desk and scaled by CHECK_SLOW, how much longer a fixed workload
# takes now than on the desk: four copies of a loop at once (a 4 vCPU box
# and a machine loaded by other runs both read slower), never under 1,
# so a limit keeps its teeth here. Measured once a check, at its first
# slow_limit (not in a $(...), which would lose it), and passed on to
# what it runs; a CHECK_SLOW given is kept.
# A step's limit is in frames, ticks or the game's time instead, and a
# margin a margin: neither is scaled. The loop's table fits a core's
# cache: one of 4 MB read the check box's vCPUs as one core (9x the
# desk), where its ground generation is 1.4x. The desk (16 threads) read
# 0.09 s; the 4 vCPU check box 0.12-0.15 s
#   slow_limit limit 10       # $limit 10 here; 25 on a machine 2.5x slower
CHECK_SLOW_DESK_S=0.09
check_slow()
{
	[ -n "${CHECK_SLOW:-}" ] && return
	local bin="$_check_root/local/check/speed_2" s e p ps=()
	if [ ! -x "$bin" ]; then
		printf '%s\n' '#include <stdio.h>' '#include <stdint.h>' \
			'static uint32_t a[1 << 14];' 'int main(void){ uint32_t x = 1;' \
			'for(long i = 0; i < 100000000; i++){ x = x * 1664525u + 1013904223u; a[x >> 18] += x; }' \
			'printf("%u\n", a[12345]); return 0; }' |
			cc -O2 -x c - -o "$bin.$$" && mv "$bin.$$" "$bin" ||
			{ export CHECK_SLOW=1; echo "check_slow: no cc; CHECK_SLOW=1" >&2; return; }
	fi
	s=$(date +%s%N)
	for p in 1 2 3 4; do "$bin" > /dev/null & ps+=($!); done
	wait "${ps[@]}"
	e=$(date +%s%N)
	export CHECK_SLOW=$(awk -v t=$(((e - s) / 1000000)) -v d=$CHECK_SLOW_DESK_S \
		'BEGIN { f = t / 1000 / d; printf "%.2f", f < 1 ? 1 : f }')
	echo "check_slow: $CHECK_SLOW ($(((e - s) / 1000000)) ms)" >&2
}
slow_limit() # <variable> <limit>: the variable set to the limit times CHECK_SLOW
{
	check_slow
	printf -v "$1" '%s' "$(awk -v l="$2" -v f="$CHECK_SLOW" 'BEGIN { printf "%g", l * f }')"
}
# **Drawn frames** ([FP_MOVE_BOX_FRAMES]): a limit on a frame's time with
# its drawing in it is the GPU's as well, which CHECK_SLOW does not see. A
# client drawing with software GL (the check box's Xvfb: llvmpipe) logs it
# in its "GL renderer:" line; true then.
#   soft_gl "$t/client.log" && limit=...
soft_gl() # <client log>
{
	grep -aqiE "GL renderer: .*(llvmpipe|softpipe|swrast|swiftshader|software)" "$1"
}

# What a check waits on, rather than a fixed sleep: until <file> has a
# line matching <regex> (grep -E), up to <seconds>; 1 if it never did.
# With a server's user path, the seconds are its game's (game_clock
# above), and the wait ends early only when that clock has not moved for
# 60 s of the wall's
#   wait_for_log "$t/srv.log" "Listening at" 60 || fail "no server"
#   wait_for_log "$t/srv.log" "round over" 30 "$t/u" || fail "no round"
wait_for_log()
{
	local i g g0= last= still=0
	if [ -n "${4:-}" ]; then
		while ! grep -qaE "$2" "$1" 2>/dev/null; do
			g=$(game_seconds "$4")
			[ -n "$g0" ] || g0=$g
			if [ "$g" = "$last" ]; then still=$((still + 1)); else last=$g still=0; fi
			[ -n "$g" ] && [ $((g - g0)) -ge "$3" ] && break
			[ $still -ge 300 ] && break
			sleep 0.2
		done
		grep -qaE "$2" "$1" 2>/dev/null
		return
	fi
	for i in $(seq $(($3 * 5))); do
		grep -qaE "$2" "$1" 2>/dev/null && return 0
		sleep 0.2
	done
	grep -qaE "$2" "$1" 2>/dev/null
}

verdict_keep()
{
	verdict_rc=$?
	return 0
}

verdict_exit()
{
	exit "${verdict_rc:-0}"
}

# For a runner whose verdict is a shell test rather than a python block
verdict_set()
{
	verdict_rc=$1
}

# **A run that has stopped saying anything is over** (user, 2026-09-24:
# a check "ran for 4 minutes and wasn't progressing"). A wedged client,
# or a drive whose waits are all sitting out their timeouts, otherwise
# burns minutes of a check that has already failed -- and the whole
# point of a tier is that a failure is read soon.
#
#   run_client 60 "$out/cli.log" timeout 600 bin/buildat ... -c @cmds
#
# The command's output goes to the log, raw; a caller that wants the
# colour codes out runs sed -i over it afterwards, as it did over the
# pipe. The watcher takes the run down as soon as the log has not grown
# for <stall> seconds. A driven client says something at least every ten
# seconds -- every command it runs, and a heartbeat while a wait_log
# waits -- so quiet means stuck.
#
# The status is the command's, or 125 when the watchdog took it down.
run_client()
{
	local stall=$1 log=$2
	shift 2
	check_build
	: > "$log"
	"$@" > "$log" 2>&1 &
	# quiet counts tenths of a second: the poll is short so the run ends
	# when the client does, not up to a poll later
	local pid=$! last=0 quiet=0 size=0
	while kill -0 "$pid" 2>/dev/null; do
		sleep 0.5
		size=$(wc -c < "$log" 2>/dev/null || echo 0)
		if [ "${size:-0}" -gt "$last" ]; then
			last=$size
			quiet=0
			continue
		fi
		quiet=$((quiet + 5))
		[ "$quiet" -lt "$((stall * 10))" ] && continue
		echo "run_client: nothing logged for ${stall}s; taken down" >> "$log"
		# The child too: the command is usually "timeout ... bin/buildat",
		# and killing timeout outright leaves the client behind
		pkill -9 -P "$pid" 2>/dev/null
		kill -9 "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
		return 125
	done
	wait "$pid"
}

# **The last drive's client is not this drive's condition.** A check
# that runs several clients in a row starts the next one while the last
# is still shutting down: it holds a port, and it answers -- or stops --
# the server this run just started, which reads as "the screen never
# opened". Waits for the tree to go quiet, up to <seconds> (30 by
# default); 1 if it never did.
wait_quiet()
{
	local s=${1:-30} i=0
	while check_pgrep buildat >/dev/null || check_pgrep buildat_server >/dev/null; do
		i=$((i + 1))
		if [ "$i" -ge "$((s * 5))" ]; then
			echo "wait_quiet: a client or server is still up after ${s}s" >&2
			return 1
		fi
		sleep 0.2
	done
	return 0
}
# [AITTA_KEY_IDENTITY] A public key's fingerprint (its hex, or a file of
# it): the first 20 hex digits of the sha256 of its bytes, which name a
# package where it is installed (installed/<fp>/<name>, "<fp>.<name>")
aitta_fp() # <public key hex or file>
{
	local k=$1
	[ -f "$k" ] && k=$(tr -d ' \n' < "$k")
	python3 -I -c 'import hashlib, sys
print(hashlib.sha256(bytes.fromhex(sys.argv[1])).hexdigest()[:20])' "$k"
}
# vim: set noet ts=4 sw=4:
