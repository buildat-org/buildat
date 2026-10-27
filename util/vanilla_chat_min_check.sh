#!/bin/bash
# tier: full
# cost: ~4 min (2026-10-17)
# covers: builtin/chat/chat.cpp builtin/chat/api.h builtin/luanti/session.h apps/vanilla/main/main.cpp apps/vanilla/main/client_lua/pause.lua apps/vanilla/main/client_lua/join.lua
# [VANILLA_CHAT_MIN]: vanilla's chat is builtin/chat's "who may talk",
# Residents and up by default on a public server, everyone in a LAN game.
# On the minimal game:
#   - the launcher's server: a Guest (a client not the owner's, in by the
#     login since [GUEST_NAME_REUSE]) talks;
#   - public, no world: a Guest's lobby line (the held page's Chat...)
#     is refused;
#   - public with the world: a Guest's line is refused, its /privs runs;
#     the admin picks "Guests and up" in the pause menu (the audit log has
#     chat_min);
#   - started again: the Guest's line is said, the setting kept.
# simplified: a Resident's line and a helper's refused set_min are
# builtin/chat's rule as before; skeldat's default (everyone) is its
# check's chat
#   util/vanilla_chat_min_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp vanilla_chat_min; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/u
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
# serve <log> [args]: vanilla (a public server's world is its
# public_world, none at first)
serve(){
	local log=$1; shift
	start_server "$log" \
		"STATUS Listening" 120 $PORT "$here/Build/bin/buildat_server" "$@" \
		-A 127.0.0.1 -m "$here/apps/vanilla" -D "${D:-$d}" -C "$t/c" -l 3 ||
		fail "the server ($log)"
	CHECK_PIDS+=($SERVER_PID)
}
stop(){ kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; }
# A client's own lines, not the drive's commands that quote them
said(){ grep -av "command: \|wait_log" "$1"; }
# In the world, a chat line typed: say <text> <wait for>
say(){ printf 'keypress T\nwait_log 5000 chat: the line opened\ntext %s\nkeypress Return\nwait_log 10000 %s\n' "$1" "$2"; }

# The launcher's own server: a Guest talks (an owner token the client
# has not: without one any client from this machine is the owner). Its
# accounts of its own: the admin the setup code makes there, then the
# Guest
BUILDAT_OWNER_TOKEN=notthisclients BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=w \
	D=$t/lan serve "$t/lan.log" -u launcher=1
wait_for_log "$t/lan.log" "The world is up" 120 || fail "the LAN world ($t/lan.log)"
lan_code=$(grep -ao "setup code [A-Z0-9]*" "$t/lan.log" | head -1 | cut -d' ' -f3)
printf 'wait_log_any 60000 Joined as\nquit\n' > "$t/lana.cmds"
BUILDAT_JOIN_NAME=lanadmin BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_CODE=$lan_code run_client 60 "$t/lana.log" timeout 240 \
	"$here/Build/bin/buildat" -C "$t/lcc" -D "$t/lau" -s 127.0.0.1:$PORT \
	-w 800x450 -u 1 -l 3 -o sound_mute=1 -c @"$t/lana.cmds" ||
	fail "the LAN admin's drive ($t/lana.log)"
{ echo "wait_log_any 60000 the world is in"; echo "delay 1000"
	say "hello on the lan" "<languest> hello on the lan"; echo quit; } > "$t/lan.cmds"
BUILDAT_JOIN_NAME=languest BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1 \
	run_client 60 "$t/lanc.log" timeout 240 "$here/Build/bin/buildat" -C "$t/lcc" -D "$t/lcu" \
	-s 127.0.0.1:$PORT -w 800x450 -u 1 -l 3 -o sound_mute=1 -c @"$t/lan.cmds" ||
	fail "the LAN guest's drive ($t/lanc.log: $(grep -a "Command sequence failed" "$t/lanc.log" | tail -1))"
stop
# The world the public starts below play
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=w serve "$t/w.log" -u launcher=1
wait_for_log "$t/w.log" "The world is up" 120 || fail "the world ($t/w.log)"
stop
! grep -aq "line refused" "$t/lan.log" || fail "a LAN guest refused ($t/lan.log)"
echo "  a LAN game's Guest talks"
echo "enable_damage = false" >> "$d/apps/vanilla/saves/w/luanti/world.mt"

# join <name> <create> <code> <log> <cmds>: by the launcher's connect
# screen, as util/vanilla_stop_check.sh
join(){
	{ printf 'wait_log_any 20000 Join a Buildat server: shown\nclick LineEdit "29500"\ndelay 300\nkeypress End\n'
		printf 'keypress Backspace\n%.0s' 1 2 3 4 5
		printf 'text %s\ndelay 300\nclick Button "Join"\n' $PORT
		cat "$5"; } > "$5.full"
	BUILDAT_JOIN_NAME=$1 BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=$2 \
		BUILDAT_JOIN_CODE=$3 timeout 300 "$here/Build/bin/buildat" -o launch_ui=launch_menu \
		-a extension/launch_menu/connect -D "$t/cl_$1" -C "$t/cc_$1" -w 1100x800 -u 1 -l 3 \
		-o sound_mute=1 -c @"$5.full" > "$4" 2>&1 ||
		fail "$1's drive ($4: $(grep -a "Command sequence failed" "$4" | tail -1))"
}

# Public, no world chosen: the admin's account, then the Guest's line in
# the lobby
serve "$t/p1.log"
wait_for_log "$t/p1.log" "setup code" 60 || fail "the public server ($t/p1.log)"
code=$(grep -ao "setup code [A-Z0-9]*" "$t/p1.log" | head -1 | cut -d' ' -f3)
printf 'wait_log 30000 accounts: ntfy asked\ndelay 1500\nclick Button "Don'"'"'t add"\ndelay 1500\nquit\n' > "$t/a0.cmds"
join admin 1 "$code" "$t/a0.log" "$t/a0.cmds"
cat > "$t/u1.cmds" <<C
wait_log 60000 join: held:
delay 1000
click Button "Chat..."
wait_log 10000 chat page: y
delay 500
text hello in the lobby
keypress Return
wait_log 10000 join: chat: (The chat is for Residents and up now.)
quit
C
join user 1 "" "$t/u1.log" "$t/u1.cmds"
stop
grep -aq "user's line refused: The chat is for Residents and up now." "$t/p1.log" ||
	fail "the lobby line not refused ($t/p1.log)"
echo "  a public lobby's Guest refused"

# Public with the world: refused, /privs runs; the admin opens the chat
echo w > "$d/apps/vanilla/public_world"
serve "$t/p2.log"
wait_for_log "$t/p2.log" "The world is up" 120 || fail "no world ($t/p2.log)"
{ echo "wait_log 60000 the server put the player at"
	echo "wait_log 60000 chat: *** user joined the game"; echo "delay 500"
	say "hello as a guest" "chat: The chat is for Residents and up now."
	say "/privs" "chat: Privileges of user"; echo quit; } > "$t/u2.cmds"
join user 0 "" "$t/u2.log" "$t/u2.cmds"
cat > "$t/a1.cmds" <<C
wait_log 60000 the server put the player at
delay 1500
keypress Escape
wait_log 10000 pause: the menu shown
delay 500
click DropDownList "▼"
wait_log 5000 dropdown_
click Text "Guests and up"
wait_log 10000 chat: *** Chat is for Guests and up now
quit
C
join admin 0 "" "$t/a1.log" "$t/a1.cmds"
stop
grep -aq "admin: the lowest level that may talk is everyone" "$t/p2.log" ||
	fail "the admin's pick ($t/p2.log)"
grep -raq "chat_min" "$d" || fail "no chat_min in the audit log ($d)"
echo "  a world's Guest refused, its /privs run; the admin picks Guests and up"

# Started again: the Guest talks
serve "$t/p3.log"
wait_for_log "$t/p3.log" "The world is up" 120 || fail "no world ($t/p3.log)"
{ echo "wait_log 60000 the server put the player at"
	echo "wait_log 60000 chat: *** user joined the game"; echo "delay 500"
	say "hello again" "<user> hello again"; echo quit; } > "$t/u3.cmds"
join user 0 "" "$t/u3.log" "$t/u3.cmds"
stop
! grep -aq "line refused" "$t/p3.log" || fail "refused after the restart ($t/p3.log)"
echo "PASS: vanilla's chat for Residents and up on a public server, everyone on a LAN, an admin's pick kept"
