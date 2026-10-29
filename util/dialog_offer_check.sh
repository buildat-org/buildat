#!/bin/bash
# tier: full
# cost: ~15 s (2026-10-29)
# covers: client/core/starport/init.lua client/core/network/init.lua client/core/urho3d/overlay.lua
# [DIALOG_OFFER_DECLINES]: a Starport's answer that offers an Aitta while
# the permission dialog is up waits for the user's answer, and its save
# keeps what another writer put in starport.json meanwhile.
#   1. A stand-in Starport and Aitta (one port), the launcher's default
#      Starport; its settings name the Aitta by another name (localhost),
#      so Apps from Aitta asks about it.
#   2. The stand-in holds /api/v1/list until the client logs the dialog,
#      then writes "version_not_now" into starport.json (as a second tab
#      or a drive would) and answers with a recommended Aitta.
#   3. The dialog stays up, the user accepts it, and only then is the
#      Aitta offered; closed, it is ignored. starport.json has the
#      stand-in's key, the recommendation and the ignored Aitta.
#   util/dialog_offer_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp dialog_offer; t=$CHECK_TMP
cd "$here/Build"

# 1.
cat > "$t/fake.py" <<'PY'
import http.server, json, os, sys, time
log, state = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
	def answer(self):
		path = self.path.split("?")[0]
		if path == "/api/v1/list":
			# 2. Held until the dialog is up (the client's run is
			# bounded by the check's timeout)
			while b"Asking the user about http://localhost" not in open(log, "rb").read():
				time.sleep(0.05)
			s = json.load(open(state))
			s["version_not_now"] = "9.9.9"
			json.dump(s, open(state + ".new", "w"))
			os.replace(state + ".new", state)
			v = {"ok": True, "servers": [],
				"recommends": {"aittas": ["http://127.0.0.1:9"]}}
		elif path == "/api/v1/aitta/list":
			v = {"ok": True, "releases": []}
		else:
			v = {"ok": False}
		body = json.dumps(v).encode()
		self.send_response(200)
		self.send_header("Content-Type", "application/json")
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)
	def do_GET(self): self.answer()
	def do_POST(self):
		self.rfile.read(int(self.headers.get("Content-Length") or 0))
		self.answer()
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print("port", s.server_address[1], flush=True)
s.serve_forever()
PY
mkdir -p "$t/cl"
: > "$t/cl.log"
python3 -I "$t/fake.py" "$t/cl.log" "$t/cl/starport.json" > "$t/fake.log" 2>&1 &
CHECK_PIDS+=($!)
wait_for_log "$t/fake.log" "^port " 10 || fail "the stand-in ($t/fake.log)"
F=http://127.0.0.1:$(awk '/^port /{print $2}' "$t/fake.log")
FL=${F/127.0.0.1/localhost}
printf '{"aittas": ["%s"], "hearth": ""}\n' "$FL" > "$t/cl/starport.json"

# 3.
cat > "$t/cmds" <<C
wait_log_any 30000 rows in
text apps from aitta
wait_log 10000 rows for "apps from aitta" in
keypress Return
wait_log 10000 Asking the user about $FL
wait_log_any 10000 Starport $F: 0 servers listed
# The overlay offers every half second
wait_log_absent 1000 Offering
keypress Return
wait_log 5000 The user accepted $FL
wait_log 5000 Offering 1 Aitta
keypress escape
wait_log 5000 Aittas offered: 1, not now
quit
C
run_client 30 "$t/cl.log" env BUILDAT_STARPORT_DEFAULT=$F BUILDAT_STARPORT_OFFER=1 \
	timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -C "$t/cl.cache" \
	-w 1000x700 -l 3 -o sound_mute=1 -c @"$t/cmds" ||
	fail "the drive: $(grep -a "Command sequence failed\|while it was up" "$t/cl.log" | tail -2) ($t/cl.log)"
grep -a "while it was up" "$t/cl.log" && fail "the dialog was declined ($t/cl.log)"
python3 - "$t/cl/starport.json" "$F" <<'PY' || fail "starport.json ($t/cl/starport.json)"
import json, sys
s = json.load(open(sys.argv[1]))
assert s.get("version_not_now") == "9.9.9", "the other writer's key lost"
assert s["recommends"][sys.argv[2]]["aittas"] == ["http://127.0.0.1:9"], s["recommends"]
assert s["ignored_aittas"] == ["http://127.0.0.1:9"], s["ignored_aittas"]
PY
echo "PASS: the offer waited for the dialog's answer, and starport.json kept the other write"
