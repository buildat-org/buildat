#!/bin/bash
# tier: full
# needs: pixels
# cost: ~50 s (2026-10-30)
# covers: apps/hearth/main/** src/impl/markup.cpp 3rdparty/Urho3D/Source/Urho3D/UI/Text.cpp
# [HEARTH_POST_STYLE]: the admin's message has bold, an image of its own
# with {.right} before three long paragraphs, the same with {.center},
# and an outside image with {.right}.
#   1. The markup: <strong>; class="right" and class="center" on the own
#      images and their suffixes gone; the outside one's suffix its text.
#   2. The client's view ("hearth: m1" lines, view.png): the parts in
#      order, bold as **, the images where the text has them; the right
#      one beside the first paragraphs and above the last, at the box's
#      right with text to its left; the centred one in the middle; the
#      bold drawn in full white, the plain text not.
#   3. The HTML in headless Chrome (html.png, html_narrow.png): <strong>
#      bold, the right image floated at the box's right with the first
#      paragraph beside it, the centred one in the middle; on a phone's
#      width nothing floats.
#
#   apps/hearth/style_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp hearth_style; t=$CHECK_TMP

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 auto \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

client(){ # log requests commands [env...]
	local log=$1 reqs=$2
	printf "$3" > "$t/cmds"
	shift 3
	env BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" \
		-w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$P \
		-c @"$t/cmds" > "$log" 2>&1 ||
		fail "the drive $log: $(grep -a "Command sequence failed" "$log" | tail -1)"
}
answer(){ # log id
	grep -ao "hr: {.*\"id\":$2,.*" "$1" | head -1
}

# The admin's first login is asked about ntfy in a window over the page
# (mod_tools_check.sh): Don't add, the 300 ms its button drawn
NTFY='wait_log_any 20000 server window: the page ntfy\ndelay 300\nclick Button "Don'"'"'t add"\nwait_log 5000 server window: closed\ndelay 1000\n'
# A 200x150 PNG, all one orange the page has nowhere else
png=$(python3 -c '
import struct, zlib
w, h = 200, 150
def chunk(k, d):
    return struct.pack(">I", len(d)) + k + d + struct.pack(">I", zlib.crc32(k + d))
raw = b"".join(b"\0" + bytes((255, 120, 0)) * w for _ in range(h))
print((b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
    chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")).hex())')
client "$t/up.log" "{\"cmd\":\"new_topic\",\"name\":\"Help\"}
{\"cmd\":\"upload\",\"name\":\"shot.png\",\"data\":\"$png\"}" \
	'wait_log_any 20000 "id":1001,\nwait_log_any 20000 "id":1002,\n'"$NTFY"'quit\n'
id=$(answer "$t/up.log" 1002 | grep -o '"result":{.*' | grep -o '"id":[0-9]*' | cut -d: -f2)
[ -n "$id" ] || fail "the upload: $(answer "$t/up.log" 1002)"
long="the words go on and on so that the paragraph wraps over several lines beside the picture and"
body="Plain then **bold words** here.\\n\\n![shot](/f/$id/thumb){.right}\\n\\nFirst $long $long first.\\n\\nSecond $long $long second.\\n\\nThird $long $long third.\\n\\n![shot](/f/$id/thumb){.center}\\n\\n![far](https://img.example/p.png){.right} after"
client "$t/post.log" "{\"cmd\":\"new_thread\",\"topic\":1,\"title\":\"Style\",\"body\":\"$body\"}" \
	'wait_log_any 20000 "id":1001,\nquit\n'
answer "$t/post.log" 1001 | grep -q '"ok":true' ||
	fail "the thread: $(answer "$t/post.log" 1001)"

# 1. The markup
curl -s "http://127.0.0.1:$P/t/1" > "$t/page"
for want in '<strong>bold words</strong>' \
		"<img src=\"/f/$id/thumb\" alt=\"shot\" class=\"right\" loading=\"lazy\">" \
		"<img src=\"/f/$id/thumb\" alt=\"shot\" class=\"center\" loading=\"lazy\">" \
		'[image: far]</a>{.right} after'; do
	grep -qF "$want" "$t/page" || fail "the markup: no $want ($(grep -a 'shot' "$t/page" | head -3))"
done
grep -aq '}{\.right}\|">{\.center}\|"{\.right}' "$t/page" && fail "an own image's suffix left as text"

# 2. The client's view, once the right image is laid out beside its text
client "$t/view.log" "" "wait_log_any 20000 hearth: m1 beside image $id: \nwait_log_any 20000 hearth: m1 text: [image: far]\ndelay 500\nscreenshot $t/view.png\nquit\n" \
	BUILDAT_HEARTH_OPEN=1
grep -aq "Lua runtime error" "$t/view.log" && fail "a Lua error in the view"
grep -a "hearth: m1 " "$t/view.log" | grep -av "command: \|wait_log\|beside image" |
	sed 's/.*hearth: m1 //' | cut -c1-40 > "$t/parts"
want="text: Plain then **bold words** here.
image: $id right
text: First the words go on and on so that the paragraph
image: $id center
text: [image: far] (https://img.example/p.png){.right} after"
[ "$(cat "$t/parts")" = "$(echo "$want" | cut -c1-40)" ] || fail "the client's parts: $(cat "$t/parts")"
beside=$(grep -ao "hearth: m1 beside image $id: [0-9]* of [0-9]*" "$t/view.log" | tail -1 | sed 's/.*: //')
[ "$beside" = "1 of 3" ] || [ "$beside" = "2 of 3" ] ||
	fail "the paragraphs beside the right image: $beside, not 1 or 2 of 3"
python3 - "$t/view.png" <<'EOF' || fail "the client's view ($t/view.png)"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
px = im.load()
# The orange pictures: their runs of rows, each a box
rows = [y for y in range(h) if any(px[x, y] == (255, 120, 0) for x in range(0, w, 2))]
boxes = []
for y in rows:
    if boxes and y == boxes[-1][3] + 1:
        boxes[-1][3] = y
    else:
        xs = [x for x in range(w) if px[x, y] == (255, 120, 0)]
        boxes.append([min(xs), max(xs), y, y])
if len(boxes) < 2:
    sys.exit("pictures: %s" % boxes)
right, centre = boxes[0], boxes[1]
print("right", right, "centre", centre)
def text_in(x0, x1, y0, y1):
    return sum(1 for y in range(y0, y1) for x in range(x0, x1) if sum(px[x, y]) > 450)
# Text beside the right one, to its left
if text_in(max(0, right[0] - 300), right[0] - 4, right[2], right[3]) < 200:
    sys.exit("no text left of the right picture")
# Nothing beside the centred one, on either side
if text_in(max(0, centre[0] - 150), centre[0] - 4, centre[2] + 5, centre[3] - 5) or \
        text_in(centre[1] + 4, min(w, centre[1] + 150), centre[2] + 5, centre[3] - 5):
    sys.exit("text beside the centred picture")
# The text under the right one is the box's width: the right one ends at
# its right, the centred one's middle is its middle
xs = [x for y in range(right[3] + 4, centre[2] - 4) for x in range(w)
        if sum(px[x, y]) > 450 and x > right[0] - 450]
if not xs:
    sys.exit("no text under the right picture")
left, end = min(xs), max(xs)
print("text under the right picture", left, end)
if abs(right[1] - end) > 12 or abs((centre[0] + centre[1]) / 2 - (left + right[1]) / 2) > 12:
    sys.exit("not at the right / in the middle")
# The bold: brighter than any plain text can be (the plain text's colour is
# about 210 of 255 at most) in the line above the right picture, and none of
# that in the paragraph beside it
white = lambda y0, y1: sum(1 for y in range(y0, y1) for x in range(left, right[0]) if sum(px[x, y]) > 690)
bold = white(right[2] - 40, right[2] - 2)
plain = white(right[2], right[3])
print("white in the bold line", bold, "beside the picture", plain)
if bold < 30 or plain > 0:
    sys.exit("bold not drawn bright, or plain text is")
EOF

# 3. The HTML in Chrome. The page is the server's, not the web client,
# so web/'s age is not this check's (BUILDAT_STALE_OK).
cat > "$t/steps.json" <<EOF
[["nav", "\${URL}t/1"],
 ["until", "[...document.images].every(i => i.complete)", 10],
 ["eval", "(() => { const r = e => e.getBoundingClientRect(), b = r(document.querySelector('.box')), i = r(document.querySelector('img.right')), c = r(document.querySelector('img.center')), p = [...document.querySelectorAll('.box p')].find(p => p.textContent.startsWith('First')), n = document.createRange(); n.selectNodeContents(p); const q = n.getClientRects()[0]; return {strong: getComputedStyle(document.querySelector('strong')).fontWeight, box: [b.left, b.right], right: [i.left, i.right, i.top, i.bottom], first: [q.left, q.right, q.top], centre: [c.left, c.right], float: getComputedStyle(document.querySelector('img.right')).float} })()"],
 ["shot", "\${OUT}/html.png"],
 ["viewport", 380, 800],
 ["eval", "getComputedStyle(document.querySelector('img.right')).float"],
 ["shot", "\${OUT}/html_narrow.png"]]
EOF
BUILDAT_STALE_OK=1 WEB_DRIVE_URL="http://127.0.0.1:$P/" \
	"$here/util/web_drive.sh" chrome hearth "$t/steps.json" "$t/web" > "$t/web.log" 2>&1 ||
	fail "the Chrome drive ($t/web.log): $(tail -3 "$t/web.log")"
# The first paragraph's first line (a Range's first rect: the block itself
# runs under the float) beside the right image, ending left of it
python3 - "$t/web.log" <<'EOF' || fail "the HTML in Chrome ($t/web/html.png)"
import json, sys
ev = [json.loads(l.split("eval: ", 1)[1]) for l in open(sys.argv[1]) if l.startswith("eval: ")]
g, narrow = ev[0], ev[1]
print(g, narrow)
if int(g["strong"]) < 600:
    sys.exit("<strong> not bold")
if g["float"] != "right" or abs(g["right"][1] - g["box"][1]) > 30:
    sys.exit("the right image not floated at the box's right")
if not (g["first"][2] < g["right"][3] and g["first"][2] >= g["right"][2] - 20 and
        g["first"][1] <= g["right"][0]):
    sys.exit("the first paragraph not beside the right image")
if abs((g["centre"][0] + g["centre"][1]) / 2 - (g["box"][0] + g["box"][1]) / 2) > 20:
    sys.exit("the centred image not in the middle")
if narrow != "none":
    sys.exit("floated on a phone's width")
EOF
echo "PASS: bold, an image where the text has it, {.right} beside its paragraphs and {.center} in the middle, in the client and the HTML"
