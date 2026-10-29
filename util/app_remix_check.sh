#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-29)
# covers: src/impl/aitta.cpp src/interface/aitta.h src/client/app_lua.h client/core/aitta/init.lua client/core/aitta/publish.lua client/launch_grid.lua client/api.lua extensions/ui_utils/init.lua builtin/client_data/client_data.cpp apps/aitta/main/main.cpp apps/demo_board_game/meta.json apps/demo_board_game/main/main.cpp apps/demo_board_game/main/client_lua/init.lua
# [APP_REMIX]: an app's settings, "Make my own version", and the version
# published, installed with its base and played, through a local Aitta,
# native. The base is demo_board_game (its settings in its meta.json) as a
# package, tester/boardy 1.0.0, installed on the publisher's user path:
#   1. its tile "boardy: make my own version 1.0.0" makes the remix
#      boardy_mine in dev_apps; on its page the form's Board size is set to
#      6 and the Title to "My board", saved; a blue texture is put in place
#      of main/client_data/green_texture.png (as Open folder would have the
#      player do), which the page then lists; Next, Next, Pack and publish:
#      listed as a remix of tester.boardy 1.0.0;
#   2. crafted ones: a remix carrying client Lua (zipped and signed here,
#      as pack refuses it) is refused by the Aitta and by an install; one
#      whose board_size is 99 is listed (an Aitta has no base to check it
#      against) and refused by an install;
#   3. on a fresh user path, Apps from Aitta's boardy_mine Install: boardy
#      1.0.0 is installed first, then the remix; its tile plays it: the
#      server's board is 6x6, the client's settings say "My board", and the
#      board is drawn blue (the screenshot's pixels).
# simplified: the publish screen is taller than the window, so its Next
# and Pack and publish are reached by keys, as util/world_package_check.sh
# does (the remix's page adds one button before them)
#   util/app_remix_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/Build/bin/buildat"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
python3 -c "import cryptography, PIL" 2>/dev/null || skip "no python3 cryptography and PIL"
check_tmp app_remix; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/aitta.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/aitta" -l 3 ||
	fail "Aitta did not start ($t/aitta.log)"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/aitta.log" | cut -d' ' -f3)

# A user path with only this Aitta, its address already allowed
user(){
	mkdir -p "$t/$1/shared"
	echo "{\"starports\": [], \"aittas\": [\"http://127.0.0.1:$P\"]}" \
		> "$t/$1/starport.json"
	local now; now=$(date +%s)
	printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","","%s","%s","","",""\n' \
		$P $now $now > "$t/$1/network_addresses.csv"
}
user u
user u2
mkdir -p "$t/u/aitta_keys"
"$b" aitta keygen "$t/u/aitta_keys/tester.key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'wait_log_any 30000 "id":2,"ok":\nquit\n' > "$t/admin.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
BUILDAT_AITTA_CODE=$code BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0}}" \
	timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/admin" -C "$t/c_admin" \
	-w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$P -c @"$t/admin.cmds" > "$t/admin.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/admin.log" && grep -aq 'ai: {"id":2,"ok":true' "$t/admin.log" ||
	fail "the bind or the setting did not go through ($t/admin.log)"

# The base: demo_board_game as tester/boardy, its settings the tree's
a=$t/boardy
cp -r ../apps/demo_board_game "$a"
cat > "$a/launcher/init.lua" <<'L'
return function(ctx) return {{id = "play", label = "boardy",
	run = function() ctx.launch{app = "tester.boardy"} end}} end
L
python3 - "$a/meta.json" <<'PY' || fail "boardy's meta.json"
import json, sys
m = json.load(open(sys.argv[1]))
m.update({"author": "tester", "name": "boardy", "version": "1.0.0",
        "engine_api": 2, "license_code": "Apache-2.0",
        "license_media": "CC-BY-SA-3.0", "description": "A board"})
json.dump(m, open(sys.argv[1], "w"))
PY
zip=$("$b" aitta pack "$a" "$t/u/aitta_keys/tester.key" "$t/out" 2>"$t/pack.err") ||
	fail "pack boardy: $(cat "$t/pack.err")"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester/boardy/1.0.0" || fail "publish boardy: $out"
"$b" aitta install "$zip" "$t/u" > /dev/null || fail "install boardy on u"

# A 64x64 PNG of one colour
png(){ python3 - "$@" <<'PY'
import struct, sys, zlib
r, g, b = (int(x) for x in sys.argv[2:5])
raw = b"".join(b"\0" + bytes((r, g, b)) * 64 for _ in range(64))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" +
        chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0)) +
        chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PY
}
png "$t/blue.png" 20 40 230 || fail "the blue texture"

# 1. Made, set in the form and published from the launcher. The texture
# goes in once the remix's folder is there, as the player would put it
r=$t/u/dev_apps/boardy_mine
( for _ in $(seq 600); do
	[ -f "$r/meta.json" ] && mkdir -p "$r/main/client_data" &&
		cp "$t/blue.png" "$r/main/client_data/green_texture.png" && break
	sleep 0.1
done ) &
CHECK_PIDS+=($!)
cat > "$t/make.cmds" <<C
wait_log_any 60000 rows in
delay 500
text make my own
wait_log 10000 rows for "make my own" in
delay 300
click Button "boardy: make my own version*"
wait_log 10000 aitta remix: the page of boardy_mine
delay 500
click LineEdit "10"
keypress End
keypress Backspace
keypress Backspace
text 6
wait_log 5000 aitta remix: board_size = 6
click LineEdit "demo_board_game"
keypress End
$(for _ in $(seq 15); do echo "keypress Backspace"; done)
text My board
wait_log 5000 aitta remix: title = My board
click Button "Save"
wait_log 5000 aitta remix: saved boardy_mine: ok
click Button "Next: the package"
wait_log 5000 aitta publish: the package page, boardy_mine
delay 300
click Button "Settings and files..."
wait_log 5000 aitta remix: the page of boardy_mine (tester.boardy), 1 files of its own
delay 300
screenshot $t/form.png
click Button "Next: the package"
wait_log 5000 aitta publish: the package page, boardy_mine
delay 500
$(for _ in $(seq 17); do echo "keypress Tab"; done)
keypress Return
wait_log 20000 aitta publish: the key page, The key is bound
delay 300
keypress Tab
keypress Tab
keypress Return
wait_log 20000 aitta publish: published tester/boardy_mine/1.0.0
quit
C
run_client 60 "$t/make.log" timeout 240 "$b" -o launch_ui=launch_menu -D "$t/u" \
	-C "$t/c_u" -w 1000x1000 -l 3 -o sound_mute=1 -c @"$t/make.cmds" ||
	fail "the make and publish drive ($t/make.log)"
python3 - "$r/meta.json" "$t/u/aitta_releases/tester-boardy_mine-1.0.0.zip" <<'PY' || fail "the remix's meta.json or release"
import json, sys, zipfile
m = json.load(open(sys.argv[1]))
assert m["kind"] == "remix" and m["base"] == "tester.boardy", m
assert m["base_version"] == "1.0.0", m
v = m["setting_values"]
assert v["board_size"] == 6 and v["title"] == "My board", v
names = sorted(zipfile.ZipFile(sys.argv[2]).namelist())
assert names == ["main/client_data/green_texture.png", "meta.json"], names
PY
curl -s "http://127.0.0.1:$P/api/v1/aitta/list" | python3 -c 'import json, sys
r = [r for r in json.load(sys.stdin)["releases"] if r["name"] == "boardy_mine"][0]
assert r["kind"] == "remix" and r["base"] == "tester.boardy", r
assert r["base_version"] == "1.0.0", r' ||
	fail "the list does not say boardy_mine is a remix of tester.boardy"
curl -s "http://127.0.0.1:$P/" | grep -q "remix of" ||
	fail "Aitta's page does not say boardy_mine is a remix"
echo "ok: a version made from the tile, set in the form, a texture of its own, published as a remix of tester.boardy"

# 2. Crafted: code, and a value out of the base's range
rawsign(){ # dir key base
python3 - "$@" <<'PY'
import hashlib, io, json, os, sys, zipfile
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
app, keyfile, base = sys.argv[1:4]
z = io.BytesIO()
with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as f:
    for d, _, names in os.walk(app):
        for n in names:
            p = os.path.join(d, n)
            f.write(p, os.path.relpath(p, app))
z = z.getvalue()
k = ec.derive_private_key(int(open(keyfile).read().split()[1], 16), ec.SECP256R1())
sha = hashlib.sha256(z).hexdigest()
h = hashlib.sha256(("aitta-release-1\n" + sha).encode()).digest()
pub = k.public_key().public_bytes(serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint).hex()
sig = k.sign(h, ec.ECDSA(utils.Prehashed(hashes.SHA256()))).hex()
os.makedirs(os.path.dirname(base), exist_ok=True)
open(base + ".zip", "wb").write(z)
open(base + ".sig", "w").write(json.dumps({"format": "aitta-release-1",
        "sha256": sha, "key": pub, "signature": sig}) + "\n")
PY
}
manifest(){ # name values
	echo "{\"kind\": \"remix\", \"base\": \"tester.boardy\", \"author\": \"tester\",
 \"name\": \"$1\", \"version\": \"1.0.0\", \"engine_api\": 2, \"license_code\": \"MIT\",
 \"license_media\": \"CC0-1.0\", \"setting_values\": $2}"
}
e=$t/evil
mkdir -p "$e/main/client_lua"
manifest evilmix '{}' > "$e/meta.json"
echo 'buildat.Logger("evilmix"):info("evilmix: ran")' > "$e/main/client_lua/init.lua"
"$b" aitta pack "$e" "$t/u/aitta_keys/tester.key" "$t/out" > /dev/null 2>"$t/pack.err" &&
	fail "pack took a remix carrying client Lua"
grep -q "a remix carries only files" "$t/pack.err" || fail "pack: $(cat "$t/pack.err")"
rawsign "$e" "$t/u/aitta_keys/tester.key" "$t/raw/tester-evilmix-1.0.0" || fail "the raw evilmix"
out=$("$b" aitta publish "$t/raw/tester-evilmix-1.0.0.zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "a remix: main/client_lua/init.lua" ||
	fail "the Aitta did not refuse a remix carrying client Lua: $out"
"$b" aitta install "$t/out/tester-boardy-1.0.0.zip" "$t/u3" > /dev/null || fail "install boardy on u3"
out=$("$b" aitta install "$t/raw/tester-evilmix-1.0.0.zip" "$t/u3" 2>&1) &&
	fail "an install took a remix carrying client Lua: $out"
echo "$out" | grep -q "a remix: main/client_lua/init.lua" || fail "install evilmix: $out"
[ ! -e "$t/u3/installed/tester/evilmix" ] || fail "evilmix was installed"
v=$t/bad
mkdir -p "$v"
manifest badmix '{"board_size": 99}' > "$v/meta.json"
zip=$("$b" aitta pack "$v" "$t/u/aitta_keys/tester.key" "$t/out" 2>"$t/pack.err") ||
	fail "pack badmix: $(cat "$t/pack.err")"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester/badmix/1.0.0" || fail "publish badmix: $out"
out=$("$b" aitta install "$zip" "$t/u3" 2>&1) && fail "an install took board_size 99: $out"
echo "$out" | grep -q "board_size: at most 20" || fail "install badmix: $out"
echo "ok: a remix carrying client Lua refused by pack, the Aitta and an install; board_size 99 refused by an install"

# 3. Installed with its base on a fresh user path, and played
cat > "$t/inst.cmds" <<C
wait_log_any 60000 rows in
delay 500
text apps from aitta
wait_log 10000 rows for "apps from aitta" in
keypress Return
wait_log 20000 aitta page:
wait_log_any 5000 aitta panel:
delay 500
click Button "tester/boardy_mine"
wait_log 5000 aitta panel: tester/boardy_mine 1.0.0
delay 300
click Button "Install"
wait_log 30000 aitta: the base tester/boardy 1.0.0 installed
wait_log 30000 aitta status: Installed tester/boardy_mine 1.0.0
delay 300
keypress Escape
delay 500
text boardy_mine
wait_log 10000 rows for "boardy_mine" in
delay 300
keypress Return
wait_log 300000 drawing a board of 6x6
delay 1000
screenshot $t/played.png
quit
C
run_client 120 "$t/inst.log" timeout 400 "$b" -o launch_ui=launch_menu -D "$t/u2" \
	-C "$t/c_u2" -w 1000x700 -l 3 -o sound_mute=1 -c @"$t/inst.cmds" ||
	fail "the install and play drive ($t/inst.log)"
for p in $(pgrep -f "[b]uildat_server .*-D $t/u2"); do kill $p; done
[ -f "$t/u2/installed/tester/boardy/1.0.0/meta.json" ] || fail "the base was not installed"
[ -f "$t/u2/installed/tester/boardy_mine/1.0.0/main/client_data/green_texture.png" ] ||
	fail "the remix was not installed"
cat "$t"/c_u2/buildat_server*.log | grep -aq "demo_board_game: a board of 6x6" ||
	fail "the server's board is not 6x6 ($t/c_u2/buildat_server*.log)"
grep -aq 'settings: .*\["title"\] = "My board"' "$t/inst.log" ||
	fail "the client's settings do not say My board ($t/inst.log)"
python3 - "$t/played.png" <<'PY' || fail "the board is not blue ($t/played.png)"
from PIL import Image
import sys
im = Image.open(sys.argv[1]).convert("RGB")
px = list(im.getdata())
blue = sum(1 for r, g, b in px if b > 80 and b > r + 50 and b > g + 50)
green = sum(1 for r, g, b in px if g > 80 and g > r + 30 and g > b + 30)
print("blue", blue, "green", green, "of", len(px))
assert blue > len(px) // 5 and green < len(px) // 50
PY
echo "PASS: a remix made in the launcher's form with a texture of its own, published, installed with its base on a fresh user path and played as set; code and a bad value refused"
