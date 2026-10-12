#!/bin/bash
# Runs apps on the newest GitHub release's Linux web-precompiled archive,
# and moves to each newer release as it appears. For testing servers in a
# terminal (a GNU screen): it stays in the foreground, the servers' output
# is its own, and Ctrl+C stops them all.
#
#   util/serve_latest_release.sh <game> <port> <user dir> [server options...]
#           [-- <game> <port> <user dir> [server options...]]...
#   util/serve_latest_release.sh floorplanner 29500 ~/buildat-user -T 127.0.0.1
#   util/serve_latest_release.sh floorplanner 29500 ~/fp-user -- vanilla 30000 ~/vanilla-user
#   AITTA=https://aitta.example util/serve_latest_release.sh someone/lamps 29500 ~/lamps-user
#
# **An app from an Aitta** ([AITTA_SERVE]): a game <author>/<name> (a slash
# tells it from the release's own apps) runs the newest version installed
# under <user dir>/installed/<author>/<name>/, which
#   bin/buildat aitta install <Aitta> <author>/<name> <user dir>
# (in a release's directory) puts there; the server calls it
# <author>.<name>, as its saves under <user dir>/apps/. Its version moves
# only when told: with AITTA=<the Aitta's address>, each update check
# installs the app's newest listed release there and restarts onto it as
# for a new engine release, with the same wait and warning; without it the
# installed version stays. Not installed and no AITTA: the script says how
# and stops. **A delisted release** ([SERVE_DELISTED]): each check also
# reads the Aitta's list of what it delisted, and why. The running
# release delisted as malware or CSAM is stopped, a stand-in on its port
# saying it was withdrawn by its Aitta, until a newer listed release is
# installed and compiled. Delisted for another reason: said once in the
# log, and it runs on. simplified: no rollback to an older listed version;
# for one, stop this script, remove the withdrawn version's directory under
# installed/, and start it again -- the newest one left runs.
#
# Each server is a game, a port and a user directory, which holds its
# saves and accounts. Every version uses it (-D), and it can be one a
# server used before. Each server has its own: two given one directory
# would share saves and accounts, and the script refuses to start. The
# servers all run the same release. The rest is under BUILDAT_SERVE_DIR
# (default ~/buildat-serve):
#   versions/<archive>/     each release, unpacked
#   current                 the version running
#   server-<game>-<port>.log  a server's output, also on the terminal with
#                           [<game>:<port>] before each line
# **A new release** ([SERVE_UPDATE_SMOOTH]) is downloaded and unpacked,
# and each server's app compiled on it (--compile-only) while the old one
# serves. A compile that fails keeps every server on the old version, and
# that release is not tried again; a newer one is. **The restart waits
# for nobody to be on** ([SERVE_UPDATE_POLITE]): every server's /health
# says 0 players, or UPDATE_MAX_WAIT seconds (1800) have passed since the
# release compiled. A minute before that, whoever is on is told
# ("<user dir>/apps/<game>/notice", which the server shows every client),
# and a server listed on a Starport is listed as updating. Then one
# server at a time: <user dir>/apps/<game>/shutdown_reason written ("updating to X"),
# which the server tells its clients as it goes (they wait and rejoin),
# stopped with SIGTERM (a game saves on it), started on the new version,
# a stand-in on its port meanwhile, and the next once it is listening.
# A server that exits is started again by itself. Every version but
# the running one and the one before it is deleted. A server that exits with
# status 20 is a game's own restart (apps/vanilla switching its world), and
# is started again at once; meanwhile a stand-in on its port answers a
# browser with a page that says so and reloads itself, until the server
# says it is listening (they share the port: BUILDAT_SHARE_PORT=1).
#
# **The box** ([PROCESS_SANDBOX], 0.5.67 and newer): each server confines
# itself, and refuses to start on a kernel without Landlock unless given
# --unconfined. A boxed server connects out only to ports 80, 443, 465,
# 587, 29500 and 29595; a Starport that lists servers on other ports is
# given more by a file in its user directory, <user dir>/connect_ports,
# one line: "any", or a list such as "8080,30000" -- or as a server option,
# "--connect-ports any".
#
# **A rollback** is by hand, with this script stopped: run the version
# before from its directory,
#   cd ~/buildat-serve/versions/<the one before>
#   bin/buildat_server -m apps/<app> -P <port> -D <user dir>
# for each server. To a release from before apps were called apps
# (0.5.57 and older), it is -m games/<app>, and <user dir>/apps is moved
# back to <user dir>/games first: a newer server moved it on its start.
# Started again, this script goes back to the newest release. A game whose
# saves carry a schema version (the floorplanner) refuses a save that a
# newer version wrote.
#
# **Compiled modules from a build host** ([SERVE_BUILDS]): with
# BUILDS_URL, before each compile -- a new release's, a new Aitta
# version's -- the host is asked (GET, release=<the release's directory
# name>, app=<game>, and for an Aitta app aitta=<AITTA> and
# version=<its version>) for the app's compiled modules: 200 is a tar of
# them (regular files at its top, *.so and *.so.hash), unpacked into the
# release's cache under apps/<app>/rccpp_build, and the compile that
# follows finds them current; 202 is "building", asked again in
# BUILDS_POLL seconds (30) or its Retry-After; 422 is a failed build, its
# body the log, taken as a failed compile; 404 is none offered, and it is
# compiled here, as it is after BUILDS_MAX_WAIT seconds (7200) without an
# answer. The waiting keeps the servers watched; with nothing running yet,
# each port's stand-in says what is building. The tar is code the servers
# load: BUILDS_URL is https, or http to a loopback or private address.
# A server given --unconfined builds into the shared cache and asks
# nothing. simplified: a server option -C (its cache elsewhere) is not
# followed; BUILDAT_CACHE_PATH is.
#
# Environment: AITTA (above), POLL_SECONDS (300), UPDATE_MAX_WAIT (1800),
# GITHUB_REPO (celeron55/buildat),
# GITHUB_TOKEN (optional; unauthenticated, GitHub allows 60 asks an hour),
# RELEASES_URL (GitHub's list of the repo's releases; a check serves its
# own), BUILDS_URL, BUILDS_POLL and BUILDS_MAX_WAIT (above).
# Needs bash, curl and tar; python3 for the stand-in, which is skipped
# without it.
set -u

usage(){
	grep '^#   util/\|^#           \[' "$0" | sed 's/^# *//' >&2
	exit 2
}
# The servers, by index: game, port, user directory, and their options as
# lines
games=() ids=() ports=() users=() opts=()
while [ $# -gt 0 ]; do
	[ $# -lt 3 ] && usage
	games+=("$1")
	# What the server calls it, and its files here and under <user dir>
	ids+=("${1/\//.}")
	ports+=("$2")
	mkdir -p "$3" || exit 1
	u=$(cd "$3" && pwd -P)
	for j in "${!users[@]}"; do
		if [ "${users[$j]}" = "$u" ]; then
			echo "${games[$j]} on port ${ports[$j]} and $1 on port $2 are" \
				"given the same user directory, $u; each needs its own" >&2
			exit 2
		fi
	done
	users+=("$u")
	shift 3
	o=""
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do
		o+="$1"$'\n'
		shift
	done
	opts+=("$o")
	[ $# -gt 0 ] && shift
done
[ ${#games[@]} -eq 0 ] && usage

# An Aitta app's directory: its newest version installed, or nothing
aitta_dir(){
	local d="${users[$1]}/installed/${games[$1]}" v
	# Its versions are directories; the key beside them is a file
	v=$(cd "$d" 2>/dev/null && ls -1d -- */ | tr -d / | sort -V | tail -n 1)
	[ -n "$v" ] && echo "$d/$v"
}
for i in "${!games[@]}"; do
	case ${games[$i]} in */*) ;; *) continue ;; esac
	if [ -z "${AITTA:-}" ] && [ -z "$(aitta_dir "$i")" ]; then
		echo "${games[$i]} is not installed in ${users[$i]}; in a Buildat" \
			"release's directory:" >&2
		echo "  bin/buildat aitta install <Aitta> ${games[$i]} ${users[$i]}" >&2
		echo "or set AITTA=<the Aitta's address> to install it here" >&2
		exit 2
	fi
done

base=${BUILDAT_SERVE_DIR:-$HOME/buildat-serve}
poll=${POLL_SECONDS:-300}
max_wait=${UPDATE_MAX_WAIT:-1800}
repo=${GITHUB_REPO:-celeron55/buildat}
releases_url=${RELEASES_URL:-https://api.github.com/repos/$repo/releases?per_page=10}
asset_re='linux-x86_64-web-precompiled\.tar\.gz'
builds_poll=${BUILDS_POLL:-30}
builds_max_wait=${BUILDS_MAX_WAIT:-7200}
if [ -n "${BUILDS_URL:-}" ]; then
	case $BUILDS_URL in
	https://*|http://127.*|http://localhost[:/]*|http://\[::1\]*|http://10.*|\
	http://192.168.*|http://172.1[6-9].*|http://172.2[0-9].*|http://172.3[01].*) ;;
	*)
		echo "BUILDS_URL is https, or http to a loopback or private address:" \
			"what it answers is code the servers load" >&2
		exit 2 ;;
	esac
fi

mkdir -p "$base/versions"
cd "$base" || exit 1

say(){ echo "[serve $(date '+%F %T')] $*"; }

# The newest release's archive URL, or nothing. Releases come newest
# first, and one still being built has no archive yet: the first URL
# found is the newest there is.
latest_url(){
	local auth=()
	[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
	curl -fsSL --max-time 60 "${auth[@]}" \
			"$releases_url" |
		grep -o '"browser_download_url": *"[^"]*"' |
		sed 's/.*"\(http[^"]*\)"$/\1/' |
		grep -E "$asset_re" | head -n 1
}

# Downloads and unpacks a release into versions/<name>; its name, or
# nothing when it could not
install(){
	local url=$1
	local name
	name=$(basename "$url" .tar.gz)
	if [ -x "versions/$name/bin/buildat_server" ]; then
		echo "$name"
		return
	fi
	local tmp="versions/.download-$name"
	rm -rf "$tmp" "$tmp.tar.gz"
	say "downloading $name" >&2
	if ! curl -fL --retry 3 --max-time 1800 -o "$tmp.tar.gz" "$url" >&2; then
		say "download failed" >&2
		rm -f "$tmp.tar.gz"
		return
	fi
	mkdir -p "$tmp"
	if ! tar -C "$tmp" -xzf "$tmp.tar.gz"; then
		say "the archive would not unpack" >&2
		rm -rf "$tmp" "$tmp.tar.gz"
		return
	fi
	rm -f "$tmp.tar.gz"
	# The archive has one directory at the top
	local top
	top=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)
	if [ -z "$top" ] || [ ! -x "$top/bin/buildat_server" ]; then
		say "no bin/buildat_server in the archive" >&2
		rm -rf "$tmp"
		return
	fi
	rm -rf "versions/$name"
	mv "$top" "versions/$name"
	rm -rf "$tmp"
	echo "$name"
}

# Every version but the current one and the newest other, which is kept
# for a rollback
prune(){
	local keep_prev
	keep_prev=$(ls -1 versions | grep -v '^\.' | grep -vx "$current" |
			sort -V | tail -n 1)
	local v
	for v in $(ls -1 versions | grep -v '^\.'); do
		if [ "$v" != "$current" ] && [ "$v" != "$keep_prev" ]; then
			say "deleting the old version $v"
			rm -rf "versions/$v"
		fi
	done
}

# The servers' process ids, by index; a version a server would not start
# on is not tried again until another comes
pids=() broken=()
# An Aitta app's new version installed and compiled, waiting as a release
# does, by index: its directory
app_new=()
# A release some server's app would not compile on: not tried again
bad_release=""
# A release compiled and waiting for a quiet moment: its name, when it
# was ready, and when whoever was on was warned
pending="" pending_at=0 warned_at=0
# [SERVE_BUILDS] A new release being built, and by index the servers whose
# app is compiled on it; an Aitta app's new version being built, by index;
# the build host's asks running, by their result file
building="" built=() app_building=()
declare -A build_jobs=()
# A restarting server's stand-in, by index: its pid, and the log line
# the server's own "Listening at" is to come after
standins=() standin_from=()

# **The port answered while a server restarts** (user, 2026-10-01: a
# browser that came during a world switch got no page at all): a 503
# page that reloads every 3 s, for anything that connects; a native
# client gets it as well and drops it, as it would a refused connection.
# It shares the port with the server (SO_REUSEPORT, which the server
# sets under BUILDAT_SHARE_PORT=1), so neither waits for the other.
# simplified: one connection at a time, each given up after 2 s
STANDIN_PY='
import html, socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
s.bind(("", int(sys.argv[1])))
s.listen(16)
body = (b"<!doctype html><meta charset=utf-8><meta http-equiv=refresh "
	b"content=3><meta name=viewport content=\"width=device-width\">"
	b"<title>Buildat</title><body style=\"background:#202020;color:#ddd;"
	b"font:16px sans-serif;text-align:center;padding-top:30vh\">The "
	b"server is restarting. This page reloads by itself.</body>")
if len(sys.argv) > 2:
	body = body.replace(b"The server is restarting. This page reloads by itself.",
		html.escape(sys.argv[2]).encode())
head = (b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/html; "
	b"charset=utf-8\r\nRetry-After: 3\r\nCache-Control: no-store\r\n"
	b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body))
while True:
	c, _ = s.accept()
	c.settimeout(2)
	try:
		c.recv(8192)
		c.sendall(head + body)
	except OSError:
		pass
	c.close()
'

standin_start(){ # i [the page's text]
	local i=$1
	command -v python3 >/dev/null || return
	python3 -c "$STANDIN_PY" "${ports[$i]}" ${2:+"$2"} 2>/dev/null &
	standins[$i]=$!
	standin_from[$i]=$(wc -l 2>/dev/null < "$base/server-${ids[$i]}-${ports[$i]}.log" || echo 0)
	say "a stand-in answers on port ${ports[$i]} until ${games[$i]} is back"
}

standin_stop(){
	local i=$1 pid=${standins[$1]:-}
	standin_build[$i]=""
	[ -z "$pid" ] && return
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	standins[$i]=""
}
# By index: the stand-in says a build is waited for, with nothing running
standin_build=()

# Gone once the server is listening, or has exited again: its log since
# the stand-in came
standin_check(){
	local i=$1
	[ -z "${standins[$i]:-}" ] || [ -n "${withdrawn[$i]:-}" ] ||
		[ -n "${standin_build[$i]:-}" ] && return
	if tail -n +"$((standin_from[$i] + 1))" \
			"$base/server-${ids[$i]}-${ports[$i]}.log" 2>/dev/null |
			grep -q "Listening at\|Failed to bind" ||
			! kill -0 "${pids[$i]:-0}" 2>/dev/null; then
		standin_stop "$i"
		say "the stand-in on port ${ports[$i]} is gone"
	fi
}

# The app's directory for server i on version v: the release's apps/<game>
# (games/ before apps were called apps), or an Aitta app's newest installed,
# installed first where AITTA is set and it is not; nothing when there is
# none
app_path(){
	local i=$1 dir="$base/versions/$2"
	case ${games[$i]} in
	*/*)
		local a
		a=$(aitta_dir "$i")
		if [ -z "$a" ] && [ -n "${AITTA:-}" ]; then
			say "installing ${games[$i]} from $AITTA" >&2
			"$dir/bin/buildat" aitta install "$AITTA" "${games[$i]}" \
					"${users[$i]}" >&2
			a=$(aitta_dir "$i")
		fi
		echo "$a"
		;;
	*)
		local apps=apps
		[ -d "$dir/apps" ] || apps=games
		[ -d "$dir/$apps/${games[$i]}" ] && echo "$dir/$apps/${games[$i]}"
		;;
	esac
}

# The Aitta app's directory each server runs, by index
running=()

start(){
	local i=$1 game=${games[$1]} id=${ids[$1]} port=${ports[$1]}
	local dir="$base/versions/$current" app
	app=$(app_path "$i" "$current")
	if [ -z "$app" ]; then
		say "$current has no $game"
		broken[$i]=$current
		return 1
	fi
	local args=()
	[ -n "${opts[$i]}" ] && mapfile -t args <<< "${opts[$i]%$'\n'}"
	say "starting $game on port $port on $current, user ${users[$i]}"
	echo "$current" > "$base/current"
	running[$i]=$app
	(cd "$dir" && BUILDAT_SHARE_PORT=1 exec bin/buildat_server \
			-m "$app" -P "$port" \
			-D "${users[$i]}" "${args[@]}") \
			> >(sed -u "s/^/[$id:$port] /" |
				tee -a "$base/server-$id-$port.log") 2>&1 &
	pids[$i]=$!
}

stop(){
	local i=$1 pid=${pids[$1]:-}
	[ -z "$pid" ] && return
	if kill -0 "$pid" 2>/dev/null; then
		say "stopping ${games[$i]} on port ${ports[$i]}"
		kill -TERM "$pid" 2>/dev/null
		local n
		for n in $(seq 60); do
			kill -0 "$pid" 2>/dev/null || break
			sleep 0.5
		done
		if kill -0 "$pid" 2>/dev/null; then
			say "${games[$i]} did not stop in 30 s; killing it"
			kill -KILL "$pid" 2>/dev/null
		fi
	fi
	wait "$pid" 2>/dev/null
	pids[$i]=""
}

# The new version's compile of server i's app, with its options, while
# the old one serves: the modules land in the version's own cache, which
# the start then finds. True when it compiled.
compile(){
	local i=$1 game=${games[$1]} id=${ids[$1]} port=${ports[$1]} v=$2 app
	local args=()
	[ -n "${opts[$i]}" ] && mapfile -t args <<< "${opts[$i]%$'\n'}"
	app=$(app_path "$i" "$v")
	[ -z "$app" ] && return 1
	say "compiling $game on $v"
	(cd "$base/versions/$v" && exec bin/buildat_server -m "$app" \
			-P "$port" -D "${users[$i]}" "${args[@]}" --compile-only) 2>&1 |
		sed -u "s/^/[$id:$port compile] /" |
		tee -a "$base/server-$id-$port.log"
	return "${PIPESTATUS[0]}"
}

# [SERVE_BUILDS] Server i's app's modules on release $2 (Aitta version
# $3) from the build host, into the file $4: its last line ready, failed
# or local (compile here). Run in the background.
builds_ask(){ # i release version result
	local i=$1 rel=$2 ver=$3 out=$4 first said="" code wait
	local what="${games[$i]}${ver:+ $ver} on $rel"
	local dest="${BUILDAT_CACHE_PATH:-$base/versions/$rel/cache}/apps/${ids[$i]}/rccpp_build"
	local q=(--data-urlencode "release=$rel" --data-urlencode "app=${games[$i]}")
	[ -n "$ver" ] && q+=(--data-urlencode "aitta=$AITTA" --data-urlencode "version=$ver")
	first=$(date +%s)
	while true; do
		code=$(curl -sS --max-time 600 --max-filesize 67108864 -o "$out.body" \
			-D "$out.head" -w '%{http_code}' --get "${q[@]}" "$BUILDS_URL" 2>/dev/null)
		wait=$builds_poll
		case $code in
		200)
			if builds_unpack "$out.body" "$dest"; then
				say "asked BUILDS_URL for $what: ready"
				echo ready > "$out.tmp"
			else
				say "asked BUILDS_URL for $what: failed (not a tar of modules)"
				echo failed > "$out.tmp"
			fi
			break ;;
		202)
			[ -z "$said" ] && say "asked BUILDS_URL for $what: building"
			said=1
			local ra
			ra=$(grep -i '^retry-after:' "$out.head" | tr -dc '0-9' | head -c 5)
			[ -n "$ra" ] && [ "$ra" -ge 1 ] && wait=$ra ;;
		422)
			say "asked BUILDS_URL for $what: failed"
			head -c 65536 "$out.body" | sed "s/^/[build ${ids[$i]}] /"
			echo failed > "$out.tmp"
			break ;;
		404)
			say "asked BUILDS_URL for $what: none offered; compiling here"
			echo local > "$out.tmp"
			break ;;
		esac
		if [ $(($(date +%s) + wait - first)) -gt "$builds_max_wait" ]; then
			say "asked BUILDS_URL for $what: no answer for $builds_max_wait s;" \
				"compiling here"
			echo local > "$out.tmp"
			break
		fi
		sleep "$wait"
	done
	rm -f "$out.body" "$out.head"
	mv "$out.tmp" "$out"
}

# A build host's tar into dir: only regular files at its top named as a
# module or its hash, or nothing is taken
builds_unpack(){ # tar dir
	local names types tmp
	names=$(tar -tf "$1" 2>/dev/null) || return 1
	types=$(tar -tvf "$1" 2>/dev/null | cut -c1 | sort -u)
	[ -z "$names" ] && return 0
	[ "$types" = "-" ] || return 1
	printf '%s\n' "$names" | grep -qvE '^[A-Za-z0-9._-]+\.so(\.hash)?$' && return 1
	mkdir -p "$2" || return 1
	tmp=$(mktemp -d "$2/.unpack.XXXXXX") || return 1
	if ! tar -C "$tmp" --no-same-owner -xf "$1"; then
		rm -rf "$tmp"
		return 1
	fi
	mv -f "$tmp"/* "$2"/ && rm -rf "$tmp"
}

# Whether server i's app on release $2 (Aitta version $3) may be compiled
# now: 0 yes (no build host, or its answer is in), 1 the build failed, 2
# still waiting -- the ask started in the background the first time
prepare(){ # i release version
	local i=$1 f r
	[ -z "${BUILDS_URL:-}" ] && return 0
	printf '%s' "${opts[$i]}" | grep -qx -- --unconfined && return 0
	f="$base/builds/${ids[$i]}~$2~${3:-release}"
	if [ -f "$f" ]; then
		r=$(tail -n 1 "$f")
		rm -f "$f"
		unset "build_jobs[$f]"
		[ "$r" = failed ] && return 1
		return 0
	fi
	if [ -z "${build_jobs[$f]:-}" ]; then
		mkdir -p "$base/builds"
		builds_ask "$i" "$2" "$3" "$f" &
		build_jobs[$f]=$!
	fi
	return 2
}

# The release being built onto every server: each once its modules are in
# (or at once without a build host); every one compiled makes it pending
build_release(){
	local i r v=${building#buildat-} ver
	for i in "${!games[@]}"; do
		[ -n "${built[$i]:-}" ] && continue
		# An Aitta app's ask says its version, installed first if it is
		# not: without one the host took it for a release app it does
		# not know ([BUILDS_AITTA_ASK])
		ver=""
		case ${games[$i]} in */*) ver=$(app_path "$i" "$building"); ver=${ver##*/} ;; esac
		prepare "$i" "$building" "$ver"
		r=$?
		if [ "$r" = 2 ]; then
			[ -z "$current" ] && [ -z "${standins[$i]:-}" ] &&
				standin_start "$i" "Building ${games[$i]} for ${v%%-*}; this page reloads itself." &&
				standin_build[$i]=1
			continue
		fi
		if [ "$r" = 0 ] && compile "$i" "$building"; then
			built[$i]=1
			continue
		fi
		say "${games[$i]} does not compile on $building; staying on" \
			"${current:-nothing} until a newer release"
		bad_release=$building
		building="" built=()
		for i in "${!games[@]}"; do
			[ -n "${standin_build[$i]:-}" ] && standin_stop "$i"
		done
		return
	done
	[ "${#built[@]}" = "${#games[@]}" ] || return
	say "$building is ready; updating once nobody is on, in" \
		"$max_wait s at the latest"
	pending=$building
	building="" built=()
	[ "$pending_at" = 0 ] && pending_at=$(date +%s)
	# Nothing running yet: at once
	[ -z "$current" ] && update
}

# Each Aitta app's new version being built: compiled on the running
# release once its modules are in, then waiting as a release does.
# simplified: a server that exits meanwhile starts on the newest installed,
# this one, compiling it at its start
build_aitta(){
	local i d r
	for i in "${!app_building[@]}"; do
		d=${app_building[$i]}
		[ -z "$d" ] && continue
		prepare "$i" "$current" "${d##*/}"
		r=$?
		[ "$r" = 2 ] && continue
		app_building[$i]=""
		if [ "$r" = 0 ] && compile "$i" "$current"; then
			say "${games[$i]} ${d##*/} is ready; updating once nobody is on," \
				"in $max_wait s at the latest"
			app_new[$i]=$d
			[ "$pending_at" = 0 ] && pending_at=$(date +%s)
		else
			say "${games[$i]} ${d##*/} does not compile on $current; removed," \
				"staying on ${running[$i]##*/}"
			rm -rf "$d"
		fi
	done
}

# A line into a file in server i's app directory, which its sandboxed app
# writes too: the name removed and made anew with noclobber (O_EXCL), so a
# link the app put there is not followed out of the sandbox
app_note(){ # i file text
	local f="${users[$1]}/apps/${ids[$1]}/$2"
	mkdir -p "${users[$1]}/apps/${ids[$1]}"
	rm -f "$f"
	( set -o noclobber; printf '%s\n' "$3" > "$f" ) 2>/dev/null ||
		say "could not write $f"
}

# One server onto the current version: told why, stopped, started, and
# waited for until it listens (or exits, or 10 minutes pass)
restart(){
	local i=$1 why=$2
	if [ -n "${pids[$i]:-}" ] && kill -0 "${pids[$i]}" 2>/dev/null; then
		app_note "$i" shutdown_reason "$why"
	fi
	stop "$i"
	standin_stop "$i"
	withdrawn[$i]=""
	rm -f "${users[$i]}/apps/${ids[$i]}/shutdown_reason"
	local log="$base/server-${ids[$i]}-${ports[$i]}.log" from n
	from=$(wc -l 2>/dev/null < "$log" || echo 0)
	standin_start "$i"
	if start "$i"; then
		for n in $(seq 600); do
			tail -n +"$((from + 1))" "$log" 2>/dev/null |
				grep -q "Listening at\|Failed to bind" && break
			kill -0 "${pids[$i]}" 2>/dev/null || break
			sleep 1
		done
		[ "$n" = 600 ] && say "${games[$i]} is not listening after 10 minutes; going on"
	fi
	standin_stop "$i"
}

# Who is on server i, by its /health; 0 when it does not answer
players(){
	local i=$1 tok="${users[$1]}/apps/${ids[$1]}/health_token.txt" auth=()
	# Not through a link the app put there (dd's nofollow)
	[ -f "$tok" ] && auth=(-H "Authorization: Bearer $(dd if="$tok" \
		iflag=nofollow bs=256 count=1 2>/dev/null | head -n 1 | tr -d '\r')")
	local n
	n=$(curl -s -m 5 "${auth[@]}" "http://127.0.0.1:${ports[$i]}/health" |
		grep -o '"players": *[0-9]*' | grep -o '[0-9]*$')
	echo "${n:-0}"
}

# The pending release onto every server, one at a time; else each Aitta
# app's new version onto its own
update(){
	local old=$current i
	if [ -n "$pending" ]; then
		current=$pending
		# buildat-<version>-<hash>-linux-... said as its version
		local v=${pending#buildat-}
		for i in "${!games[@]}"; do
			restart "$i" "updating to ${v%%-*}"
		done
	else
		for i in "${!games[@]}"; do
			[ -n "${app_new[$i]:-}" ] &&
				restart "$i" "updating to ${games[$i]} ${app_new[$i]##*/}"
		done
	fi
	app_new=()
	pending="" pending_at=0 warned_at=0
	[ -n "$old" ] && [ "$old" != "$current" ] && prune
}

# Updated once nobody is on, or at the latest max_wait after it was
# ready; whoever is on warned a minute before that
update_when_quiet(){
	[ -z "$pending" ] && [ -z "${app_new[*]:-}" ] && return
	local i n on=() now
	now=$(date +%s)
	for i in "${!games[@]}"; do
		n=0
		[ -n "${pids[$i]:-}" ] && n=$(players "$i")
		[ "$n" -gt 0 ] && on+=("$i")
	done
	if [ ${#on[@]} = 0 ] || [ "$now" -ge $((pending_at + max_wait)) ]; then
		[ ${#on[@]} -gt 0 ] && say "updating with ${#on[@]} server(s) still in use"
		update
		return
	fi
	if [ "$warned_at" = 0 ] && [ "$now" -ge $((pending_at + max_wait - 60)) ]; then
		warned_at=$now
		local v=${pending#buildat-}
		v=${v%%-*}
		[ -z "$pending" ] && v="a new version"
		for i in "${on[@]}"; do
			say "warning ${games[$i]} on port ${ports[$i]}: updating to $v in 60 s"
			app_note "$i" notice "The server updates to $v in 60 s"
			app_note "$i" shutdown_reason "updating to $v"
		done
	fi
}

stop_all(){
	local i j
	for j in "${build_jobs[@]}"; do
		kill "$j" 2>/dev/null
	done
	# All told at once, so that they save and go together
	for i in "${!games[@]}"; do
		[ -n "${pids[$i]:-}" ] && kill -TERM "${pids[$i]}" 2>/dev/null
	done
	for i in "${!games[@]}"; do
		stop "$i"
		standin_stop "$i"
	done
}

# [SERVE_DELISTED] Why server i's running release is delisted on the
# Aitta, if it is: "" when listed or when the list cannot be read
delisted_why(){
	local u=$AITTA
	case $u in http://*|https://*) ;; *) u=http://$u ;; esac
	curl -s -m 20 "${u%/}/api/v1/aitta/list" | python3 -c '
import json, sys
try:
	d = json.load(sys.stdin)
except ValueError:
	sys.exit()
for r in d.get("delisted", []):
	if r.get("author") + "/" + r.get("name") == sys.argv[1] and \
			r.get("version") == sys.argv[2]:
		print(r.get("why") or "no reason given")
' "${games[$1]}" "${running[$1]##*/}" 2>/dev/null | head -n 1
}

# Server i's running release withdrawn for malware or CSAM: stopped, a
# stand-in saying so, not started again but by a newer release
withdraw(){ # i why
	local i=$1
	say "${games[$i]} ${running[$i]##*/} on port ${ports[$i]} was delisted by" \
		"$AITTA: $2; stopped until a newer release is listed"
	withdrawn[$i]=${running[$i]##*/}
	app_note "$i" shutdown_reason "withdrawn by its Aitta"
	stop "$i"
	standin_start "$i" "This app was withdrawn by the Aitta it came from ($2)."
}

# By index: the version withdrawn, and the delist already warned of
withdrawn=() delist_said=()

# [AITTA_SERVE] Each Aitta app's newest listed release, installed and
# compiled on the running version; one that does not compile is removed
# again (tried again at the next check)
follow_aitta(){
	local i d why
	for i in "${!games[@]}"; do
		case ${games[$i]} in */*) ;; *) continue ;; esac
		[ -z "${running[$i]:-}" ] && continue
		if [ -z "${withdrawn[$i]:-}" ] && command -v python3 >/dev/null; then
			why=$(delisted_why "$i")
			case $why in
			"") ;;
			malware*|csam*|"reported for malware"*|"reported for csam"*)
				withdraw "$i" "$why" ;;
			*)
				[ "${delist_said[$i]:-}" = "${running[$i]##*/} $why" ] ||
					say "warning: ${games[$i]} ${running[$i]##*/} is delisted" \
						"by $AITTA: $why; it runs on"
				delist_said[$i]="${running[$i]##*/} $why" ;;
			esac
		fi
		if ! d=$("$base/versions/$current/bin/buildat" aitta install \
				"$AITTA" "${games[$i]}" "${users[$i]}" 2>/dev/null); then
			say "could not read ${games[$i]}'s releases from $AITTA"
			continue
		fi
		[ -z "$d" ] || [ "$d" = "${running[$i]}" ] ||
			[ "$d" = "${app_new[$i]:-}" ] ||
			[ "$d" = "${app_building[$i]:-}" ] && continue
		# Only a newer one: the newest listed is older when the running one
		# was delisted, and the start runs the newest installed anyway
		[ "$(printf '%s\n' "${d##*/}" "${running[$i]##*/}" | sort -V |
			tail -n 1)" = "${d##*/}" ] || continue
		app_building[$i]=$d
	done
	build_aitta
}

trap 'stop_all; say "stopped"; exit 0' INT TERM

# What ran last, else the newest there is
current=""
if [ -f current ] && [ -d "versions/$(cat current)" ]; then
	current=$(cat current)
else
	current=$(ls -1 versions | grep -v '^\.' | sort -V | tail -n 1)
fi

next_poll=0
while true; do
	now=$(date +%s)
	if [ "$now" -ge "$next_poll" ]; then
		next_poll=$((now + poll))
		url=$(latest_url)
		if [ -z "$url" ]; then
			say "could not read the releases of $repo; keeping ${current:-nothing}"
		elif [ "$(basename "$url" .tar.gz)" != "$current" ]; then
			name=$(basename "$url" .tar.gz)
			[ "$name" != "$bad_release" ] && [ "$name" != "$pending" ] &&
				[ "$name" != "$building" ] &&
				name=$(install "$url") || name=""
			if [ -n "$name" ]; then
				say "new version: $name"
				building=$name built=()
			fi
		fi
		[ -n "${AITTA:-}" ] && [ -n "$current" ] && follow_aitta
	fi
	# [SERVE_BUILDS] What waits on the build host, every pass
	[ -n "$building" ] && build_release
	[ -n "${app_building[*]:-}" ] && build_aitta
	update_when_quiet
	for i in "${!games[@]}"; do
		pid=${pids[$i]:-}
		if [ -n "$current" ] && [ "${broken[$i]:-}" != "$current" ] &&
				[ -z "${withdrawn[$i]:-}" ] &&
				{ [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; }; then
			if [ -n "$pid" ]; then
				wait "$pid" 2>/dev/null
				status=$?
				pids[$i]=""
				# 20 is a game's own restart, such as apps/vanilla
				# switching its world: again at once
				if [ "$status" = 20 ]; then
					say "${games[$i]} on port ${ports[$i]} restarts itself"
					standin_start "$i"
				else
					say "${games[$i]} on port ${ports[$i]} exited ($status); starting it again in 10 s"
					sleep 10
				fi
			fi
			start "$i"
		fi
		standin_check "$i"
	done
	# Quicker while a stand-in waits for its server
	if [ -n "$(printf '%s' "${standins[@]:-}")" ]; then
		sleep 1
	else
		sleep 5
	fi
done
