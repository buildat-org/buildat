#!/bin/bash
# tier: quick
# ci
# cost: ~40 s (2026-10-09)
# covers: apps/hearth/main/** src/impl/markup.cpp
# [HEARTH_LINES_CODE]: the admin's message has single newlines, a drawn
# image of its own (linked, as the File... button writes it), an outside
# image and a fenced block.
#   1. The web page: a newline is <br>, the block one <pre><code>.
#   2. The client's view ("hearth: m<id>" lines of a scripted client): the
#      lines broken, no image's Markdown, the own image apart where the text
#      has it ([HEARTH_POST_STYLE]), the outside image as its alt and
#      address, the block apart as code without its fences; a screenshot.
#   3. The reply field's "Code block": its fences round what is typed next.
#
#   apps/hearth/lines_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp hearth_lines; t=$CHECK_TMP

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

# A 3x2 PNG
png=89504e470d0a1a0a0000000d49484452000000030000000208060000009d74661a0000001149444154789c63687050f80fc30cc81c008df50b3be56bccc90000000049454e44ae426082
client "$t/up.log" "{\"cmd\":\"new_topic\",\"name\":\"Help\"}
{\"cmd\":\"upload\",\"name\":\"shot.png\",\"data\":\"$png\"}" \
	'wait_log_any 20000 "id":1001,\nwait_log_any 20000 "id":1002,\nquit\n'
id=$(answer "$t/up.log" 1002 | grep -o '"result":{.*' | grep -o '"id":[0-9]*' | cut -d: -f2)
[ -n "$id" ] || fail "the upload: $(answer "$t/up.log" 1002)"
body="one\\ntwo\\n\\n[![shot](/f/$id/thumb)](/f/$id/shot.png)\\n\\n![far](https://img.example/p.png)\\n\\n\`\`\`sh\\nmake -j8 2>&1 | tail\\n  x < 1\\n\`\`\`\\n\\nafter"
client "$t/post.log" "{\"cmd\":\"new_thread\",\"topic\":1,\"title\":\"Lines\",\"body\":\"$body\"}" \
	'wait_log_any 20000 "id":1001,\nquit\n'
answer "$t/post.log" 1001 | grep -q '"ok":true' ||
	fail "the thread: $(answer "$t/post.log" 1001)"

# 1. The web page
curl -s "http://127.0.0.1:$P/t/1" > "$t/page"
grep -qPz '<p>one<br>\ntwo</p>' "$t/page" || fail "no <br> on the page"
grep -qPz '<pre><code>make -j8 2&gt;&amp;1 \| tail\n  x &lt; 1\n</code></pre>' "$t/page" ||
	fail "the block on the page: $(grep -a -A3 '<pre>' "$t/page" | head -4)"

# 2. The client's view: the thread drawn to its last part, and the half
# second after it is the page laid out
V='wait_log_any 20000 hearth: m1 text: after\ndelay 500\n'
client "$t/view.log" "" "${V}screenshot $t/view.png\nquit\n" \
	BUILDAT_HEARTH_OPEN=1
grep -a "hearth: m1 " "$t/view.log" | grep -av "command: \|wait_log" | sed 's/.*hearth: m1 //' > "$t/parts"
want="text: one|two
image: $id
text: [image: far] (https://img.example/p.png)
code: make -j8 2>&1 | tail|  x < 1
text: after"
[ "$(cat "$t/parts")" = "$want" ] ||
	fail "the client's parts: $(cat "$t/parts")"
grep -aq "Lua runtime error" "$t/view.log" && fail "a Lua error in the view"

# 3. "Code block" in the reply field, Ctrl+Enter sends, and the reply is
# answered. The 100 ms are Ctrl's hold round the Enter.
# simplified: Escape with a message selected focuses the composer and logs
# nothing; the half second after it is the page settling before the
# click at the field's pixels. A click's focus lands a frame or two on:
# the 200 ms after each before the text, and after each text the
# typing taken before Ctrl+Enter
client "$t/reply.log" "" "${V}"'keypress Escape\ndelay 500\nmouse_pos 450 325\nmouse_click left\ndelay 200\ntext see:\ndelay 200\nclick Button "Code block"\ndelay 200\ntext ls -l\ndelay 200\nkeydown ctrl\ndelay 100\nkeypress Return\ndelay 100\nkeyup ctrl\nwait_log_any 10000 hearth: reply sent in thread\nquit\n' \
	BUILDAT_HEARTH_OPEN=1
curl -s "http://127.0.0.1:$P/t/1" > "$t/page"
grep -qPz '<p>see:</p>\n<pre><code>ls -l\n</code></pre>' "$t/page" ||
	fail "Code block's reply: $(grep -a -B1 -A2 'see:' "$t/page" | head -4)"
echo "PASS: a newline is <br> and a block one <pre> on the web; the client draws the lines, the block as code, no image's Markdown; Code block's fences (see $t/view.png)"
