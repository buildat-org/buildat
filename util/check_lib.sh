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
# The Luanti games and textures the checks play, from the desk's user path:
# hard links, so nothing is copied and a boxed server (Landlock is by path)
# can read them, which it could not through a symlink out of its user path.
# The checks only read them; a write into a linked file would reach the desk.
# simplified: linked once; a game the desk updates later is not seen until
# local/check/user/shared/vanilla/<dir> is removed and linked again
for _d in games texture_packs textures; do
	[ -d "$_check_root/user/shared/vanilla/$_d" ] &&
		[ ! -e "$BUILDAT_USER_PATH/shared/vanilla/$_d" ] &&
		{ cp -al "$_check_root/user/shared/vanilla/$_d" \
			"$BUILDAT_USER_PATH/shared/vanilla/$_d" 2>/dev/null || {
		# Across file systems (a CHECK_USER_PATH in /tmp): copied
		rm -rf "$BUILDAT_USER_PATH/shared/vanilla/$_d"
		cp -r "$_check_root/user/shared/vanilla/$_d" \
			"$BUILDAT_USER_PATH/shared/vanilla/$_d"; }; }
done
unset _d

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
	ss -Hltnu "( sport = :$1 )" 2>/dev/null | grep -q .
}
start_server()
{
	local log=$1 ready=$2 timeout=$3 port=$4 _i
	shift 4
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
# and a last line beginning PASS:, FAIL: or SKIP: saying which.
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
#   check_tmp starport; CHECK_PIDS+=($SERVER_PID)
CHECK_PIDS=()
check_tmp()
{
	CHECK_TMP=$(mktemp -d "/tmp/buildat_$1.XXXXXX")
	trap check_cleanup EXIT
}
check_cleanup()
{
	local p i killed=("${CHECK_PIDS[@]}")
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
	[ -n "${CHECK_TMP:-}" ] || return 0
	if [ -n "${KEEP_TMP:-}" ]; then echo "kept $CHECK_TMP"; else rm -rf "$CHECK_TMP"; fi
}

# What a check waits on, rather than a fixed sleep: until <file> has a
# line matching <regex> (grep -E), up to <seconds>; 1 if it never did
#   wait_for_log "$t/srv.log" "Listening at" 60 || fail "no server"
wait_for_log()
{
	local i
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
# vim: set noet ts=4 sw=4:
