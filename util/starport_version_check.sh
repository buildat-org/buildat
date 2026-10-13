#!/bin/bash
# tier: full
# cost: 75s (2026-10-09)
# covers: client/extensions/starport/init.lua apps/starport/main/main.cpp util/starport_version_github.py src/client/app_lua.h src/impl/linux/process.cpp extensions/launch_menu/init.lua
# [VERSION_CHECK]: a Starport whose version adapter says 0.9.0 carries it
# in /api/v1/list, filtered (a bad platform left out); the launcher shows the
# notice, "Not now" is kept across a restart, a newer version (0.9.1) is
# told again, and "Download" hands the platform's link to the system's
# opener (an xdg-open of this check's own on PATH).
# [VERSION_DOWNLOAD]: after it the amber text names the file (a .tar.gz's
# says extract, an .exe's run) and "Close Buildat" ends the client.
# The GitHub adapter prints the newest release, when GitHub answers.
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_spver.XXXXXX")
SP=29681
export BUILDAT_CONNECT_PORTS="$SP"
pid=
cleanup() {
	[ -n "$pid" ] && kill "$pid" 2>/dev/null
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
cd "$here"

starport() { # version [linux file]
	[ -n "$pid" ] && kill "$pid" && wait "$pid" 2>/dev/null
	mkdir -p "$tmp/sp/apps/starport"
	cat > "$tmp/sp/apps/starport/version_adapter" <<A
#!/bin/sh
echo "a warning on stderr" >&2
echo '{"version": "$1", "url": "https://example.org/releases",
 "platforms": {"linux": {"url": "https://example.org/${2:-linux-$1.tar.gz}"},
  "win64": {"url": "http://example.org/insecure"}, "bad name": {"url": "https://x"}}}'
A
	chmod +x "$tmp/sp/apps/starport/version_adapter"
	Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -P $SP -l 3 \
		>> "$tmp/sp.log" 2>&1 &
	pid=$!
	for _ in $(seq 300); do
		curl -s -m 2 "localhost:$SP/api/v1/list" | grep -q "\"version\":{.*$1" && return
		kill -0 $pid 2>/dev/null || break
		sleep 0.2
	done
	fail "/api/v1/list has no version $1 (sp.log)"
}
starport 0.9.0
curl -s -m 10 "localhost:$SP/api/v1/list" | python3 -c '
import json, sys
v = json.load(sys.stdin)["version"]
assert v == {"version": "0.9.0", "url": "https://example.org/releases",
	"platforms": {"linux": {"url": "https://example.org/linux-0.9.0.tar.gz"}}}, v
' || fail "/api/v1/list's version not as filtered"
echo "ok: /api/v1/list carries the adapter's answer, filtered"

mkdir -p "$tmp/cl" "$tmp/bin"
echo "{\"starports\": [\"http://127.0.0.1:$SP\"]}" > "$tmp/cl/starport.json"
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","Starport","%s","%s","","",""\n' \
	$SP $(date +%s) $(date +%s) > "$tmp/cl/network_addresses.csv"
printf '#!/bin/sh\necho "$@" > %s/opened\n' "$tmp" > "$tmp/bin/xdg-open"
chmod +x "$tmp/bin/xdg-open"
launcher() { # cmds log
	PATH="$tmp/bin:$PATH" BUILDAT_STARPORT_OFFER=1 timeout 120 Build/bin/buildat \
		-o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 4 \
		-o sound_mute=1 -c @"$1" > "$2" 2>&1
}
# The delays of a second at most are settles after a line: the window it
# says is up drawn and laid out in the frames after it
cat > "$tmp/c1" <<C
wait_log_any 30000 Offering version 0.9.0
delay 1000
screenshot $tmp/notice.png
click Button "Not now"
wait_log 5000 Version: not now, 0.9.0 kept
quit
C
launcher "$tmp/c1" "$tmp/cl1.log" || fail "the drive ($tmp/cl1.log)"
grep -q "Offering version 0.9.0 (https://example.org/linux-0.9.0.tar.gz" "$tmp/cl1.log" ||
	fail "no notice, or not the platform's link ($tmp/cl1.log)"
grep -q '"version_not_now":"0.9.0"' "$tmp/cl/starport.json" ||
	fail "Not now not kept ($tmp/cl1.log)"
echo "ok: the notice with this platform's link; Not now kept"

# The list in, and the notice not shown at the 0.5 s it is looked at
printf 'wait_log_any 30000 servers listed\nwait_log_absent 2000 Offering version\nquit\n' > "$tmp/c2"
launcher "$tmp/c2" "$tmp/cl2.log" || fail "the drive ($tmp/cl2.log)"
grep -v " __app   : " "$tmp/cl2.log" | grep -q "Offering version" && fail "0.9.0 told again after Not now"
echo "ok: not told again"

starport 0.9.1
cat > "$tmp/c3" <<C
wait_log_any 30000 Offering version 0.9.1
delay 1000
click Button "Download"
wait_log 5000 Version link
delay 1000
screenshot $tmp/next.png
click Button "Close Buildat"
# The window in which the client must end: Close Buildat ends it, so this
# costs nothing when it does
delay 10000
C
launcher "$tmp/c3" "$tmp/cl3.log"
rc=$?
[ "$(cat "$tmp/opened" 2>/dev/null)" = "https://example.org/linux-0.9.1.tar.gz" ] ||
	fail "Download did not open the link ($tmp/cl3.log)"
grep -q "Version next: .*extract linux-0.9.1.tar.gz and run bin/buildat.*they are in $tmp/cl," "$tmp/cl3.log" ||
	fail "the next steps: $(grep "Version next" "$tmp/cl3.log")"
# 1: a scripted client that ends before its sequence does says so
[ $rc = 1 ] && grep -q "Version: closing for the update" "$tmp/cl3.log" &&
	grep -q "Succesful shutdown" "$tmp/cl3.log" ||
	fail "Close Buildat did not end it ($rc, $tmp/cl3.log)"
echo "ok: a newer version told again; Download opened its link, said to extract it, Close Buildat closed"

starport 0.9.2 buildat-0.9.2-setup.exe
cat > "$tmp/c3b" <<C
wait_log_any 30000 Offering version 0.9.2
delay 1000
click Button "Download"
wait_log 5000 Version next
delay 500
quit
C
launcher "$tmp/c3b" "$tmp/cl3b.log" || fail "the drive ($tmp/cl3b.log)"
grep -q "Version next: .*close Buildat and run buildat-0.9.2-setup.exe: it updates" "$tmp/cl3b.log" ||
	fail "an .exe's next steps: $(grep "Version next" "$tmp/cl3b.log")"
echo "ok: an .exe's text"

# [WIN_OPEN]: no opener on PATH is a failure, said on the notice, which
# stays; Settings' "Open the log folder" hands the opener the log's folder
rm -f "$tmp/opened"
mkdir -p "$tmp/none"
cat > "$tmp/c4" <<C
wait_log_any 30000 Offering version 0.9.2
delay 1000
click Button "Download"
wait_log 5000 Version link
delay 500
screenshot $tmp/failed.png
click Button "Not now"
wait_log 5000 Version: not now, 0.9.2 kept
quit
C
BUILDAT_STARPORT_OFFER=1 timeout 120 env PATH="$tmp/none" Build/bin/buildat \
	-o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 4 \
	-o sound_mute=1 -c @"$tmp/c4" > "$tmp/cl4.log" 2>&1
grep -q "Version link: the system's opener could not be run" "$tmp/cl4.log" ||
	fail "no opener, and not said ($tmp/cl4.log)"
grep -q 'command: click Button "Not now"' "$tmp/cl4.log" &&
	! grep -q "Command sequence failed" "$tmp/cl4.log" ||
	fail "the notice closed on a failed open ($tmp/cl4.log)"
cat > "$tmp/c5" <<C
wait_log_any 20000 rows in
delay 1000
click Button "Settings"
wait_log 5000 launch_menu: settings,
delay 300
click Button "Logs and errors"
wait_log 5000 launch_menu: logs shown
delay 300
click Button "Open the log folder"
wait_log 5000 launch_menu: logs: Opened
quit
C
launcher "$tmp/c5" "$tmp/cl5.log" || fail "the drive ($tmp/cl5.log)"
# The opener is a process of its own: its file, or a second gone
for _ in $(seq 5); do [ -s "$tmp/opened" ] && break; sleep 0.2; done
opened=$(cat "$tmp/opened" 2>/dev/null)
[ -n "$opened" ] && [ -d "$opened" ] ||
	fail "Open the log folder opened \"$opened\" ($tmp/cl5.log)"
echo "ok: no opener said and the notice kept; the log folder opened"

if out=$(timeout 60 util/starport_version_github.py 2>&1); then
	echo "$out" | python3 -c '
import json, re, sys
v = json.load(sys.stdin)
assert re.match(r"^\d+(\.\d+)+$", v["version"]) and v["url"].startswith("https://"), v
' || fail "the GitHub adapter printed $out"
	echo "ok: the GitHub adapter: $(echo "$out" | cut -c1-60)..."
else
	echo "skipped: the GitHub adapter (no answer: $(echo "$out" | tail -1))"
fi
echo "PASS"
