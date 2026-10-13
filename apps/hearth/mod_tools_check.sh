#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-09)
# covers: apps/hearth/main/** builtin/accounts/accounts.cpp
# [HEARTH_MOD_TOOLS]: on a local Hearth, a moderator (mia), a helper (hal),
# a member (mem) and a new account (neo) with an image in thread 1.
#   1. The message's action row ("hearth: action" lines): the member sees
#      no tool; the helper "Show images to everyone", which shows them and
#      turns to "Hide images from everyone"; the moderator Delete... and
#      Ban... on a member's or a new account's message; a helper's has
#      Delete... only.
#   2. The moderator's Delete... (the dialog driven): the message's place
#      says "Deleted by", the author is told, appeals, and the appeal
#      restores it; Delete of a thread's first message hides the thread.
#   3. Ban... for a day (the dialog driven): neo's join is refused with the
#      reason and the end; a day on (the server's sim clock) let in. A
#      helper is not banned, and a member deletes and bans nothing.
# Screenshots of the row and the two dialogs in $t (KEEP_TMP=1 keeps it).
#
#   apps/hearth/mod_tools_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp hearth_mod_tools; t=$CHECK_TMP

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 auto \
	bin/buildat_server --sim-clock -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

# commands Q: until each request is answered, and the admin script's
client(){ # name log requests commands [env...]
	local n=$1 log=$2 reqs=$3 i=0 w
	if [ "$4" = Q ]; then
		while IFS= read -r w; do
			[ -n "$w" ] && i=$((i + 1)) && echo "wait_log_any 20000 \"id\":$((1000 + i)),"
		done <<< "$reqs"
		case "${*:5}" in *BUILDAT_HEARTH_ADMIN=*)
			echo "wait_log_any 20000 admin script: done";; esac
		echo quit
	else
		printf "$4"
	fi > "$t/cmds_$n"
	shift 4
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=${n}pass1234 \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" \
		-w 900x700 -l 3 -o sound_mute=1 -s 127.0.0.1:$P \
		-c @"$t/cmds_$n" > "$log" 2>&1 ||
		fail "the client $n ($log): $(grep -a "Command sequence failed" "$log" | tail -1)"
}
Q=Q
# Thread 1 open: its page, drawn with every message's actions
T='wait_log_any 20000 hearth: page My lamp\ndelay 500\n'
answer(){ grep -ao "hr: {.*\"id\":$2,.*" "$1" | head -1; }
num(){ answer "$1" $2 | grep -o '"result":[0-9]*' | cut -d: -f2; }
ok(){ answer "$1" $2 | grep -q '"ok":true' || fail "$3: $(answer "$1" $2 | head -c 300)"; }
acts(){ # log message: its actions, one a line
	grep -a "hearth: action m$2 " "$1" | grep -av "command: \|wait_log: " |
		sed "s/.*hearth: action m$2 //" | sort -u
}
has(){ echo "$1" | grep -qx "$2"; }

client admin "$t/admin.log" '{"cmd":"new_topic","name":"Help"}' "$Q" \
	"BUILDAT_HEARTH_ADMIN=add mia miapass1234
level mia 30
add hal halpass1234
level hal 20
add mem mempass1234
level mem 10
add neo neopass1234"
ok "$t/admin.log" 1001 "the topic"
png=89504e470d0a1a0a0000000d49484452000000030000000208060000009d74661a0000001149444154789c63687050f80fc30cc81c008df50b3be56bccc90000000049454e44ae426082
client neo "$t/neo.log" "{\"cmd\":\"upload\",\"name\":\"one.png\",\"data\":\"$png\"}" "$Q"
I=$(answer "$t/neo.log" 1001 | grep -o '"result":{.*' | grep -o '"id":[0-9]*' | cut -d: -f2)
[ -n "$I" ] || fail "neo's upload: $(answer "$t/neo.log" 1001)"
client neo "$t/neo2.log" "{\"cmd\":\"new_thread\",\"topic\":1,\"title\":\"My lamp\",\"body\":\"look [![one.png](/f/$I/thumb)](/f/$I/one.png)\"}
{\"cmd\":\"new_thread\",\"topic\":1,\"title\":\"Cheap pills\",\"body\":\"buy now\"}" "$Q"
T1=$(num "$t/neo2.log" 1001); T2=$(num "$t/neo2.log" 1002)
[ -n "$T1" ] && [ -n "$T2" ] || fail "neo's threads: $(answer "$t/neo2.log" 1001)"
client neo "$t/neo3.log" "{\"cmd\":\"reply\",\"thread\":$T1,\"body\":\"and again\"}" "$Q"
client mem "$t/mem.log" "{\"cmd\":\"reply\",\"thread\":$T1,\"body\":\"a member's reply\"}" "$Q"
client hal "$t/hal.log" "{\"cmd\":\"reply\",\"thread\":$T1,\"body\":\"a helper's reply\"}
{\"cmd\":\"thread\",\"thread\":$T1}" "$Q"
ids=$(answer "$t/hal.log" 1002 | grep -o '"id":[0-9]*,"patches"' | cut -d: -f2 | cut -d, -f1)
set -- $ids
[ $# = 4 ] || fail "thread $T1's messages: $ids"
M1=$1 M2=$2 M3=$3 M4=$4

# 1. The action rows
client mem "$t/mem_row.log" "" "${T}quit\n" BUILDAT_HEARTH_OPEN="$T1#$M1"
a=$(acts "$t/mem_row.log" $M1)
[ -n "$a" ] || fail "no actions logged for the member"
echo "$a" | grep -q "images\|Delete\|Ban" && fail "a member's tools: $a"
client hal "$t/hal_row.log" "" "${T}screenshot $t/hal.png\nclick Button \"Show images to everyone\"\nwait_log 10000 hearth: action m$M1 Hide images from everyone\nquit\n" \
	BUILDAT_HEARTH_OPEN="$T1#$M1"
a=$(acts "$t/hal_row.log" $M1)
has "$a" "Show images to everyone" && has "$a" "Hide images from everyone" ||
	fail "the helper's images button: $a"
echo "$a" | grep -q "Delete\|Ban" && fail "a helper's Delete or Ban: $a"
curl -s "http://127.0.0.1:$P/t/$T1" | grep -q "<img src=\"/f/$I/" ||
	fail "the image not shown to everyone"
# A reason picked draws the dialog again; the moderator's own request is
# answered with ok
# The page comes before its rows' action buttons: the row's own
# "action mN Delete..." line, and the 300 ms its button drawn.
# A moderator's first login is asked about ntfy in a window over the
# thread ([NTFY_ASK_OVER_GAME]), and closing it leaves no message
# selected: Don't add in a login of its own, so mia's runs click the thread
NTFY='wait_log_any 20000 server window: the page ntfy\ndelay 300\nclick Button "Don'"'"'t add"\nwait_log 5000 server window: closed\n'
# The second before quit is the answer's packet sent (no answer comes back)
client mia "$t/mia_ntfy.log" "" "${NTFY}delay 1000\nquit\n"
client mia "$t/mia_row.log" "" "${T}wait_log_any 10000 Delete...\ndelay 300\nscreenshot $t/row.png\nclick Button \"Delete...\"\nwait_log 10000 hearth: page Delete\ndelay 500\nclick Button \"Spam\"\nwait_log 5000 hearth: page Delete\ndelay 500\nscreenshot $t/delete.png\nclick Button \"Delete\"\nwait_log 10000 \"ok\":true\nquit\n" \
	BUILDAT_HEARTH_OPEN="$T1#$M2"
a=$(acts "$t/mia_row.log" $M2)
has "$a" "Delete..." && has "$a" "Ban..." || fail "the moderator's tools: $a"
a=$(acts "$t/mia_row.log" $M4)
has "$a" "Delete..." && ! has "$a" "Ban..." ||
	fail "the moderator's tools on a helper's message: $a"
a=$(acts "$t/mia_row.log" $M3)
has "$a" "Delete..." && has "$a" "Ban..." || fail "on a member's message: $a"

# 2. Deleted, told, appealed, restored; a thread's first message
curl -s "http://127.0.0.1:$P/t/$T1" > "$t/page"
grep -q "Deleted by a [A-Za-z]*: Spam" "$t/page" && ! grep -q "and again" "$t/page" ||
	fail "the deleted message's place: $(grep -a -o 'class="box[^<]*<p class="meta">[^<]*' "$t/page" | head -5)"
client neo "$t/neo_appeal.log" '{"cmd":"notifications"}'"
{\"cmd\":\"appeal\",\"message\":$M2,\"text\":\"it was a joke\"}" "$Q"
answer "$t/neo_appeal.log" 1001 | grep -q '"kind":"deleted".*"note":"Spam"' ||
	fail "neo was not told: $(answer "$t/neo_appeal.log" 1001 | head -c 300)"
R=$(num "$t/neo_appeal.log" 1002)
[ -n "$R" ] || fail "the appeal: $(answer "$t/neo_appeal.log" 1002)"
client mia "$t/mia_restore.log" "{\"cmd\":\"moderate\",\"report\":$R,\"action\":\"restore\",\"statement\":\"fine\"}" "$Q"
ok "$t/mia_restore.log" 1001 "the restore"
curl -s "http://127.0.0.1:$P/t/$T1" | grep -q "and again" || fail "the appeal did not restore it"
# Thread 2's first message: the whole thread
client mia "$t/mia_list.log" "{\"cmd\":\"thread\",\"thread\":$T2}" "$Q"
F2=$(answer "$t/mia_list.log" 1001 | grep -o '"id":[0-9]*,"patches"' | head -1 | cut -d: -f2 | cut -d, -f1)
client mia "$t/mia_del2.log" "{\"cmd\":\"delete\",\"message\":$F2,\"reason\":\"Spam\",\"text\":\"pills\"}" "$Q"
ok "$t/mia_del2.log" 1001 "the thread's delete"
curl -s "http://127.0.0.1:$P/" | grep -q "Cheap pills" && fail "the deleted thread is listed"

# 3. Ban... for a day, from the dialog
client mia "$t/mia_ban.log" "" "${T}click Button \"Ban...\"\nwait_log 10000 hearth: page Ban\ndelay 500\nclick Button \"Spam\"\nwait_log 5000 hearth: page Ban\ndelay 500\nscreenshot $t/ban.png\nclick Button \"Ban\"\nwait_log 10000 \"ok\":true\nquit\n" \
	BUILDAT_HEARTH_OPEN="$T1#$M1"
client neo "$t/neo_banned.log" '{"cmd":"me"}' 'expect_error Disconnected from server\nwait_log_any 20000 Login refused\nquit\n' 
grep -a "Login refused" "$t/neo_banned.log" | grep -aq "until 20[0-9-]* [0-9:]* UTC: Spam" ||
	fail "neo's refusal: $(grep -a 'Login refused' "$t/neo_banned.log" | head -2)"
client mia "$t/mia_ban2.log" '{"cmd":"ban","name":"hal","days":1,"reason":"Spam","text":""}' "$Q"
answer "$t/mia_ban2.log" 1001 | grep -q "not banned here" ||
	fail "a helper banned: $(answer "$t/mia_ban2.log" 1001)"
client mem "$t/mem_tools.log" "{\"cmd\":\"delete\",\"message\":$M4,\"reason\":\"Spam\",\"text\":\"\"}
{\"cmd\":\"ban\",\"name\":\"neo\",\"days\":0,\"reason\":\"Spam\",\"text\":\"\"}" "$Q"
answer "$t/mem_tools.log" 1001 | grep -q "only a [A-Za-z]* deletes" &&
	answer "$t/mem_tools.log" 1002 | grep -q "only a [A-Za-z]* bans" ||
	fail "a member's delete or ban: $(answer "$t/mem_tools.log" 1001)"
echo 86460 > "$t/srv/sim_clock"
for _i in $(seq 100); do
	grep -aq "sim clock: 86460s ahead" "$t/srv.log" && break
	sleep 0.1
done
client neo "$t/neo_back.log" '{"cmd":"me"}' "$Q"
grep -aq "Login refused" "$t/neo_back.log" && fail "neo still refused a day on"
ok "$t/neo_back.log" 1001 "neo a day on"
echo "PASS: the member's row has no tools, the helper's images button flips them, the moderator's Delete and Ban; deleted, told, appealed, restored; a thread deleted; banned with the reason and end, let in a day on (see $t/row.png, delete.png, ban.png)"
