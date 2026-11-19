#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-19)
# covers: extensions/jam/music_edit.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua src/impl/jam.cpp extensions/jam/songs.lua
# drives: extensions/jam/music_edit.lua
# [JAM_EDITOR] Kit's music editor (music_edit.lua) on a kit/music's song, on
# Workbench: kitboss (the admin, by the setup code) on a headless weston's
# Xwayland, the audio SDL's dummy driver:
#   0. its parameter tables' ranges are jam's (src/impl/jam.cpp's);
#   1. Yard Vamp (jam.songs'): the inspector's Edit... opens it, every view
#      shown (a screenshot each), played from a section and the section
#      looped, stopped; Apply sends the text unchanged;
#   2. Scrap Heat: Apply unchanged sends it as it was; Analyze's hash; a
#      drum step placed and taken out again: the text and the hash the
#      same; a snare step placed, a melodic step placed on ld1's lead, a
#      note drawn in the roll (a click; a drag, moved, resized), gtr's bright stepped up, kick's calm mood
#      gain -3 to -2: those lines alone changed, as expected, the text
#      parses, the hash another; Apply sends it;
#      then the other buttons of each view (sections' entries, the loop,
#      a param lane, Undo, an instrument's choices and source, a track's
#      pan, the reverb, tempo, swing, a mood, Space), the server takes it;
#   3. Scrap Heat with a comment added and a lane's spacing changed (set
#      as an agent would): the editor's hash the original's;
#   (0b. an agent's set_param of Scrap Heat over MCP, an 8 KB request;)
#   4. the touch mode (BUILDAT_TEST_KIT_UI_MODE=2): the editor opened, a
#      step tapped places it.
# Screenshots, kept with KEEP_TMP=1: $t/song.png $t/pattern.png $t/roll.png
# $t/inst.png $t/mixer.png $t/text.png $t/grid_edit.png $t/roll_edit.png
# $t/mixer_edit.png $t/touch.png
#   util/kit_music_edit_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_music_edit; t=$CHECK_TMP
export SDL_AUDIODRIVER=dummy

# 0. The editor's ranges are jam's
python3 -I - "$here" <<'PY' || fail "music_edit.lua's ranges are not jam's"
import re, sys
root = sys.argv[1]
cpp = open(root + "/src/impl/jam.cpp").read()
lua = open(root + "/extensions/jam/music_edit.lua").read()
num = r"(-?[0-9.e]+)"
def table(name):
    body = cpp.split(name + "[] = {", 1)[1].split("};", 1)[0]
    return body
inst = {k: (float(a), float(b)) for k, a, b in
        re.findall(r'\{"(\w+)", &Inst::\w+, ' + num + ", " + num + r"\}", table("INST_KEYS"))}
track = {k: (float(a), float(b)) for k, a, b in
         re.findall(r'\{"(\w+)", &TrackP::\w+, ' + num + ", " + num + r"\}", table("TRACK_KEYS"))}
buses = {}
for bus, name in (("reverb", "REVERB_KEYS"), ("delay", "DELAY_KEYS"), ("master", "MASTER_KEYS")):
    buses[bus] = {k: (float(a), float(b), float(d)) for k, d, a, b in
                  re.findall(r'\{"(\w+)", ' + num + ", " + num + ", " + num + r"\}", table(name))}
ent = r'\{"(\w+)", ' + num + ", " + num + ", " + num + r"\}"
def part(a, b):
    return lua.split(a, 1)[1].split(b, 1)[0]
bad, n = [], 0
for k, lo, hi, d in re.findall(ent, part("\nJ.INST = {", "\nJ.INST.tom")):
    n += 1
    if inst.get(k) != (float(lo), float(hi)):
        bad.append("inst %s: %s..%s, jam's %s" % (k, lo, hi, inst.get(k)))
for k, lo, hi, d in re.findall(ent, part("\nJ.TRACK = {", "\nJ.BUS = {")):
    n += 1
    if track.get(k) != (float(lo), float(hi)):
        bad.append("track %s: %s..%s, jam's %s" % (k, lo, hi, track.get(k)))
bt = part("\nJ.BUS = {", "\n}")
for bus in buses:
    for k, lo, hi, d in re.findall(ent, bt.split(bus + " = {", 1)[1].split("}},", 1)[0] + "}"):
        n += 1
        if buses[bus].get(k) != (float(lo), float(hi), float(d)):
            bad.append("%s %s: %s..%s (%s), jam's %s" % (bus, k, lo, hi, d, buses[bus].get(k)))
missing = set(inst) - set(re.findall(r'\{"(\w+)", ', part("\nJ.INST = {", "\nJ.INST.tom")))
if missing:
    bad.append("inst keys the editor lacks: " + " ".join(sorted(missing)))
if bad or n < 80:
    print("\n".join(bad) or "only %d entries read" % n)
    sys.exit(1)
print("ok: the editor's %d parameter ranges are jam's" % n)
PY

# The kit_edit lines setting the song: jam.songs' two and Scrap Heat with a
# comment and a lane's spacing changed (the same music)
songs() # <id>
{
	python3 -I - "$here" "$t" "$1" <<'PY'
import json, re, sys
root, t, id = sys.argv[1], sys.argv[2], int(sys.argv[3])
lua = open(root + "/extensions/jam/songs.lua").read()
songs = dict(re.findall(r"(\w+) = \[==\[\n(.*?)\]==\]", lua, re.S))
v = songs["scrap_heat"].replace("\ntempo ", "\n# (a comment an agent added)\ntempo ", 1)
v = v.replace("\nkick:  X . . . . . x .", "\nkick:  X . .  .  . . x .", 1)
assert v != songs["scrap_heat"] and v.count("\n") == songs["scrap_heat"].count("\n") + 1
for name, s in (("yard_vamp", songs["yard_vamp"]), ("scrap_heat", songs["scrap_heat"]),
        ("variant", v)):
    open("%s/%s.json" % (t, name), "w").write(json.dumps({"op": "set", "id": id,
        "comp": 0, "param": "song", "value": s}))
    open("%s/%s.bytes" % (t, name), "w").write(str(len(s.encode())))
PY
}

cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
check_build
sock=buildat-music-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
CLIENT=
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		[ -z "$CLIENT" ] || kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
}
cmd() { printf '%s\n' "$@" >&3; }
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
after() # <offset> <regex>: the client log's first match after offset
{
	tail -c +$(($1 + 1)) "$CL" | grep -aoE "$2" | head -1
}
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/srv" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($t/srv.log)"
SRV=$SERVER_PID
CHECK_PIDS+=($SRV)
SL=$t/srv.log
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
boss() # <name> [env...]: kitboss in $t/cu_kitboss, its commands from a fifo (fd 3), in edit mode, Stopped
{
	local n=$1
	shift
	mkfifo "$t/$n.cmd"
	sleep 900 > "$t/$n.cmd" &
	CHECK_PIDS+=($!)
	CL=$t/$n.log
	env "$@" DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
		timeout 600 bin/buildat -C "$t/client_cache" -D "$t/cu_kitboss" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 \
		-c - < "$t/$n.cmd" > "$CL" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
	exec 3> "$t/$n.cmd"
	await "$CL" 0 120 "Joined as kitboss"
	await "$CL" 0 60 "player physics enabled"
	await "$CL" 0 30 "kit editor: edit rights: yes"
	# (the server window's ntfy page, for the admin, when it came)
	if grep -aq "server window: the page ntfy" "$CL"; then
		cmd "frames 3" 'click Button "Don'"'"'t add"'
	fi
	# (the second time back in edit mode as he left it)
	if [ "$n" = boss ]; then
		step 20 "kit editor: edit mode on" "frames 3" "keypress F6"
	else
		await "$CL" 0 20 "kit editor: edit mode on"
	fi
	await "$CL" 0 20 "kit editor: the server is (Running|Ended)"
	if grep -a "kit editor: the server is" "$CL" | tail -1 | grep -q Running; then
		step 10 "kit editor: the server is Ended" 'event kit_edit {"op": "stop"}'
	fi
}
quit() # the client asked to quit, waited for
{
	cmd "sync 1000" "quit"
	exec 3>&-
	wait $CLIENT
	CLIENT=
}
set_song() # <name>: the music's song set to $t/<name>.json's, the inspector shows it
{
	local m mc
	m=$(mark "$SL") mc=$(mark "$CL")
	cmd "event kit_edit $(cat "$t/$1.json")"
	await "$SL" "$m" 10 "An edit by kitboss: set $ID's kit/music song to"
	[ -z "$SELECTED" ] || await "$CL" "$mc" 10 "kit editor: song song: .* \($(cat "$t/$1.bytes") bytes\)"
}
SELECTED=
view() # <view> <screenshot or "">
{
	step 10 "kit editor: music view $1" "frames 2" "click Button \"music view $1\""
	[ -z "$2" ] || cmd "frames 5" "screenshot $2" "wait_log_any 5000 Wrote screenshot $2"
}
HASH=
analyze() # HASH: the editor's Analyze's
{
	local m
	m=$(mark "$CL")
	step 30 "kit editor: music analyzed" "frames 2" 'click Button "music analyze"'
	HASH=$(tail -c +$((m + 1)) "$CL" | grep -aoP "kit editor: music analyzed.*hash \K[0-9a-f]+" | head -1)
	[ -n "$HASH" ] || fail "no hash: $(tail -c +$((m + 1)) "$CL" | grep -a "music analyzed") ($CL)"
}
APPLIED= # the last Apply's text, in $t/applied_<n>.txt
napply=0
apply() # the editor's Apply: the text it sent in $APPLIED
{
	local m
	m=$(mark "$CL")
	step 10 "kit editor: music applied" "frames 2" 'click Button "music apply"'
	napply=$((napply + 1))
	APPLIED=$t/applied_$napply.txt
	tail -c +$((m + 1)) "$CL" | python3 -I -c '
import json, sys
for l in sys.stdin.buffer.read().decode("utf-8", "replace").split("\n"):
    i = l.find("kit editor: sent {")
    if i >= 0:
        j = json.loads(l[i + len("kit editor: sent "):])
        if j.get("param") == "song":
            sys.stdout.write(j["value"])
            break
else:
    sys.exit(1)' > "$APPLIED" || fail "no song sent by Apply ($CL)"
}
same() # <file> <song>
{
	python3 -I - "$here" "$1" "$2" <<'PY'
import re, sys
lua = open(sys.argv[1] + "/extensions/jam/songs.lua").read()
songs = dict(re.findall(r"(\w+) = \[==\[\n(.*?)\]==\]", lua, re.S))
sys.exit(open(sys.argv[2]).read() != songs[sys.argv[3]])
PY
}

boss boss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_ADMIN="setting open_registration on"
m=$(mark "$SL")
cmd 'event kit_edit {"op": "place", "type": "kit/music", "pos": [0, 1, 0]}'
await "$SL" "$m" 10 "An edit by kitboss: placed kit/music [0-9]+"
ID=$(tail -c +$((m + 1)) "$SL" | grep -aoP "An edit by kitboss: placed kit/music \K[0-9]+" | head -1)
songs "$ID"

# 0b. An agent's set_param of Scrap Heat (8 KB) over MCP: a token made on My
# account, one call
clip() # the clipboard
{
	local i got
	for i in $(seq 50); do
		got=$(DISPLAY=$d xclip -selection clipboard -o 2>/dev/null)
		[ -n "$got" ] && break
		sleep 0.2
	done
	printf '%s' "$got"
}
step 10 "pause: the menu shown" "frames 3" "keypress Escape"
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" \
	'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
tok=$(clip)
[[ $tok =~ ^bat_[0-9a-f]{64}$ ]] || fail "kitboss's token: $tok"
cmd "frames 3" 'click Button "Done"'
step 10 "pause: the menu shown" "keypress Escape"
step 10 "pause: the menu closed" "frames 3" "keypress Escape"
m=$(mark "$SL")
python3 -I - "http://localhost:$SERVER_PORT/api/v1/mcp" "$tok" "$t/scrap_heat.json" <<'PY' ||
import json, sys, urllib.request
url, tok, f = sys.argv[1:4]
n = 0
def rpc(method, params):
    global n
    n += 1
    body = json.dumps({"jsonrpc": "2.0", "id": n, "method": method,
        "params": params}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": "Bearer " + tok})
    with urllib.request.urlopen(req, timeout=30) as r:
        assert r.status == 200, r.status
        return json.loads(r.read().decode()), len(body)
rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
    "clientInfo": {"name": "kit_music_edit_check", "version": "1"}})
e = json.load(open(f))
r, size = rpc("tools/call", {"name": "set_param", "arguments": {"id": e["id"],
    "comp": 0, "param": "song", "value": e["value"]}})
text = r["result"]["content"][0]["text"]
assert not r["result"]["isError"] and size > 8000, (size, text[:300])
print("ok: an agent's set_param of Scrap Heat (a %d-byte request): %s" % (size, text[:80]))
PY
	fail "an agent's set_param of an 8 KB song"
await "$SL" "$m" 10 "set $ID's kit/music song to \"# Scrap Heat"

# 1. Yard Vamp: every view, Apply unchanged
set_song yard_vamp
step 10 "kit editor: song song: Yard Vamp: .* \($(cat "$t/yard_vamp.bytes") bytes\)" \
	"frames 3" "event kit_select $ID"
SELECTED=1
step 10 "kit editor: music opened .*: [0-9]+ bytes, 8 tracks, 13 patterns, 3 sections, parses" \
	"frames 3" 'click Button "song edit"'
cmd "frames 5" "screenshot $t/song.png" "wait_log_any 5000 Wrote screenshot $t/song.png"
for v in pattern roll inst mixer text; do
	view $v "$t/$v.png"
done
view song ""
step 10 "kit editor: music section blues" "frames 2" 'click Button "music section blues 2"'
step 10 "kit editor: music playing song from [1-9][0-9.]* s, mood all" "frames 2" \
	'click Button "music play from"'
step 10 "kit editor: music playing section blues from 0.00 s" "frames 30" 'click Button "music loop it"'
step 10 "kit editor: music stopped" "frames 30" 'click Button "music play"'
view pattern ""
step 10 "kit editor: music view pattern" "frames 2" 'click DropDownList "music pattern"' \
	"frames 3" 'click Text "music pattern: rA1 (1)"'
apply
same "$APPLIED" yard_vamp || fail "Yard Vamp not sent as it was ($APPLIED)"
step 10 "kit editor: music closed" "frames 2" 'click Button "music close"'
echo "ok: Yard Vamp in every view, Apply sends it unchanged"

# 2. Scrap Heat: unchanged, then the edits
set_song scrap_heat
step 10 "kit editor: music opened .*: [0-9]+ bytes, 10 tracks, 18 patterns, 6 sections, parses" \
	"frames 3" 'click Button "song edit"'
for v in pattern roll inst mixer text song; do
	view $v ""
done
apply
same "$APPLIED" scrap_heat || fail "Scrap Heat not sent as it was ($APPLIED)"
echo "ok: Scrap Heat in every view, Apply sends it unchanged"
analyze
H0=$HASH
view pattern ""
step 10 "kit editor: music view pattern beat" "frames 2" 'click DropDownList "music pattern"' \
	"frames 3" 'click Text "music pattern: beat (1)"'
step 10 "kit editor: music edit placed x at beat kick step 2: parses" "frames 2" \
	'click BorderImage "music step kick 2"'
step 10 "kit editor: music edit cleared beat kick step 2: parses" "frames 2" \
	'click BorderImage "music step kick 2"'
analyze
[ "$HASH" = "$H0" ] || fail "a step placed and taken out changed the hash ($H0, $HASH)"
step 10 "kit editor: music edit placed x at beat snare step 3: parses" "frames 2" \
	'click BorderImage "music step snare 3"'
cmd "frames 5" "screenshot $t/grid_edit.png" "wait_log_any 5000 Wrote screenshot $t/grid_edit.png"
step 10 "kit editor: music view pattern ld1" "frames 2" 'click DropDownList "music pattern"' \
	"frames 3" 'click Text "music pattern: ld1 (2)"'
step 10 "kit editor: music edit placed [A-G][#b]?[0-9] at ld1 lead step 4: parses" "frames 2" \
	'click BorderImage "music step lead 4"'
view roll ""
m=$(mark "$CL")
step 10 "kit editor: music edit note G4 at step 20, length 1: ld1 lead: parses" "frames 2" \
	'click BorderImage "music roll 20 G4"'
# Drags from there, in the drive's pixels (the window's over the UI's):
# E4 drawn 4 long at step 22, moved a step on and up to F4, made 5 long
read -r X Y W CW CH <<< "$(after "$m" "music press at [0-9]+ [0-9]+ of [0-9]+, cells [0-9]+ [0-9]+" |
	grep -oE "[0-9]+" | tr '\n' ' ')"
[ -n "$CH" ] || fail "no press logged ($CL)"
px() { echo $(( ($1) * 1024 / W )); }
drag() # <regex> <from x y> <to x y> (UI units)
{
	step 10 "$1" "mouse_pos $(px "$2") $(px "$3")" "frames 2" "mouse_down left" "frames 2" \
		"mouse_pos $(px "$4") $(px "$5")" "frames 2" "mouse_up left" "frames 2"
}
drag "kit editor: music edit note E4 at step 22, length 4: ld1 lead: parses" \
	"X + 2 * CW" "Y + 3 * CH" "X + 5 * CW" "Y + 3 * CH"
drag "kit editor: music edit note E4 moved to step 23 as F4: ld1 lead: parses" \
	"X + 2 * CW" "Y + 3 * CH" "X + 3 * CW" "Y + 2 * CH"
drag "kit editor: music edit note at step 23, length 5: ld1 lead: parses" \
	"X + 6 * CW + CW / 4" "Y + 2 * CH" "X + 7 * CW + CW / 4" "Y + 2 * CH"
cmd "frames 5" "screenshot $t/roll_edit.png" "wait_log_any 5000 Wrote screenshot $t/roll_edit.png"
view inst ""
step 10 "kit editor: music instrument gtr" "frames 2" 'click Button "music inst gtr"'
step 10 "kit editor: music edit inst gtr bright [0-9.]+: parses" "frames 2" \
	'click Button "music param bright +"'
view mixer ""
step 10 "kit editor: music mixer kick mood calm" "frames 2" 'click Button "music mix kick mood calm"'
step 10 "kit editor: music edit mood calm kick -2: parses" "frames 2" 'click Button "music mood +"'
cmd "frames 5" "screenshot $t/mixer_edit.png" "wait_log_any 5000 Wrote screenshot $t/mixer_edit.png"
analyze
[ "$HASH" != "$H0" ] || fail "the edits left the hash as it was ($HASH)"
apply
python3 -I - "$here" "$APPLIED" <<'PY' || fail "Scrap Heat's edits are not as expected ($APPLIED)"
import re, sys
lua = open(sys.argv[1] + "/extensions/jam/songs.lua").read()
a = dict(re.findall(r"(\w+) = \[==\[\n(.*?)\]==\]", lua, re.S))["scrap_heat"].split("\n")
b = open(sys.argv[2]).read().split("\n")
assert len(a) == len(b), "%d lines, was %d" % (len(b), len(a))
pat, at = None, {}
for i, l in enumerate(a):
    if l.startswith("pattern "):
        pat = l.split()[1]
    lane = l.split(":")[0] if re.match(r"^\w+:", l) else None
    at.setdefault((pat, lane), []).append(i)
    if l.startswith("inst gtr "): at["inst"] = i
    if l.startswith("mood calm "): at["mood"] = i
snare = at[("beat", "snare")][0]
lead = at[("ld1", "lead")]
want = {snare, lead[0], lead[1], at["inst"], at["mood"]}
changed = {i for i in range(len(a)) if a[i] != b[i]}
assert changed == want, "lines changed %s, expected %s" % (sorted(changed), sorted(want))
steps = lambda l: l.split(":", 1)[1].replace(" ", "").replace("|", "")
sa, sb = steps(a[snare]), steps(b[snare])
assert sb[2] == "x" and sb[:2] + sb[3:] == sa[:2] + sa[3:], (a[snare], b[snare])
ta, tb = a[lead[0]].split()[1:], b[lead[0]].split()[1:]
assert ta[:3] == tb[:3] and tb[3] not in "-.", (a[lead[0]], b[lead[0]])
ta, tb = a[lead[1]].split()[1:], b[lead[1]].split()[1:]
assert ta[:3] == tb[:3] and tb[3:] == "G4 . . F4 - - - - . D4 - E4 -".split(), (a[lead[1]], b[lead[1]])
bright = lambda l: float(re.search(r"bright=([0-9.]+)", l).group(1))
assert bright(b[at["inst"]]) > bright(a[at["inst"]]), (a[at["inst"]], b[at["inst"]])
assert re.sub(r" bright=\S+", "", a[at["inst"]]) == re.sub(r" bright=\S+", "", b[at["inst"]])
assert b[at["mood"]] == a[at["mood"]].replace("kick=-3", "kick=-2"), b[at["mood"]]
print("ok: the edits changed the lines they should: " + " | ".join(b[i].strip() for i in sorted(want)))
PY
# The rest of the views' buttons, each an edit that parses
e() # <log after "kit editor: music "> <command>...
{
	local re=$1
	shift
	step 10 "kit editor: music $re" "frames 2" "$@"
}
view song ""
e "section chorus" 'click Button "music section chorus 4"'
e "edit loop chorus: parses" 'click Button "music loop here"'
e "entry chorus 1" 'click Button "music entry chorus 1"'
e "edit section chorus 1 repeat 2: parses" 'click Button "music rep +"'
e "edit section chorus 1 later: parses" 'click Button "music entry >"'
e "edit section chorus 2 removed: parses" 'click Button "music entry remove"'
view pattern ""
e "lane ld1 lead" 'click Button "music lane lead"'
e "edit lane lead~cut added to ld1: parses" 'click DropDownList "music add param"' \
	"frames 3" 'click Text "music add param: cut"'
e "edit placed [0-9.]+ at ld1 lead~cut step 1: parses" 'click BorderImage "music step lead~cut 1"'
e "edit value [0-9.]+: ld1 lead~cut step 1: parses" 'click Button "music value +"'
e "undone" 'click Button "music undo"'
view inst ""
e "instrument gtr" 'click Button "music inst gtr"'
e "edit inst gtr bright default: parses" 'click Button "music param bright x"'
e "edit inst gtr ftype lp: parses" 'click DropDownList "music choice ftype"' \
	"frames 3" 'click Text "music choice ftype: lp"'
e "edit inst gtr src osc: parses" 'click DropDownList "music src"' "frames 3" \
	'click Text "music src: osc"'
view mixer ""
e "mixer gtl pan" 'click Button "music mix gtl pan"'
e "edit track gtl pan -?[0-9.]+: parses" 'click Button "music track pan +"'
e "mixer reverb" 'click Button "music mix bus rev"'
e "edit reverb decay [0-9.]+: parses" 'click Button "music bus decay +"'
e "edit tempo 157: parses" 'click Button "music tempo +"'
e "edit swing 0.05: parses" 'click Button "music swing +"'
e "preview mood lobby" 'click Button "music mood lobby"'
e "playing song from 0.00 s, mood lobby" "keypress Space"
e "stopped" "frames 10" "keypress Space"
m=$(mark "$SL")
apply
await "$SL" "$m" 10 "An edit by kitboss: set $ID's kit/music song to"
step 10 "kit editor: music closed" "frames 2" 'click Button "music close"'
echo "ok: Scrap Heat edited in the grid, the roll, the instrument and the mixer; the hash $H0 before, $HASH after, the same for a step put back; the other views' buttons edit it and the server takes it"

# 3. The same music, its text another: the same hash
set_song variant
step 10 "kit editor: music opened .*, parses" "frames 3" 'click Button "song edit"'
analyze
[ "$HASH" = "$H0" ] || fail "a comment and spacing changed the hash ($H0, $HASH)"
m=$(mark "$CL")
step 10 "kit editor: music closed" "frames 2" "keypress Escape"
step 10 "kit editor: music view song" "frames 5" 'click Button "song edit"' "frames 2" \
	'click Button "music view song"'
! tail -c +$((m + 1)) "$CL" | grep -aq "pause: the menu shown" ||
	fail "the editor's Escape opened the pause menu too ($CL)"
step 10 "kit editor: music closed" "frames 2" 'click Button "music close"'
echo "ok: a comment and a lane's spacing leave the hash $H0; Escape closes the editor"
quit

# 4. The touch mode: a step tapped
boss touch BUILDAT_TEST_KIT_UI_MODE=2
step 10 "kit editor: song song: Scrap Heat: .* \($(cat "$t/variant.bytes") bytes\)" \
	"frames 3" "event kit_select $ID"
step 10 "kit editor: music opened" "frames 3" 'tap Button "song edit"'
view pattern ""
step 10 "kit editor: music view pattern beat" "frames 2" 'tap DropDownList "music pattern"' \
	"frames 3" 'tap Text "music pattern: beat (1)"'
step 10 "kit editor: music edit placed x at beat kick step 2: parses" "frames 2" \
	'tap BorderImage "music step kick 2"'
cmd "frames 5" "screenshot $t/touch.png" "wait_log_any 5000 Wrote screenshot $t/touch.png"
quit
kill -INT $SRV 2>/dev/null
wait $SRV 2>/dev/null
echo "ok: the touch mode: the editor opened, a step tapped"
echo "PASS: Kit's music editor: jam's ranges; Yard Vamp and Scrap Heat in every view and back unchanged; steps, a note, an instrument's parameter and a mood's gain edited as text, the hash changed by the music alone; the touch mode's tap. Screenshots in $t"
