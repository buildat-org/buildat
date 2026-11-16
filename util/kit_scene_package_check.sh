#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-16)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua client/core/aitta/** src/impl/aitta.cpp
# [KIT_SCENE_PACKAGES] A scene exported from one Workbench project and
# added to another, from the file and through a local Aitta. kitboss, the
# admin of two Workbench servers one after the other (each its blank
# project "world": one game, kitboss/world), on a headless weston's
# Xwayland of the check's own:
#   1. A: in "world" the counters Score and Bell and the custom types
#      local/beacon and local/marker; a scene "track" (its own World, a
#      heightmap), in it a timer linked to Score and to Bell, a teleporter onto
#      Score, a beacon, a marker, a cell of the voxel type kitboss/brick and
#      a heightmap stroke, a kit/scene_info. The palette's New tab: Export this scene, the
#      file track.scene.zip in <user>/exports (its outside entities named);
#      Publish this scene..., dev_apps/track, packed and published by the
#      command line, and a copy of it as "othertrack", made for the game
#      other/game.
#   2. B (another user dir, the file copied into its exports): in "world" a
#      counter Score and B's own local/marker. Add from a file...
#      (the scene list), the picker: a zip with a file no scene package has
#      refused; track.scene.zip added as "track", the window listing the
#      link to Bell left out. Its export there has the first's World edits
#      and names only Score outside it.
#   3. B's New tab lists both packages: "track" added at once as track_2
#      (its key vouched for by the Aitta), its kitboss/brick kept as B's,
#      not refused; "othertrack" only after the question's Add anyway, as
#      track_3, its brick giving light: B's kept, the Added line naming it
#      as differing.
#   4. B, Running: track.scene.zip as 0.8.0-alpha.1 made it (its World's
#      edits over 64 sections, its brick another version): with another
#      kind refused, the refusal naming both versions; as it is added as
#      track_4, unlisted, the brick kept and not named; its list_scene
#      refused until its World's sections are in, then done.
#   B's save after: each scene's entities new ids, the timer's link and the
#   teleporter's target B's Score, no link to Bell; local/beacon A's,
#   local/marker B's own; kitboss/brick and the heightmap rows taken.
# Screenshots, kept with KEEP_TMP=1: $t/a_new.png (A's New tab),
# $t/a_publish.png, $t/b_added.png (what was left out), $t/b_new.png (B's
# New tab), $t/b_other.png (the other game's question)
#   util/kit_scene_package_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
# Workbench opens its project "world" at once, no Manage
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston unzip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_scene_package; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
check_build
b="$here/Build/bin/buildat"
sock=buildat-scene-$$
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
edit() # <regex in the server's log> <kit:edit JSON>
{
	local m
	m=$(mark "$SL")
	cmd "event kit_edit $2"
	await "$SL" "$m" 10 "$1"
}
put_type() # <name> <source> [client]: a custom type put
{
	local m
	m=$(mark "$SL")
	cmd "event kit_type {\"op\": \"put\", \"name\": \"$1\", \"source\": \"$2\", \"client\": \"${3:-}\"}"
	await "$SL" "$m" 10 "A type put \(local/$1\) by peer [0-9]+ (done|refused)"
	tail -c +$((m + 1)) "$SL" | grep -qaE "A type put \(local/$1\) by peer [0-9]+ done" ||
		fail "local/$1 refused ($SL)"
}
ID= # placed's
placed() # <type> <x> <y> <z> <name>: ID the new entity's
{
	local m
	m=$(mark "$SL")
	cmd "event kit_edit {\"op\": \"place\", \"type\": \"$1\", \"pos\": [$2, $3, $4]}"
	await "$SL" "$m" 10 "An edit by kitboss: placed $1 [0-9]+|An edit \(place\) by peer [0-9]+ refused"
	ID=$(tail -c +$((m + 1)) "$SL" | grep -aoP "An edit by kitboss: placed \S+ \K[0-9]+" | head -1)
	[ -n "$ID" ] || fail "no id of the placed $1 ($SL)"
	edit "An edit by kitboss: renamed $ID to $5" "{\"op\": \"rename\", \"id\": $ID, \"name\": \"$5\"}"
}
# A user dir with only this Aitta, its address allowed
user() # <dir>
{
	local now
	now=$(date +%s)
	mkdir -p "$1"
	echo "{\"starports\": [], \"aittas\": [\"http://127.0.0.1:$P\"]}" > "$1/starport.json"
	printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","","%s","%s","","",""\n' \
		$P $now $now > "$1/network_addresses.csv"
}
server() # <name>: a Workbench server in $t/<name>, its log $SL
{
	SL=$t/$1.log
	start_server "$SL" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/$1" -l 3 \
		--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
	SRV=$SERVER_PID
	CHECK_PIDS+=($SRV)
	wait_for_log "$SL" "setup code [A-Z0-9]+" 30
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
	[ -n "$code" ] || fail "no setup code ($SL)"
}
client() # <name>: kitboss in $t/cu_<name>, the admin by the setup code, its commands from a fifo; the tools on, Stopped
{
	exec 3>&-
	mkfifo "$t/$1.cmd"
	sleep 900 > "$t/$1.cmd" &
	CHECK_PIDS+=($!)
	CL=$t/$1_client.log
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
		BUILDAT_JOIN_CODE=$code timeout 600 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 \
		-c - < "$t/$1.cmd" > "$CL" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
	exec 3> "$t/$1.cmd"
	await "$CL" 0 120 "Joined as kitboss"
	cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
	await "$CL" 0 60 "player physics enabled"
	await "$CL" 0 30 "kit editor: edit rights: yes"
	step 20 "kit editor: edit mode on" "frames 3" "keypress F6"
	await "$CL" 0 20 "kit editor: the server is (Running|Ended)"
	if grep -a "kit editor: the server is" "$CL" | tail -1 | grep -q Running; then
		step 10 "kit editor: the server is Ended" 'event kit_edit {"op": "stop"}'
	fi
}
bye() # the client and its server gone
{
	cmd "quit"
	exec 3>&-
	wait $CLIENT
	CLIENT=
	kill -INT $SRV 2>/dev/null
	wait $SRV 2>/dev/null
}
added_closed() # the window listing what was left out closed
{
	step 10 "kit editor: the scene added closed" "frames 3" 'click Button "OK"'
}
pick() # <file in <user>/exports> <regex in the client's log> [commands after]: Add from a file...
{
	local f=$1 re=$2
	shift 2
	# (the bar's second list, the first the view's)
	cmd "frames 3" 'click DropDownList "▼" 1024 0' "delay 300" "frames 3"
	step 10 "The file picker at .*/exports" 'click Text "Add from a file..."'
	step 60 "$re" "frames 3" "click Button \"$f\"" "$@"
}

# The Aitta, kitboss's key bound there
start_server "$t/aitta.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/aitta" -l 3 ||
	fail "Aitta did not start ($t/aitta.log)"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
acode=$(grep -ao "setup code [A-Z0-9]*" "$t/aitta.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'wait_log_any 20000 ai: {"id":1,\nquit\n' > "$t/bind.cmds"
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_AITTA_CREATE=1 \
	BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$acode \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"kitboss\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -o sound_mute=1 -D "$t/bind" \
	-w 800x600 -l 3 -s 127.0.0.1:$P -c @"$t/bind.cmds" > "$t/bind.log" 2>&1 ||
	fail "the bind's client ($t/bind.log)"
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind ($t/bind.log)"
publish() # <dir>
{
	local zip
	zip=$("$b" aitta pack "$1" "$t/key" "$t/out" 2> "$t/pack.err") ||
		fail "pack $1: $(cat "$t/pack.err")"
	"$b" aitta publish "$zip" 127.0.0.1:$P > "$t/publish.out" 2>&1
	grep -q "listed: kitboss/" "$t/publish.out" || fail "publish $1: $(cat "$t/publish.out")"
}
user "$t/cu_a"
user "$t/cu_b"
# The servers ask the Aitta whose a package's key is
export BUILDAT_CONNECT_PORTS=$P

BEACON='return {version = 1, about = {group = \"Building\", what = \"A beacon\"}, look = {shape = \"box\", size = 0.3, color = \"#40c0ff\"}, params = {glow = {type = \"number\", default = 2}}}\n'
BEACON_CLIENT='return {on_add = function(e) e:log(\"beacon added\") end}\n'
marker() { echo 'return {version = 1, about = {group = \"Building\", what = \"A marker\"}, look = {shape = \"sphere\", size = 0.2, color = \"'"$1"'\"}}\n'; }

# 1. A: the scene, exported and published
server a
client a
edit "kitboss made voxel type kitboss/brick version 1" \
	'{"op": "voxel", "name": "brick", "texture": "kit/stone.png"}'
placed kit/counter 6 9 4 Score
SCORE=$ID
placed kit/counter 6 9 8 Bell
BELL=$ID
put_type beacon "$BEACON" "$BEACON_CLIENT"
put_type marker "$(marker '#ff4040')"
step 20 "kit editor: in the scene track " \
	'event kit_edit {"op": "new_scene", "name": "track", "copy": true}'
# Its own World, a heightmap
placed kit/terrain 0 1 0 World
m=$(mark "$CL")
edit "set $ID's kit/terrain surface to \"heightmap\"" \
	"{\"op\": \"set\", \"id\": $ID, \"comp\": 0, \"param\": \"surface\", \"value\": \"heightmap\"}"
await "$CL" "$m" 30 "heightmap: terrain built"
placed kit/timer 4 9 4 Timer
T=$ID
edit "linked $T.tick -> $SCORE.count" \
	"{\"op\": \"link\", \"id\": $T, \"comp\": 0, \"output\": \"tick\", \"to\": $SCORE, \"input\": \"count\"}"
edit "linked $T.done -> $BELL.count" \
	"{\"op\": \"link\", \"id\": $T, \"comp\": 0, \"output\": \"done\", \"to\": $BELL, \"input\": \"count\"}"
placed kit/teleporter 8 9 6 Gate
edit "set $ID's kit/teleporter target to $SCORE" \
	"{\"op\": \"set\", \"id\": $ID, \"comp\": 0, \"param\": \"target\", \"value\": $SCORE}"
placed local/beacon 8 9 4 Beacon
placed local/marker 10 9 4 Marker
# (for part 4's list_scene)
placed kit/scene_info 0 1 10 Info
# The cell, once its section is loaded in the new scene's World
for i in $(seq 30); do
	m=$(mark "$SL")
	cmd 'event kit_edit {"op": "set_voxel", "pos": [3, 14, 3], "voxel": "kitboss/brick"}'
	await "$SL" "$m" 10 "A voxel edit by kitboss: placed kitboss/brick at \(3,14,3\)|An edit \(set_voxel\) by peer [0-9]+ refused"
	tail -c +$((m + 1)) "$SL" | grep -qa "placed kitboss/brick at (3,14,3)" && break
	[ $i = 30 ] && fail "the cell never written ($SL)"
	sleep 0.5
done
step 10 "kit editor: terrain: " \
	'event kit_edit {"op": "terrain", "tool": "raise", "x": 4, "y": 0, "z": 4, "size": 2, "strength": 5, "stroke": 1}'
step 20 "kit editor: [0-9]+ scene packages listed" "frames 3" 'click Button "New"'
cmd "frames 5" "screenshot $t/a_new.png"
step 20 "kit editor: Exported to .*track\.scene\.zip" "frames 3" 'click Button "Export this scene"'
z=$t/cu_a/exports/track.scene.zip
[ -s "$z" ] || fail "no $z ($CL)"
grep -aqE "kitboss exports the scene track: [0-9]+ files, [0-9]+ entities \(2 named outside it\), [1-9][0-9]* cells, [1-9][0-9]* heightmap samples" "$SL" ||
	fail "the export's line: $(grep -a "exports the scene" "$SL") ($SL)"
step 10 "kit editor: publish this scene: [0-9]+ goal warnings" "frames 3" 'click Button "Publish this scene..."'
if ! grep -aq "kit editor: publish this scene: 0 goal warnings" "$CL"; then
	step 10 "kit editor: published with goal warnings" "frames 3" 'click Button "Publish anyway"'
fi
await "$CL" 0 10 "aitta publish: the scene asked, [0-9]+ files"
step 10 "aitta publish: the package page, track" "frames 3" 'click Button "Yes"'
cmd "delay 300" "frames 3" "screenshot $t/a_publish.png"
bye
mkdir "$t/a_zip"
unzip -q "$z" -d "$t/a_zip" || fail "the export does not unzip ($z)"
mkdir -p "$t/cu_b/exports"
cp "$z" "$t/cu_b/exports/"
python3 -I - "$t/a_zip" "$t/cu_a/dev_apps/track" "$t/othertrack" "$t/cu_b/exports/bad.scene.zip" "$z" <<'PY' || fail "A's export ($z)"
import json, os, shutil, sys, zipfile
x, dev, other, bad, z = sys.argv[1:]
files = sorted(os.path.relpath(os.path.join(r, f), x) for r, _, fs in os.walk(x) for f in fs)
assert files == ["LICENSE", "composition.json", "edits.bin", "meta.json",
    "types/beacon.client.lua", "types/beacon.lua", "types/marker.lua",
    "voxels.json"], files
m = json.load(open(x + "/meta.json"))
assert m["kind"] == "scene" and m["name"] == "track" and m["title"] == "track" \
    and m["game"] == "kitboss/world" and m["author"] == "kitboss", m
c = json.load(open(x + "/composition.json"))
assert c["scene"] == "track" and sorted(c["outside"].values()) == ["Bell", "Score"], c
names = sorted(e.get("name", "") for e in c["entities"])
assert {"track", "World", "Timer", "Gate", "Beacon", "Marker"} <= set(names), names
assert list(json.load(open(x + "/voxels.json"))) == ["kitboss/brick"]
# The publish's folder: the export's files; its licences as the publish
# screen's form gives them; a copy for another game
assert sorted(os.listdir(dev + "/types")) == ["beacon.client.lua", "beacon.lua", "marker.lua"]
dm = json.load(open(dev + "/meta.json"))
assert dm["kind"] == "scene" and dm["game"] == "kitboss/world" and dm["title"] == "track", dm
dm.update(license_code="MIT", license_media="CC0-1.0")
json.dump(dm, open(dev + "/meta.json", "w"))
shutil.copytree(dev, other)
dm.update(name="othertrack", title="Other track", game="other/game")
json.dump(dm, open(other + "/meta.json", "w"))
# Its copy of kitboss/brick gives light: B keeps its own, named as differing
vs = json.load(open(other + "/voxels.json"))
vs["kitboss/brick"]["light"] = 5
json.dump(vs, open(other + "/voxels.json", "w"))
# A zip with a file no scene package has
with zipfile.ZipFile(z) as zi, zipfile.ZipFile(bad, "w") as zo:
    for n in zi.namelist():
        zo.writestr(n, zi.read(n))
    zo.writestr("x/evil.lua", "return {}\n")
print("A's export: %s; its entities %s; outside it %s" % (", ".join(files),
    ", ".join(names), ", ".join(sorted(c["outside"].values()))))
PY
publish "$t/cu_a/dev_apps/track"
publish "$t/othertrack"
echo "ok: the scene exported and published (A)"

# 2. B: added from the file
server b
client b
placed kit/counter 2 9 2 Score
SCORE_B=$ID
put_type marker "$(marker '#40ff40')"
pick bad.scene.zip "kit editor: Scene refused: the archive: not a scene package's file: x/evil.lua"
m=$(mark "$SL")
mc=$(mark "$CL")
pick track.scene.zip "kit editor: Added the scene track "
await "$SL" "$m" 10 "kitboss adds the scene track \(kitboss/track 1\.0\.0\): [0-9]+ entities, 1 links or entity parameters left out, 1 types added, 1 kept as the game's, 1 rows \(0 kept as the game's, 0 refused\), 0 textures, [1-9][0-9]* heightmap samples"
await "$SL" "$m" 10 "World track: the template's [1-9][0-9]* edited cells in [0-9]+ sections \(0 left out\)"
await "$SL" "$m" 10 "The scene track's local/marker differs from the project's"
await "$SL" "$m" 10 "The scene track: left out: Timer's link done to Bell"
await "$CL" "$mc" 10 "kit editor: left out: Timer's link done to Bell"
await "$CL" "$mc" 10 "kit editor: in the scene track "
cmd "delay 300" "frames 5" "screenshot $t/b_added.png"
added_closed
# Its export here: the first's edits
step 20 "kit editor: [0-9]+ scene packages listed" "frames 3" 'click Button "New"'
step 20 "kit editor: Exported to .*track.*\.zip" "frames 3" 'click Button "Export this scene"'
zb=$(grep -aoP "kit editor: Exported to \K.*track.*\.zip" "$CL" | tail -1)
[ -s "$zb" ] || fail "no B's export ($CL)"
mkdir "$t/b_zip"
unzip -q "$zb" -d "$t/b_zip" || fail "B's export does not unzip ($zb)"
python3 -I - "$t/a_zip" "$t/b_zip" <<'PY' || fail "B's export ($zb)"
import json, sys, zlib
a, b = sys.argv[1:]
def edits(d):
    f = json.loads(zlib.decompress(open(d + "/edits.bin", "rb").read()))
    e = f["scenes"]["track"]
    n = e["names"]
    cells = sorted((c[0], c[1], c[2], n[c[3]], c[4]) for c in
        (e["cells"][i:i + 5] for i in range(0, len(e["cells"]), 5)))
    w = 3 + f["materials"]
    hm = sorted(tuple(e["hm"][i:i + w]) for i in range(0, len(e["hm"]), w))
    return cells, hm, e["decor"]
ea, eb = edits(a), edits(b)
assert (3, 14, 3, "kitboss/brick", 0) in ea[0] and ea[1], ea
assert ea == eb, (ea[0][:5], eb[0][:5], len(ea[1]), len(eb[1]))
c = json.load(open(b + "/composition.json"))
assert list(c["outside"].values()) == ["Score"], c["outside"]
print("B's export: the first's %d cells and %d heightmap samples; outside it: Score" % (len(ea[0]), len(ea[1])))
PY
echo "ok: added from the file (B): a bad file refused, Bell's link left out, marker kept as B's, the World's edits the export's"

# 3. B: from the Aitta
cmd "frames 5" "screenshot $t/b_new.png"
grep -aq "kit editor: scene package kitboss/track 0.1.0 for kitboss/world" "$CL" &&
	grep -aq "kit editor: scene package kitboss/othertrack 0.1.0 for other/game" "$CL" ||
	fail "the New tab's list ($CL)"
m=$(mark "$SL")
mc=$(mark "$CL")
step 30 "kit editor: Added the scene track_2 " "frames 3" 'click Button "Add track"'
# (the brick B took from track: kept as B's, the same row)
await "$SL" "$m" 10 "kitboss adds the scene track_2 \(kitboss/track 0\.1\.0 from [^)]*\): [0-9]+ entities, 1 links or entity parameters left out, 0 types added, 1 kept as the game's, 0 rows \(1 kept as the game's, 0 refused\), [0-9]+ textures, [0-9]+ heightmap samples, [0-9]+ decorations$"
await "$SL" "$m" 20 "The scene track_2: by kitboss@[^,]*, its Aitta says"
await "$CL" "$mc" 10 "kit editor: in the scene track_2 "
! tail -c +$((mc + 1)) "$CL" | grep -qa "is made for" ||
	fail "the same game's package asked about ($CL)"
added_closed
step 10 "kit editor: the scene .*/othertrack is made for other/game, this project kitboss/world" \
	"frames 3" 'click Button "Add Other track"'
cmd "delay 300" "frames 5" "screenshot $t/b_other.png"
m=$(mark "$SL")
mc=$(mark "$CL")
step 30 "kit editor: Added the scene track_3 " "frames 3" 'click Button "Add anyway"'
# (its brick gives light: B's kept, named for the builder)
await "$SL" "$m" 10 "kitboss adds the scene track_3 \(kitboss/othertrack 0\.1\.0 from [^)]*\): .* 0 rows \(1 kept as the game's, 0 refused\), .* decorations; 1 differs from the game's: kitboss/brick$"
await "$CL" "$mc" 10 "kit editor: Added the scene track_3 .* decorations; 1 differs from the game's: kitboss/brick"
added_closed
echo "ok: from the Aitta (B): track_2 at once, track_3 after Add anyway"

# 4. B, Running: track made by another alpha (its World's edits over 64
# sections); the same with another kind refused, naming both versions
python3 -I - "$z" "$t/cu_b/exports" <<'PY' || fail "the other alpha's zips"
import json, sys, zipfile, zlib
z, out = sys.argv[1:]
with zipfile.ZipFile(z) as zi:
    files = {n: zi.read(n) for n in zi.namelist()}
m = json.loads(files["meta.json"])
assert m.get("buildat_version"), m
m["buildat_version"] = "0.8.0-alpha.1"
f = json.loads(zlib.decompress(files["edits.bin"]))
e = f["scenes"]["track"]
b = e["names"].index("kitboss/brick")
for i in range(8):
    for k in range(8):
        if i or k:
            e["cells"] += [64 * i + 3, 14, 64 * k + 3, b, 0]
files["edits.bin"] = zlib.compress(json.dumps(f).encode())
# Its brick's row another version of B's, the same otherwise
vs = json.loads(files["voxels.json"])
vs["kitboss/brick"]["version"] = 7
files["voxels.json"] = json.dumps(vs)
for name, meta in (("old", m), ("oldkind", dict(m, kind="template"))):
    with zipfile.ZipFile(out + "/" + name + ".scene.zip", "w") as zo:
        for n, d in files.items():
            zo.writestr(n, json.dumps(meta) if n == "meta.json" else d)
PY
V=$(cat "$here/VERSION")
pick oldkind.scene.zip "kit editor: Scene refused: not a scene package \(\"kind\": \"scene\"\) \(made with 0\.8\.0-alpha\.1; this is ${V//./\\.}\)"
step 10 "kit editor: the server is Running" 'event kit_edit {"op": "play"}'
m=$(mark "$SL")
# (listed by the client as soon as it is added: the 64 sections go in at
# two a tick, some 2 s)
pick old.scene.zip "kit editor: Added the scene track_4 " \
	"wait_log 60000 kit editor: Added the scene track_4 " \
	'event kit_edit {"op": "list_scene", "name": "track_4", "on": true}'
# (its brick only another version: kept, not named as differing)
await "$SL" "$m" 10 "kitboss adds the scene track_4 \(kitboss/track 1\.0\.0\): .* 0 rows \(1 kept as the game's, 0 refused\), .* decorations \(Running: unlisted\)$"
await "$SL" "$m" 10 "World track_4: the template's 64 edited cells in 64 sections \(0 left out\), put in over ticks"
await "$SL" "$m" 10 "An edit by kitboss: set [0-9]+'s kit/scene_info listed|An edit \(list_scene\) by peer [0-9]+ refused"
tail -c +$((m + 1)) "$SL" | grep -qaE "An edit \(list_scene\) by peer [0-9]+ refused: the scene track_4's World is not ready yet \([0-9]+ sections to go\): list it then" ||
	fail "track_4's list_scene: $(tail -c +$((m + 1)) "$SL" | grep -a "list_scene\|scene_info listed") ($SL)"
await "$SL" "$m" 60 "World track_4: ready, its edited sections in"
edit "An edit by kitboss: set [0-9]+'s kit/scene_info listed to true" \
	'{"op": "list_scene", "name": "track_4", "on": true}'
added_closed
echo "ok: another alpha's (B, Running): the other kind refused, made with 0.8.0-alpha.1; track_4 added, its listing refused until its World's sections were in"
bye
python3 -I - "$t/b/apps/workbench/saves/world/save.sqlite" $SCORE_B <<'PY' || fail "B's save"
import json, sqlite3, sys
db, score = sys.argv[1], int(sys.argv[2])
c = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
rows = dict(((s, k), v) for s, k, v in c.execute("SELECT store, key, value FROM store"))
es = {e["id"]: e for e in json.loads(rows[("kit", "authored")])["entities"]}
scenes = {e["name"]: i for i, e in es.items() if e.get("kind") == "scene"}
assert {"track", "track_2", "track_3", "track_4"} <= set(scenes), scenes
def top(i):
    while es[i].get("parent", 1) != 1:
        i = es[i]["parent"]
    return i
for n in ("track", "track_2", "track_3", "track_4"):
    by ={e.get("name"): e for i, e in es.items() if top(i) == scenes[n]}
    assert {"World", "Timer", "Gate", "Beacon", "Marker"} <= set(by), (n, by)
    links = [l for cm in by["Timer"]["components"] for l in cm.get("links", [])]
    assert [l["to"] for l in links] == [score], (n, links)
    tp = [cm for cm in by["Gate"]["components"] if cm["type"] == "kit/teleporter"][0]
    assert tp["params"]["target"] == score, (n, tp)
assert "#40c0ff" in json.loads(rows[("kit", "type:local/beacon")])["source"]
assert "#40ff40" in json.loads(rows[("kit", "type:local/marker")])["source"]
assert ("kit", "voxel:kitboss/brick") in rows
for n in ("track", "track_2", "track_3", "track_4"):
    assert any(k[1].startswith("hm_edit:%s/" % n) for k in rows), n
print("B's save: 4 scenes added, each its timer's link and its gate's target B's Score; beacon A's, marker B's; the brick and heightmap rows")
PY
echo "PASS: a scene exported (its outside entities named), published, added to another project from the file (a bad file refused, a link left out and listed, a missing type added, a differing one kept as the project's, the World's edits the export's) and from the Aitta (vouched for; another game's after a question); another alpha's added while Running, listed once its World was in (another kind's refusal naming both versions). Screenshots in $t"
