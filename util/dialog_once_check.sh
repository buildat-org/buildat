#!/bin/bash
# tier: full
# cost: ~10 s (2026-10-29)
# covers: client/core/network/init.lua client/core/starport/init.lua client/core/aitta/init.lua
# One permission dialog an address, and none on Home for an expired yes.
#   1. A stand-in Starport/Aitta/Hearth the user accepted 8 days ago (past
#      network's week): Home's fetches (the feed, Starport's list, Aitta's
#      newest) leave it out rather than ask; Home asked twice before, one
#      dialog over the other.
#   2. Apps from Aitta with two Aittas on that host: two asks, one dialog;
#      one Accept answers both, stored as accepted. Two dialogs, the lower
#      one answered took the other down with it, which was declined and
#      stored so, or failed on its removed field (play.buildat.org,
#      2026-10-29).
#   util/dialog_once_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp dialog_once; t=$CHECK_TMP
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here/Build"

cat > "$t/fake.py" <<'PY'
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
	def do_GET(self):
		path = self.path.split("?")[0]
		v = {"ok": True, "releases": []} if path.endswith("/aitta/list") else \
			{"ok": True, "servers": []}
		body = json.dumps(v).encode()
		self.send_response(200)
		self.send_header("Content-Type", "application/json")
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)
	def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print("port", s.server_address[1], flush=True)
s.serve_forever()
PY
mkdir -p "$t/cl"
python3 -I "$t/fake.py" > "$t/fake.log" 2>&1 &
CHECK_PIDS+=($!)
wait_for_log "$t/fake.log" "^port " 10 || fail "the stand-in ($t/fake.log)"
F=http://127.0.0.1:$(awk '/^port /{print $2}' "$t/fake.log")
printf '{"starports": ["%s"], "aittas": ["%s", "%s/b"], "hearth": "%s"}\n' \
	"$F" "$F" "$F" "$F" > "$t/cl/starport.json"
old=$(( $(date +%s) - 8 * 86400 ))
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","%s","stand-in","%s","%s","","",""\n' \
	"$F" $old $old > "$t/cl/network_addresses.csv"

cat > "$t/cmds" <<C
wait_log_any 30000 rows in
text apps from aitta
wait_log 10000 rows for "apps from aitta" in
keypress Return
wait_log 10000 Asking the user about $F
frames 3
keypress Return
wait_log 5000 The user accepted $F
frames 3
quit
C
run_client 30 "$t/cl.log" env BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9 \
	timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -C "$t/cl.cache" \
	-w 1000x700 -l 3 -o sound_mute=1 -c @"$t/cmds" ||
	fail "the drive: $(grep -a "Command sequence failed" "$t/cl.log" | tail -1) ($t/cl.log)"
# The client's own lines, not the drive's echo of them
said(){ grep -a "I extensio: $1" "$t/cl.log"; }
asked=$(grep -an "I extensio: Asking the user about $F" "$t/cl.log" | head -1 | cut -d: -f1)
opened=$(grep -an "command: keypress Return" "$t/cl.log" | head -1 | cut -d: -f1)
[ -n "$asked" ] && [ "$asked" -gt "$opened" ] ||
	fail "Home asked before Apps from Aitta was opened ($t/cl.log)"
n=$(said "The user accepted $F" | wc -l)
[ "$n" = 1 ] || fail "$n accepts for one Return ($t/cl.log)"
grep -a "while it was up\|taken down\|The user declined" "$t/cl.log" &&
	fail "a dialog was taken down or declined ($t/cl.log)"
n=$(said "Asking the user about $F" | wc -l)
[ "$n" = 2 ] || fail "$n asks, not the two Aittas' ($t/cl.log)"
grep -q "\"true\",\"$F\"" "$t/cl/network_addresses.csv" ||
	fail "not stored as accepted ($t/cl/network_addresses.csv)"
echo "PASS: no dialog on Home for a week-old yes; two asks for one address, one dialog, one Accept for both"
