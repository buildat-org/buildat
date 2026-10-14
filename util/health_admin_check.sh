#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-11)
# covers: builtin/network/network.cpp builtin/accounts/accounts.cpp
# [HEALTH_ADMIN]: /health's JSON says whether any account has the admin
# priv. A public vanilla server (no launcher param):
#   1. started with no admin: "admin": false;
#   2. a client takes the admin with the setup code: "admin": true, the
#      same run;
#   3. restarted: "admin": true.
#   util/health_admin_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp health_admin; t=$CHECK_TMP
trap check_cleanup EXIT
serve(){
	start_server "$1" "STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
		-m "$here/apps/vanilla" -D "$t/srv" -C "$t/cache" -l 3 || fail "the server ($1)"
	CHECK_PIDS+=($SERVER_PID)
}
admin(){ curl -s -m 5 "http://127.0.0.1:$SERVER_PORT/health" |
	python3 -c 'import json, sys; print(json.load(sys.stdin).get("admin"))'; }

# 1
serve "$t/1.log"
got=$(admin); echo "no admin: $got"
[ "$got" = False ] || fail "\"admin\" is $got with no admin"
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/1.log)"

# 2
printf 'wait_log 30000 Joined as\ndelay 500\nquit\n' > "$t/c.cmds"
BUILDAT_JOIN_NAME=boss BUILDAT_JOIN_PASSWORD=secret123 BUILDAT_JOIN_CREATE=1 \
BUILDAT_JOIN_CODE="$code" run_client 60 "$t/c.log" timeout 60 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -s "127.0.0.1:$SERVER_PORT" -D "$t/cu" -w 640x480 -u 1 \
	-l 3 -o sound_mute=1 -c @"$t/c.cmds"
grep -aq "Joined as boss" "$t/c.log" || fail "the setup code did not join ($t/c.log)"
got=$(admin); echo "the code used: $got"
[ "$got" = True ] || fail "\"admin\" is $got after the setup code"
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null

# 3
serve "$t/3.log"
got=$(admin); echo "restarted: $got"
[ "$got" = True ] || fail "\"admin\" is $got after a restart"
echo "PASS: /health says \"admin\": false until the setup code is used, true from then on and after a restart"
