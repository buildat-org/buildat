#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-19)
# covers: builtin/kit/client_lua/editor.lua builtin/kit/client_lua/signals.lua extensions/ui_utils/init.lua extensions/ui_utils/res/style.xml
# (kit_plan 4z37h) Kit's editor at a phone's portrait size (412x915, the
# desktop mode), Brimstone Speedway new from its template:
#   1. the Entities list: no scroll bar across it (each row's name cut
#      with "..." to the palette's width; the generator's long line made
#      one on a phone), the generator a row to pick (no Run there: the
#      inspector's), picked (entities.png, inspector.png);
#   2. the inspector left with an edit not applied (its seed typed): Play
#      mode asks Save / Discard / Cancel; Cancel keeps the editor and the
#      edit, Discard drops it and goes, Save sends it and goes.
# Screenshots, kept with KEEP_TMP=1: $t/entities.png, $t/inspector.png,
# $t/ask.png
#   util/kit_phone_entity_list_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_phone_entity_list; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build
G=$(python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
print([e["id"] for e in d["entities"] if any(c["type"] == "local/brim_yard"
	for c in e.get("components", []))][0])' \
		"$here/apps/workbench/templates/brimstone_speedway/composition.json") ||
	fail "no generator in the template"
sock=buildat-phone-$$
weston --backend=headless --renderer=pixman --xwayland --socket=$sock \
	--width=600 --height=1000 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
seed() # the seed's field: a 6 typed after its last digit
{
	printf '%s\n' 'click LineEdit "1955*"' "frames 2" "keypress End" "text 6" "frames 3"
}
{
	cat <<EOF
wait_log_any 120000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don*"
wait_log_any 30000 world_menu: the list shown
frames 3
click Button "New game..."
wait_log 10000 world_menu: the name screen shown
frames 3
click DropDownList "▼"
delay 300
frames 3
click Text "Brimstone Speedway"
wait_log 10000 world_menu: template picked
frames 3
click Button "Create"
wait_log 120000 kit editor: edit mode on
frames 10
click Button "Tools"
frames 5
click Button "Entities*"
wait_log 10000 kit editor: list
frames 20
screenshot $t/entities.png
click Button "generator $G"
wait_log 10000 kit editor: selected $G
click Button "Tools"
frames 3
click Button "Inspector"
frames 10
screenshot $t/inspector.png
EOF
	seed
	cat <<EOF
click Button "Play mode"
wait_log 10000 kit editor: unapplied edits of $G: 1 asked
frames 5
screenshot $t/ask.png
click Button "unapplied cancel"
wait_log 10000 kit editor: unapplied edits of $G kept
frames 3
click Button "Play mode"
wait_log 10000 kit editor: unapplied edits of $G: 1 asked
frames 3
click Button "unapplied discard"
wait_log 10000 kit editor: edit mode off
frames 5
keypress F6
wait_log 10000 kit editor: edit mode on
frames 10
EOF
	seed
	cat <<EOF
click Button "Play mode"
wait_log 10000 kit editor: unapplied edits of $G: 1 asked
frames 3
click Button "unapplied save"
wait_log 10000 kit editor: edit mode off
sync 2000
quit
EOF
} > "$t/drive.cmds"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" DISPLAY=$d WAYLAND_DISPLAY= \
	SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy BUILDAT_TEST_REAL_WINDOW=1 \
	BUILDAT_TEST_KIT_UI_MODE=1 run_client 60 "$t/client.log" \
	timeout 300 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 412x915 -u 1.03 -l 3 -o sound_mute=1 -c @"$t/drive.cmds" ||
	fail "the drive ($t/client.log)"
CL=$t/client.log
# 1. Every fit of the panel since the list: its view as wide as its body
python3 -I - "$CL" <<'PY' || fail "a scroll bar across the entity list ($CL)"
import re, sys
s = open(sys.argv[1], errors="replace").read()
s = s[s.index("kit editor: list "):s.index("kit editor: selected ")]
w = re.findall(r"kit editor: the panel \d+ of \d+ tall, (\d+) of (\d+) wide", s)
assert w, "no fit of the panel"
assert all(int(v) >= int(b) for v, b in w), w
print("ok: the entity list at 412x915 in its view's width: %s" % ", ".join("%s of %s" % x for x in w))
PY
# 2. Cancel kept, Discard sent nothing, Save the seed
n=$(grep -ac "kit editor: sent .*\"param\": *\"seed\"" "$CL")
[ "$n" = 1 ] || fail "the seed sent $n times, not once (the Save's) ($CL)"
grep -aq "kit editor: unapplied edits of $G discarded" "$CL" || fail "no Discard ($CL)"
grep -aq "kit editor: unapplied edits of $G saved" "$CL" || fail "no Save ($CL)"
grep -aE "kit editor: sent .*\"param\": *\"seed\"" "$CL" | grep -qE '"value": *19556\b' ||
	fail "the seed sent not 19556: $(grep -aE "kit editor: sent .*\"param\": *\"seed\"" "$CL") ($CL)"
echo "ok: play mode with the seed typed asked; Cancel kept the editor, Discard sent nothing, Save the seed 19556"
echo "PASS: Kit's entity list at a phone's portrait size in its width, the generator a row to pick; the inspector left with an edit not applied asks Save / Discard / Cancel; screenshots $t/entities.png $t/inspector.png $t/ask.png"
# vim: set noet ts=4 sw=4:
