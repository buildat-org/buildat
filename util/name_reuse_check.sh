#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-27)
# covers: builtin/accounts/accounts.cpp apps/vanilla/main/main.cpp apps/vanilla/main/client_lua/join.lua
# [GUEST_NAME_REUSE]: a game keeps its saves by player name, so a name
# given out again after a restart hands someone the earlier player's.
#   - vanilla on the launcher's server: its own client is singleplayer,
#     and again after a restart; a client without the owner's token (the
#     LAN's) gets the login page and is not placed; one logging in as
#     singleplayer is held; bob logging in plays as bob;
#   - [DELETED_NAME_REUSE]: bob deleted by the admin (SinglePlayer, by the
#     setup code), bob registered again is refused; the admin's add makes
#     it again;
#   - hillclimb's guests: a guest after a restart is not the guest
#     before it (builtin/accounts keeps the counter).
#   util/name_reuse_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp name_reuse; t=$CHECK_TMP
trap check_cleanup EXIT
bad=
stop(){ kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; }

# vanilla: serve <log> [args]
serve(){
	local log=$1; shift
	BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=w start_server "$log" \
		"The world is up" 180 auto "$here/Build/bin/buildat_server" "$@" \
		-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/v" -C "$t/vc" -l 3 ||
		fail "the vanilla server ($log)"
	CHECK_PIDS+=($SERVER_PID)
}
# drive <name> <cmds...>: a client of its own dirs; env BUILDAT_JOIN_*
drive(){
	local n=$1; shift
	printf '%s\n' "$@" quit > "$t/$n.cmds"
	run_client 60 "$t/$n.log" timeout 240 "$here/Build/bin/buildat" \
		-C "$t/cc_$n" -D "$t/cu_$n" -s 127.0.0.1:$SERVER_PORT -w 800x450 -u 1 \
		-l 3 -o sound_mute=1 -c @"$t/$n.cmds"
}
owner(){
	serve "$t/$1.log" -u launcher=1
	drive "$1c" "wait_log 120000 load: the world is in"
	stop
	grep -aq "luanti  : Player singleplayer joined" "$t/$1.log" ||
		bad="$bad; the owner not singleplayer ($t/$1.log, $t/$1c.log)"
}

owner v1
# The LAN's: an owner token no client here has
BUILDAT_OWNER_TOKEN=notthisclients serve "$t/v2.log" -u launcher=1
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/v2.log" | head -1)
drive lan_a "wait_log 60000 accounts: the login page shown" ||
	bad="$bad; no login page for a LAN client ($t/lan_a.log)"
BUILDAT_JOIN_NAME=SinglePlayer BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_CODE=$code drive lan_s "wait_log 60000 join: held: " ||
	bad="$bad; the host's name not held ($t/lan_s.log)"
BUILDAT_JOIN_NAME=bob BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1 \
	drive lan_b "wait_log 120000 load: the world is in" ||
	bad="$bad; bob not in ($t/lan_b.log)"
# admin <name> <script>: SinglePlayer's admin requests
admin(){
	BUILDAT_JOIN_NAME=SinglePlayer BUILDAT_JOIN_PASSWORD=checkpass12 \
		BUILDAT_JOIN_ADMIN="$2" drive "$1" "wait_log 60000 admin script: done"
}
admin del_b "delete bob" || bad="$bad; bob not deleted ($t/del_b.log)"
BUILDAT_JOIN_NAME=bob BUILDAT_JOIN_PASSWORD=otherpass12 BUILDAT_JOIN_CREATE=1 \
	drive lan_b2 "wait_log_any 60000 Login refused: " ||
	bad="$bad; no refusal for bob again ($t/lan_b2.log)"
grep -aq "Login refused: \"bob\" was a deleted account's" "$t/lan_b2.log" ||
	bad="$bad; a deleted name registered again ($t/lan_b2.log)"
admin add_b "add bob checkpass12" &&
	grep -aq "admin result: The account bob was added" "$t/add_b.log" ||
	bad="$bad; the admin's add of bob ($t/add_b.log)"
stop
# Who was placed: bob alone
placed=$(grep -aoP "luanti  : Player \K\S+(?= joined)" "$t/v2.log" | tr '\n' ' ')
[ "$placed" = "bob " ] || bad="$bad; placed on the LAN: $placed($t/v2.log)"
owner v3

# hillclimb's guests, by a raw peer's accounts:guest
hc(){
	start_server "$t/$1.log" "STATUS Listening" 300 auto env BUILDAT_HILLCLIMB_FEATURES=0 \
		BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9 "$here/Build/bin/buildat_server" \
		-A 127.0.0.1 -m "$here/apps/hillclimb" -D "$t/h" -C "$t/hc" -l 3 ||
		fail "the hillclimb server ($t/$1.log)"
	CHECK_PIDS+=($SERVER_PID)
	python3 - "$SERVER_PORT" "$t/$1.log" <<'PY'
import socket, struct, sys, time
def packet(t, data):
    return struct.pack("<HBI", t, 0, len(data)) + data
def hello():
    v = b"0.7.0"
    body = struct.pack("<IIQ", 1, 1, len(v)) + v + struct.pack("<IQ", 2, 0)
    return packet(2, b"\1\1\0" + bytes([len(body)]) + body)  # its length a one-byte varint
n = b"accounts:guest"
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(hello() + packet(0, bytes([100, 0]) + len(n).to_bytes(4, "little") + n) +
        packet(100, b""))
# Held until the server says it
t0 = time.time()
while time.time() - t0 < 20 and b"joined as a guest" not in open(sys.argv[2], "rb").read():
    time.sleep(0.2)
PY
	stop
	grep -aoP "joined as a guest, \Kguest\d+" "$t/$1.log"
}
g1=$(hc h1) g2=$(hc h2)
[ -n "$g1" ] && [ -n "$g2" ] || bad="$bad; no guest ($t/h1.log, $t/h2.log)"
[ "$g1" != "$g2" ] || bad="$bad; $g1 again after the restart"

[ -z "$bad" ] || fail "${bad#; }"
echo "PASS: singleplayer kept, LAN clients log in (bob, not the host's name); a deleted bob not registered again, the admin's add makes it; guests $g1 then $g2"
# vim: set noet ts=4 sw=4:
