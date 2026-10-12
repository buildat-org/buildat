#!/bin/bash
# tier: full
# cost: ~90 s (2026-10-10)
# covers: src/impl/aitta.cpp apps/aitta/main/main.cpp client/launch_grid.lua client/extensions/starport/init.lua client/extensions/aitta/init.lua src/client/main.cpp
# [PACKAGE_MEDIA]: a package's icon and screenshot.
#   1. pack refuses a 300 px icon, a 64x32 one and a GIF screenshot; packs
#      one with a 64 px icon and a JPEG screenshot, and one whose PNG
#      screenshot is named shot.jpg.
#   2. Both published to a local Aitta: the list's entries carry the
#      hashes, /api/aitta/media/<hash> the same bytes as image/jpeg or
#      image/png (by the bytes, not the name), nosniff; an unknown hash
#      404. The list page's box and the package page have the img tags.
#   3. The client: the first installed, its grid tile with the icon (the
#      copy under the cache); Apps from Aitta's rows' icons kept and a
#      row's panel with the screenshot. Screenshots of both.
#   4. [AITTA_PACKAGE_PAGE]: `aitta page` sends m1's page (a description
#      with a link, a <b> and two paragraphs; two screenshots): the
#      package page has, in order, the description, the release's
#      screenshot and the page's two, the page's text with the <b>
#      escaped and the link nofollow, then the releases; the screenshots
#      served. A page signed by an unbound key refused, and the first
#      page's archive sent again (older) refused. Reported as "The page"
#      from the web and delisted by a moderator: the text and its
#      screenshots gone, the release listed; a new page then waits
#      (hidden, a group in the queue) until the group is dismissed.
#   5. The Developer screen: m2 in a user's dev_apps with its key and
#      aitta_page/ (description.txt, a screenshot); Next, "The page on
#      <Aitta>...", a line typed into the description, Send: the package
#      page has the text and the screenshot; aitta_page/ not in the pack.
#
#   util/package_media_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp package_media; t=$CHECK_TMP
b="$here/Build/bin/buildat"
trap check_cleanup EXIT

python3 - "$t" <<'EOF' || fail "the images"
import sys
from PIL import Image
t = sys.argv[1]
Image.new("RGB", (64, 64), (200, 40, 40)).save(t + "/icon.png")
Image.new("RGB", (300, 300), (200, 40, 40)).save(t + "/big.png")
Image.new("RGB", (64, 32), (200, 40, 40)).save(t + "/wide.png")
Image.new("RGB", (640, 360), (40, 40, 200)).save(t + "/shot.jpg", "JPEG")
Image.new("RGB", (320, 180), (40, 200, 40)).save(t + "/shot.png")
Image.new("RGB", (320, 180), (40, 200, 40)).save(t + "/shot.gif")
EOF
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"

# pack <name> <icon file> <screenshot file> <screenshot's name>
pack(){
	rm -rf "$t/app"; mkdir -p "$t/app"
	cp -r ../apps/minigame/main ../apps/minigame/launcher "$t/app/" 2>/dev/null ||
		cp -r "$here/apps/minigame/main" "$here/apps/minigame/launcher" "$t/app/"
	cp "$t/$2" "$t/app/icon.png"; cp "$t/$3" "$t/app/$4"
	printf '{"author": "tester", "name": "%s", "version": "1.0.0",
		"engine_api": 1, "audience": "everyone", "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "a media check", "icon": "icon.png", "screenshot": "%s"}\n' \
		"$1" "$4" > "$t/app/meta.json"
	"$b" aitta pack "$t/app" "$t/key" "$t/out" 2>&1
}

# 1.
out=$(pack m1 big.png shot.jpg shot.jpg) && fail "a 300 px icon packed"
echo "$out" | grep -q "icon.png: 300x300, not 1 to 256 px a side" || fail "300 px: $out"
out=$(pack m1 wide.png shot.jpg shot.jpg) && fail "a 64x32 icon packed"
echo "$out" | grep -q "icon.png: 64x32, not square" || fail "64x32: $out"
out=$(pack m1 icon.png shot.gif shot.gif) && fail "a GIF packed"
echo "$out" | grep -q "shot.gif: not a PNG or a JPEG" || fail "GIF: $out"
z1=$(pack m1 icon.png shot.jpg shot.jpg 2>/dev/null) || fail "pack m1: $z1"
z2=$(pack m2 icon.png shot.png shot.jpg 2>/dev/null) || fail "pack m2: $z2"
echo "ok: pack refuses a 300 px icon, a 64x32 one and a GIF"

# 2.
cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
A=http://127.0.0.1:$P
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
printf 'delay 8000\nquit\n' > "$t/reqs.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$code \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0}}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$t/bind.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"
for z in "$z1" "$z2"; do
	"$b" aitta publish "$z" 127.0.0.1:$P > "$t/pub.out" 2>&1
	grep -q "listed: tester/" "$t/pub.out" || fail "publish: $(cat "$t/pub.out")"
done
curl -s "$A/api/aitta/list" > "$t/list"
curl -s "$A/" > "$t/front"
curl -s "$A/p/tester/m1" > "$t/page"
python3 - "$t" "$A" <<'EOF' || fail "the list or media ($t/list)"
import sys, json, hashlib, urllib.request, urllib.error
t, A = sys.argv[1:3]
s = json.load(open(t + "/list"))
rels = {r["name"]: r for r in (s["releases"] if isinstance(s, dict) else s)}
sha = lambda f: hashlib.sha256(open(t + "/" + f, "rb").read()).hexdigest()
want = {"m1": ("icon.png", "shot.jpg", "image/jpeg"),
	"m2": ("icon.png", "shot.png", "image/png")}
for name, (icon, shot, typ) in want.items():
	r = rels[name]
	assert r["icon"] == sha(icon) and r["screenshot"] == sha(shot), r
	for h, f, ty in ((r["icon"], icon, "image/png"), (r["screenshot"], shot, typ)):
		a = urllib.request.urlopen(A + "/api/aitta/media/" + h)
		assert a.read() == open(t + "/" + f, "rb").read(), f
		assert a.headers["Content-Type"] == ty, (f, a.headers["Content-Type"])
		assert a.headers["X-Content-Type-Options"] == "nosniff"
try:
	urllib.request.urlopen(A + "/api/aitta/media/" + "0" * 64)
	assert False, "an unknown hash served"
except urllib.error.HTTPError as e:
	assert e.code == 404
front, page = open(t + "/front").read(), open(t + "/page").read()
img = '<img src="/api/aitta/media/' + rels["m1"]["icon"] + '"'
assert img in front, "no icon in the list page's box"
assert img in page[:page.index("</h1>")], "no icon in the heading"
assert '<img src="/api/aitta/media/' + rels["m1"]["screenshot"] + '"' in page, "no screenshot"
open(t + "/icon_hash", "w").write(rels["m1"]["icon"])
EOF
echo "ok: listed with the hashes, served the same bytes by their type; the pages' img tags"

# 3.
h=$(cat "$t/icon_hash")
"$b" aitta install "$z1" "$t/u" > /dev/null 2>&1 || fail "install"
echo "{\"aittas\": [\"$A\"]}" > "$t/managed.json"
cat > "$t/cmds" <<C
delay 4000
text minigame
delay 1000
event scan grid
screenshot $t/grid.png
keypress Escape
delay 500
text apps from aitta
delay 1000
keypress Return
wait_log 10000 Asking the user about $A
delay 1000
keypress Return
delay 4000
delay 2000
event scan rows
screenshot $t/rows.png
click Button "tester/m2"
wait_log 10000 aitta panel: screenshot
delay 1000
screenshot $t/panel.png
quit
C
BUILDAT_STARPORT_MANAGED="$t/managed.json" timeout 120 "$b" \
	-m launch_menu -D "$t/u" -C "$t/cache" -w 1024x700 -l 3 -o sound_mute=1 -c @"$t/cmds" \
	> "$t/cl.log" 2>&1
grep -aq "Command sequence complete" "$t/cl.log" ||
	fail "the drive ($(grep -a "Command seq\|aitta\|Asking" "$t/cl.log" | tail -4))"
ls "$t"/cache*/package_media/$h.png > /dev/null 2>&1 ||
	fail "the installed app's icon not under the cache"
grep -a "scan grid: " "$t/cl.log" | grep -aq "$h.png" ||
	fail "the tile: $(grep -a "scan grid: .*minigame" "$t/cl.log" | head -3)"
grep -a "scan rows: " "$t/cl.log" | grep -ac "$h.png" | grep -q "^2$" ||
	fail "the rows' icons: $(grep -a "scan rows: .*image" "$t/cl.log" | head -4)"
grep -aq "aitta panel: screenshot .*\.png$" "$t/cl.log" || fail "no screenshot in the panel"
echo "ok: the grid's tile, the rows' icons and the panel's screenshot (see $t/{grid,rows,panel}.png)"

# 4.
reqs(){ # log requests...
	local log=$1; shift
	printf 'delay 8000\nquit\n' > "$t/reqs.cmds"
	BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
		BUILDAT_AITTA_REQS="$(printf '%s\n' "$@")" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
		-s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$log" 2>&1
}
mkdir -p "$t/pdir"
printf 'First <b>bold</b> line.\nSee https://example.org/x?a=1&b=2.\n\nSecond paragraph.\n' \
	> "$t/pdir/description.txt"
python3 -c '
import sys
from PIL import Image
Image.new("RGB", (200, 100), (250, 250, 0)).save(sys.argv[1] + "/a.png")
Image.new("RGB", (100, 200), (0, 250, 250)).save(sys.argv[1] + "/b.jpg", "JPEG")
' "$t/pdir"
"$b" aitta page 127.0.0.1:$P tester/m1 "$t/pdir" "$t/key" > "$t/page.out" 2>&1
grep -q "^page: tester/m1$" "$t/page.out" || fail "aitta page: $(cat "$t/page.out")"
cp "$t/pdir/.packed/tester-m1-page.zip" "$t/old-page.zip"
cp "$t/pdir/.packed/tester-m1-page.sig" "$t/old-page.sig"
curl -s "$A/p/tester/m1" > "$t/page.html"
python3 - "$t" "$A" <<'EOF2' || fail "the package page ($t/page.html)"
import sys, hashlib, urllib.request
t, A = sys.argv[1:3]
s = open(t + "/page.html").read()
sha = lambda f: hashlib.sha256(open(t + "/" + f, "rb").read()).hexdigest()
order = [s.index("</h1>"), s.index("a media check"), s.index(sha("shot.jpg")),
	s.index(sha("pdir/a.png")), s.index(sha("pdir/b.jpg")),
	s.index("First &lt;b&gt;bold&lt;/b&gt; line.<br>"),
	s.index('<a href="https://example.org/x?a=1&amp;b=2" rel="nofollow noopener">'),
	s.index("<p>Second paragraph.</p>"), s.index('<div class="box">')]
assert order == sorted(order), order
assert "<b>bold" not in s
assert '<option value="tester/m1">The page</option>' in s
for f in ("pdir/a.png", "pdir/b.jpg"):
	assert urllib.request.urlopen(A + "/api/aitta/media/" + sha(f)).read() == \
		open(t + "/" + f, "rb").read(), f
EOF2
"$b" aitta keygen "$t/key2" > /dev/null 2>&1
"$b" aitta page 127.0.0.1:$P tester/m1 "$t/pdir" "$t/key2" 2>&1 |
	grep -q "not bound" || fail "a page by an unbound key"
"$b" aitta page 127.0.0.1:$P tester/m1 "$t/pdir" "$t/key" > /dev/null 2>&1 ||
	fail "a second page"
out=$("$b" aitta publish "$t/old-page.zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "as new as this or newer" || fail "an older page: $out"
echo "ok: aitta page: the package page in order, escaped, linked; another key and an older page refused"
curl -s -d "release=tester/m1&reason=spam&text=ads" "$A/api/aitta/report" | grep -q "Sent" ||
	fail "the page's report"
reqs "$t/decide.log" \
	'{"cmd":"mod_decide","group":"tester/m1|spam","decision":"uphold","action":"delist","text":"ads"}'
grep -aq 'ai: {"id":1,"ok":true' "$t/decide.log" ||
	fail "the delist: $(grep -a 'ai: ' "$t/decide.log")"
curl -s "$A/p/tester/m1" > "$t/page.html"
grep -q "Second paragraph" "$t/page.html" && fail "the delisted page's text shown"
grep -q "$(sha256sum < "$t/pdir/a.png" | cut -d' ' -f1)" "$t/page.html" &&
	fail "the delisted page's screenshot shown"
grep -q '<div class="box">' "$t/page.html" || fail "the release went with the page"
curl -s -o /dev/null -w '%{http_code}' "$A/api/aitta/media/$(sha256sum < "$t/pdir/a.png" | cut -d' ' -f1)" |
	grep -q 404 || fail "the delisted page's screenshot served"
echo "Third." > "$t/pdir/description.txt"
"$b" aitta page 127.0.0.1:$P tester/m1 "$t/pdir" "$t/key" 2>&1 | grep -q "waits for a moderator" ||
	fail "a page after the delist not held"
curl -s "$A/p/tester/m1" | grep -q "Third." && fail "the held page shown"
reqs "$t/dismiss.log" \
	'{"cmd":"mod_decide","group":"tester/m1|other","decision":"dismiss","text":"fine now"}'
grep -aq 'ai: {"id":1,"ok":true' "$t/dismiss.log" ||
	fail "the dismiss: $(grep -a 'ai: ' "$t/dismiss.log")"
curl -s "$A/p/tester/m1" | grep -q "<p>Third.</p>" || fail "the page not shown after the dismiss"
echo "ok: reported, delisted (the release stays); the next held until a moderator lets it"

# 5.
d="$t/dev/dev_apps/m2"
mkdir -p "$d/aitta_page" "$t/dev/aitta_keys"
cp -r "$t/app/main" "$t/app/launcher" "$t/app/meta.json" "$t/app/icon.png" "$t/app/shot.jpg" "$d/"
sed -i 's/"name": "m[0-9]"/"name": "m2"/' "$d/meta.json"
cp "$t/key" "$t/dev/aitta_keys/tester.key"
printf 'Fourth' > "$d/aitta_page/description.txt"
cp "$t/pdir/b.jpg" "$d/aitta_page/1.jpg"
echo "{\"starports\": [], \"aittas\": [\"$A\"]}" > "$t/dev/starport.json"
now=$(date +%s)
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","%s","","%s","%s","","",""\n' \
	"$A" $now $now > "$t/dev/network_addresses.csv"
cat > "$t/dev.cmds" <<C
delay 5000
text publish
delay 1500
keypress Return
delay 1500
event scan p1
click Button "Next: key*"
delay 3000
event scan p2
click Button "The page on*"
delay 1500
click LineEdit "*"
keypress End
keypress Return
text typed
delay 500
screenshot $t/dev_page.png
click Button "Send"
delay 3000
event scan p3
screenshot $t/dev_sent.png
quit
C
timeout 120 "$b" -o launch_ui=launch_menu -D "$t/dev" -C "$t/dev_cache" -w 1024x700 -l 3 \
	-o sound_mute=1 -c @"$t/dev.cmds" > "$t/dev.log" 2>&1
grep -aq "Command sequence complete" "$t/dev.log" ||
	fail "the Developer drive ($(grep -a "Command seq" "$t/dev.log" | tail -2))"
grep -aq 'scan p3: .*text "Sent: tester/m2"' "$t/dev.log" ||
	fail "not sent: $(grep -a 'scan p3: .*Sent\|scan p3: .*Not sent' "$t/dev.log" | head -3)"
curl -s "$A/p/tester/m2" > "$t/m2.html"
grep -q "<p>Fourth<br>typed</p>" "$t/m2.html" || fail "the text from the screen ($t/m2.html)"
grep -q "$(sha256sum < "$d/aitta_page/1.jpg" | cut -d' ' -f1)" "$t/m2.html" ||
	fail "the screenshot from aitta_page/"
grep -aq 'scan p2: .*text "aitta_page' "$t/dev.log" && fail "aitta_page/ in the files packed"
echo "ok: the Developer screen's page sent ($t/dev_page.png)"
echo "PASS"
