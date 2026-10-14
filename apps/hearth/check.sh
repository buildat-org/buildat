#!/bin/bash
# tier: full
# needs: pixels
# cost: 1 min (a first run compiles the app, 2026-10-04)
# covers: apps/hearth/** src/interface/web_brand.h builtin/network/** 3rdparty/sqlite/CMakeLists.txt
# [HEARTH_MVP] step 1, **the groundwork**:
#   1. the admin (the setup code) adds a topic and a subtopic (not a
#      subtopic's subtopic), starts a thread whose title
#      and message carry markup, replies and edits the reply; adds bob;
#   2. bob replies, and may neither add a topic nor edit the admin's
#      message, nor post a control character, nor say what answered it;
#   3. the admin marks bob's reply the answer and mentions him: bob has
#      both notifications, the admin one for bob's reply;
#   4. a chat: bob has the thread open, the admin writes, and bob's client
#      has the line within two seconds;
#   5. the HTML face: the portal, the topic, the thread (every message,
#      the markup escaped, the edit shown), a message's own page, search
#      (with a hostile query), a 404 for what is not there -- and the web
#      client's page still the web client's;
#   6. a new account's limits (two threads a day, edits count
#      as messages) and a report's handling: carol reports bob's thread,
#      the admin hides it with a statement (gone from the portal and search,
#      the notice on its page, bob notified with the statement), bob
#      appeals (and may not edit it while hidden), carol sees neither
#      its title nor its messages by packet or /m/, the admin restores; then the search limit per
#      address and per account.
#   7. files: a new account uploads none; a JPEG comes back within 1080p
#      and without its EXIF; over the budget an unused one is crushed again,
#      and past its time deleted.
#   8. a tracker ([HEARTH_TRACKER]): a new account's patch, shown inline
#      and applied with git am; links and tracker links by the domains.
#  12. [TRUST_LADDER]: a new account's link held, one at a time, approved
#      by a helper the admin made, which trusts its author; a helper makes
#      no helper and takes back only its own approval; reports from one
#      network count once, a helper's hides until a moderator looks, and
#      a dismissal shows the message again.
#
#   apps/hearth/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
P=29881
U=http://127.0.0.1:$P

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 $P \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
pid=$SERVER_PID
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "Hearth did not start (srv.log: $(tail -3 "$t/srv.log"))"

# A client quits once each request is answered and each line of WAIT is
# logged, or CMDS is its drive; a missed wait fails the check
client(){ # name password log requests [env...]
	local n=$1 pw=$2 log=$3 reqs=$4 i=0 w
	shift 4
	if [ -n "${CMDS:-}" ]; then
		printf '%b' "$CMDS"
	else
		echo "wait_log_any 20000 Joined as"
		while IFS= read -r w; do
			[ -n "$w" ] && i=$((i + 1)) && echo "wait_log_any 10000 \"id\":$((1000 + i)),"
		done <<< "$reqs"
		while IFS= read -r w; do
			[ -n "$w" ] && echo "wait_log_any 10000 $w"
		done <<< "${WAIT:-}"
		echo quit
	fi > "$t/cmds_$n"
	# CREATE: an unknown name is made rather than refused; a known one logs in
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw BUILDAT_HEARTH_CREATE=1 \
		BUILDAT_HEARTH_CODE=$code BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" -w 800x600 -l 3 -o sound_mute=1 \
		-s 127.0.0.1:$P -c @"$t/cmds_$n" > "$log" 2>&1 ||
		fail "the client $n ($log): $(grep -a "Command sequence failed\|an error the drive" "$log" | tail -2)"
}
answer(){ # log id
	grep -ao "hr: {.*\"id\":$2,.*" "$1" | head -1
}

# 1. The admin
client admin checkpass12 "$t/admin.log" '{"cmd":"new_topic","name":"Help","about":"Questions & answers"}
{"cmd":"new_thread","topic":1,"title":"Lights <b>out</b>","body":"My <script>alert(1)</script> lamp\n\nsecond paragraph about shadows"}
{"cmd":"reply","thread":1,"body":"Try pbr"}
{"cmd":"edit","message":2,"body":"Try the pbr render mode"}
{"cmd":"new_thread","topic":9,"title":"x","body":"y"}
{"cmd":"new_topic","name":"Lamps","parent":1}
{"cmd":"new_topic","name":"Deeper","parent":2}' \
	"BUILDAT_HEARTH_ADMIN=add bob bobpass1234"
for i in 1001 1002 1003 1004; do
	answer "$t/admin.log" $i | grep -q '"ok":true' ||
		fail "the admin's request $i: $(answer "$t/admin.log" $i)"
done
answer "$t/admin.log" 1005 | grep -q "no such topic" ||
	fail "a thread in no topic: $(answer "$t/admin.log" 1005)"
answer "$t/admin.log" 1006 | grep -q '"ok":true' ||
	fail "a subtopic: $(answer "$t/admin.log" 1006)"
answer "$t/admin.log" 1007 | grep -q "cannot have subtopics" ||
	fail "a subtopic's subtopic: $(answer "$t/admin.log" 1007)"

# 2. bob
client bob bobpass1234 "$t/bob.log" '{"cmd":"reply","thread":1,"body":"bob was here"}
{"cmd":"new_topic","name":"Mine"}
{"cmd":"edit","message":1,"body":"bob wrote this"}
{"cmd":"reply","thread":1,"body":"a\u0007bell"}
{"cmd":"answered","thread":1,"message":3}'
answer "$t/bob.log" 1001 | grep -q '"ok":true' ||
	fail "bob's reply: $(answer "$t/bob.log" 1001) ($(grep -a "accounts" "$t/bob.log" | tail -2))"
answer "$t/bob.log" 1002 | grep -q "only a Steward" || fail "bob added a topic"
answer "$t/bob.log" 1003 | grep -q "only its author" || fail "bob edited the admin's"
answer "$t/bob.log" 1004 | grep -q "control character" || fail "a control character went in"
answer "$t/bob.log" 1005 | grep -q "only whoever started" || fail "bob marked the answer"

# 3. The answer, a mention, the notifications
client admin checkpass12 "$t/admin2.log" '{"cmd":"answered","thread":1,"message":3}
{"cmd":"answered","thread":1,"message":1}
{"cmd":"reply","thread":1,"body":"thanks @bob, and mail@bob.example is no one"}
{"cmd":"notifications"}
{"cmd":"answered","thread":1,"message":0}
{"cmd":"answered","thread":1,"message":3}'
answer "$t/admin2.log" 1001 | grep -q '"ok":true' || fail "the answer: $(answer "$t/admin2.log" 1001)"
answer "$t/admin2.log" 1002 | grep -q "not a reply" || fail "the question as its own answer"
answer "$t/admin2.log" 1004 | grep -q '"by":"bob","id":[0-9]*,"kind":"reply"' ||
	fail "the admin's notification of bob's reply: $(answer "$t/admin2.log" 1004)"
client bob bobpass1234 "$t/bob2.log" '{"cmd":"notifications"}'
n=$(answer "$t/bob2.log" 1001)
echo "$n" | grep -q '"kind":"mention"' && echo "$n" | grep -q '"kind":"answer"' ||
	fail "bob's notifications: $n"
[ "$(echo "$n" | grep -o '"kind"' | wc -l)" = 2 ] ||
	fail "bob has other than the mention and the answer (given twice, told once): $n"
# The launcher's count ([FORUM] 4): bob's kept login asks /unseen without
# a join; another token is refused
client bob bobpass1234 "$t/bob_keep.log" '' BUILDAT_HEARTH_KEEP=1
tok=$(cat "$(find "$t/cl_bob" -path '*/servers/*/token' | head -1)" 2>/dev/null)
[ -n "$tok" ] || fail "bob's kept login: $(find "$t/cl_bob" -name token)"
curl -s -X POST -d "{\"name\":\"bob\",\"token\":\"$tok\"}" "$U/unseen" |
	grep -q '^{"unseen":[0-9]*}$' || fail "the launcher's count"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
		-d '{"name":"bob","token":"x"}' "$U/unseen")" = 403 ] ||
	fail "a count for a token that is no login"

# 4. A chat: bob has thread 1 open, the admin writes in it
CMDS='wait_log_any 30000 a live line\nquit\n' \
	client bob bobpass1234 "$t/watch.log" '' BUILDAT_HEARTH_OPEN=1 &
w=$!
# The thread drawn: its first message
for _ in $(seq 150); do
	grep -aq "hearth: m1 text" "$t/watch.log" 2>/dev/null && break
	kill -0 $w 2>/dev/null || break
	sleep 0.2
done
grep -aq "hearth: m1 text" "$t/watch.log" || { kill $w; fail "bob's thread did not open ($t/watch.log)"; }
WAIT='admin result: ' client admin checkpass12 "$t/admin3.log" '{"cmd":"reply","thread":1,"body":"a live line"}' \
	"BUILDAT_HEARTH_ADMIN=add carol carolpass1234"
wait $w || fail "bob's watching client"
ms(){ # the first log line matching, as milliseconds of the day
	grep -a "$2" "$1" | head -1 | grep -o "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]*" |
		awk -F'[:.]' '{print (($1*60+$2)*60+$3)*1000+$4}'
}
sent=$(ms "$t/admin3.log" '"id":1001,"ok":true')
got=$(ms "$t/watch.log" 'hr: .*a live line')
[ -n "$sent" ] && [ -n "$got" ] || fail "the live line did not reach bob ($sent, $got)"
echo "a chat line reached the other client in $((got - sent)) ms"
[ $((got - sent)) -lt 2000 ] || fail "the line took over two seconds"

# 5. The HTML face
get(){ curl -s -o "$t/page" -w '%{http_code}' "$U$1"; }
[ "$(get /)" = 200 ] && grep -q 'href="/topic/1">Help' "$t/page" &&
	grep -q 'href="/t/1">Lights &lt;b&gt;out' "$t/page" || fail "the portal"
[ "$(get /topic/1)" = 200 ] && grep -q "Questions &amp; answers" "$t/page" &&
	grep -q "answered, admin" "$t/page" || fail "the topic"
[ "$(get /t/1)" = 200 ] || fail "the thread is not served"
grep -q "<script>" "$t/page" && fail "a message's markup reached the page"
grep -q "&lt;script&gt;alert(1)&lt;/script&gt; lamp</p>" "$t/page" ||
	fail "the first message as escaped text"
grep -q "Try the pbr render mode" "$t/page" && grep -q "(edited" "$t/page" ||
	fail "the edit"
grep -q 'id="m3"' "$t/page" && grep -q "bob was here" "$t/page" || fail "bob's reply"
# The answer just after the question
[ "$(grep -o 'id="m[0-9]*"' "$t/page" | head -2 | tr '\n' ' ')" = 'id="m1" id="m3" ' ] &&
	grep -q "This answered it:" "$t/page" || fail "the answer is not under the question"
[ "$(get /m/3)" = 200 ] && grep -q 'href="/t/1#m3"' "$t/page" || fail "a message's page"
[ "$(get "/search?q=shad")" = 200 ] && grep -q "<mark>shadows</mark>" "$t/page" &&
	grep -q 'href="/t/1#m1"' "$t/page" || fail "search: $(grep -a '<li>' "$t/page")"
[ "$(get "/search?q=%22)%20OR%20*%20NEAR(")" = 200 ] || fail "a hostile search"
for p in /t/99 /t/x /topic/ /m/; do
	[ "$(get $p)" = 404 ] || fail "$p is not a 404"
done
grep -q "Hearth" <(curl -s "$U/index.html") && fail "/index.html is Hearth's"
# [HTML_BRAND]: the font and the logo from the page's own origin
[ "$(get /brand/overpass.ttf)" = 200 ] && [ "$(get /brand/logo.png)" = 200 ] ||
	fail "the brand's files"
[ "$(get /)" = 200 ] && grep -Eq '(src=|url\()"?(https?:)?//' "$t/page" &&
	fail "the portal loads from another origin"

# 6. A new account's limits, a report, a hide, an appeal
client bob bobpass1234 "$t/bob6.log" '{"cmd":"me"}
{"cmd":"new_thread","topic":1,"title":"Cheap lamps","body":"Cheap lamps for everyone"}
{"cmd":"new_thread","topic":1,"title":"More","body":"one more"}
{"cmd":"new_thread","topic":1,"title":"Again","body":"and again"}
{"cmd":"report","message":3,"reason":"mine"}
{"cmd":"me"}'"$(
	for i in $(seq 10); do printf '\n{"cmd":"edit","message":3,"body":"b%s"}' $i; done)"
grep -aq 'hr: {.*"level":0' "$t/bob6.log" || fail "bob is not a new account"
answer "$t/bob6.log" 1002 | grep -q '"result":2' || fail "bob's thread: $(answer "$t/bob6.log" 1002)"
answer "$t/bob6.log" 1003 | grep -q '"ok":true' || fail "bob's second thread"
answer "$t/bob6.log" 1004 | grep -q "2 new threads a day" || fail "a third thread in a day"
answer "$t/bob6.log" 1005 | grep -q "one's own" || fail "bob reported his own"
answer "$t/bob6.log" 1016 | grep -q "messages an hour" || fail "edits without a limit"
client carol carolpass1234 "$t/carol.log" '{"cmd":"report","message":6,"reason":"spam"}
{"cmd":"report","message":6,"reason":"spam!"}
{"cmd":"report","message":2,"reason":"rude"}'
answer "$t/carol.log" 1001 | grep -q '"result":1' || fail "carol's report: $(answer "$t/carol.log" 1001)"
answer "$t/carol.log" 1002 | grep -q "waiting already" || fail "a report twice"
answer "$t/carol.log" 1003 | grep -q '"result":2' || fail "carol's second report"
client admin checkpass12 "$t/admin6.log" '{"cmd":"queue"}
{"cmd":"moderate","report":1,"action":"hide"}
{"cmd":"moderate","report":1,"action":"hide","statement":"Advertising"}
{"cmd":"moderate","report":2,"action":"dismiss"}
{"cmd":"queue"}'
answer "$t/admin6.log" 1001 | grep -q '"body":"Cheap lamps for everyone".*"reason":"rude"' ||
	fail "the queue: $(answer "$t/admin6.log" 1001)"
answer "$t/admin6.log" 1002 | grep -q "the statement" || fail "a hide without a statement"
answer "$t/admin6.log" 1003 | grep -q '"ok":true' || fail "the hide: $(answer "$t/admin6.log" 1003)"
answer "$t/admin6.log" 1004 | grep -q '"ok":true' || fail "the dismissal"
answer "$t/admin6.log" 1005 | grep -q '"result":\[\]' || fail "the queue after"
get / > /dev/null; grep -q 'href="/t/2"' "$t/page" && fail "a hidden thread on the portal"
[ "$(get /t/2)" = 200 ] && grep -q "Hidden by a Steward: Advertising" "$t/page" ||
	fail "the hidden thread's page"
grep -q "Cheap lamps" "$t/page" && fail "a hidden message's text on its page"
get "/search?q=cheap" > /dev/null; grep -q '/t/2#' "$t/page" && fail "search finds a hidden message"
[ "$(get /m/6)" = 200 ] && fail "a hidden thread's message has a page"
client carol carolpass1234 "$t/carol3.log" '{"cmd":"thread","thread":2}'
answer "$t/carol3.log" 1001 | grep -q '"title":"A hidden thread"' &&
	! answer "$t/carol3.log" 1001 | grep -q "Cheap lamps" ||
	fail "a hidden thread by packet: $(answer "$t/carol3.log" 1001)"
client bob bobpass1234 "$t/bob7.log" '{"cmd":"notifications"}
{"cmd":"thread","thread":2}
{"cmd":"appeal","message":6,"text":"It is a real offer"}
{"cmd":"appeal","message":6,"text":"really"}
{"cmd":"edit","message":6,"body":"An honest offer"}' BUILDAT_HEARTH_OPEN=2
grep -a "attempt to\|stack traceback" "$t/bob7.log" && fail "the hidden thread's page"
answer "$t/bob7.log" 1001 | grep -q '"kind":"hidden".*"note":"Advertising"' ||
	fail "bob's notification of the hide: $(answer "$t/bob7.log" 1001)"
answer "$t/bob7.log" 1002 | grep -q '"body":"Cheap lamps for everyone"' ||
	fail "the author does not see his hidden message"
answer "$t/bob7.log" 1003 | grep -q '"result":3' || fail "the appeal: $(answer "$t/bob7.log" 1003)"
answer "$t/bob7.log" 1004 | grep -q "waiting already" || fail "an appeal twice"
answer "$t/bob7.log" 1005 | grep -q "a hidden message is not edited" ||
	fail "a hidden message edited: $(answer "$t/bob7.log" 1005)"
client admin checkpass12 "$t/admin7.log" '{"cmd":"moderate","report":3,"action":"hide","statement":"x"}
{"cmd":"moderate","report":3,"action":"restore"}'
answer "$t/admin7.log" 1001 | grep -q "restored or dismissed" || fail "an appeal hidden"
answer "$t/admin7.log" 1002 | grep -q '"ok":true' || fail "the restore: $(answer "$t/admin7.log" 1002)"
get /t/2 > /dev/null; grep -q "Cheap lamps for everyone" "$t/page" &&
	! grep -q "Hidden by a Steward" "$t/page" || fail "the restored thread"
get "/search?q=cheap" > /dev/null; grep -q '/t/2#m6' "$t/page" || fail "search after the restore"
n429=0
for _ in $(seq 40); do
	[ "$(get "/search?q=x")" = 429 ] && n429=$((n429 + 1))
done
[ $n429 -gt 0 ] || fail "no search limit per address"
client carol carolpass1234 "$t/carol2.log" "$(
	for i in $(seq 31); do echo '{"cmd":"search","q":"lamps"}'; done)"
answer "$t/carol2.log" 1030 | grep -q '"ok":true' || fail "carol's search"
answer "$t/carol2.log" 1031 | grep -q "too many searches" ||
	fail "no search limit per account"

# 7. The markup: CommonMark with GitHub's additions, raw HTML as text, no
# link or image to anything but http, https, mailto or a relative path
client admin checkpass12 "$t/admin8.log" '{"cmd":"reply","thread":1,"body":"**bold** _em_ ~~del~~ `code`\n\n<script>x()</script> <img src=x onerror=y()>\n\n[js](javascript:alert(1)) [tab](<java\tscript:alert(2)>) [up](JAVASCRIPT:alert(4)) [ent](java&#115;cript:alert(3)) [ok](https://buildat.org/a?b=1&c=2) ![pic](https://img.example/p.png \"t\")\n\n| a | b |\n|---|--:|\n| 1 | 2 |\n\n- [x] done\n- [ ] not\n\n> quoted ||secret||\n\n```\n<b>raw</b>\n```\n\nsee www.lamps.example\n\n#1 and not a#2, #3x or `#4`\n\nhi @carol, not me@x.example"}'
answer "$t/admin8.log" 1001 | grep -q '"ok":true' || fail "the markup reply: $(answer "$t/admin8.log" 1001)"
get /t/1 > /dev/null
for want in "<strong>bold</strong> <em>em</em> <del>del</del> <code>code</code>" \
		"<p>&lt;script&gt;x()&lt;/script&gt; &lt;img src=x onerror=y()&gt;</p>" \
		'<a href="https://buildat.org/a?b=1&amp;c=2" rel="nofollow ugc">ok</a>' \
		'<a href="https://img.example/p.png" title="t" rel="nofollow ugc">[image: pic]</a>' \
		'<th>a</th><th style="text-align:right">b</th>' \
		'<li><input type="checkbox" disabled checked> done</li>' \
		'<span class="spoiler" tabindex="0">secret</span>' \
		'<pre><code>&lt;b&gt;raw&lt;/b&gt;' \
		'<a href="http://www.lamps.example" rel="nofollow ugc">www.lamps.example</a>' \
		'<p><a class="ref" href="/t/1">#1</a> and not a#2, #3x or <code>#4</code></p>' \
		'<p>hi <a class="ref" href="/u/carol">@carol</a>, not me@x.example</p>'; do
	grep -qF "$want" "$t/page" || fail "the markup: no $want ($(grep -a -A3 'bold' "$t/page" | head -12))"
done
# The preview: the same HTML, for a message not posted
client bob bobpass1234 "$t/bob_preview.log" '{"cmd":"preview","body":"**b** @carol <i>"}'
answer "$t/bob_preview.log" 1001 | grep -qF '<strong>b<\/strong> <a class=\"ref\" href=\"\/u\/carol\">@carol<\/a> &lt;i&gt;' ||
	fail "the preview: $(answer "$t/bob_preview.log" 1001)"
# [HEARTH_LINES_CODE]: a newline breaks the line; a fenced block is one
# <pre><code>
client bob bobpass1234 "$t/bob_lines.log" '{"cmd":"preview","body":"a\nb\n\n```\nx\ny\n```"}'
answer "$t/bob_lines.log" 1001 | grep -qF '<p>a<br>\nb<\/p>\n<pre><code>x\ny\n<\/code><\/pre>' ||
	fail "a line break and a block: $(answer "$t/bob_lines.log" 1001)"
# An @name's page: the account's messages that stand
[ "$(get /u/admin)" = 200 ] && grep -q 'href="/t/1#m' "$t/page" ||
	fail "the account's page"
[ "$(get '/u/a%3Cb')" = 404 ] || fail "an account's page for a name that is none"
get /t/1 > /dev/null
# (the header's logo is the page's own)
sed -i 's|<img src="/brand/logo.png" alt="">||' "$t/page"
grep -qi 'href="[^"]*script\|<script\|<img' "$t/page" &&
	fail "the markup let through: $(grep -aio 'href="[^"]*script[^"]*"\|<script\|<img' "$t/page")"

# 8. The reply field is multi-line: Enter breaks the line, Up moves a row
# (the field's, not the buttons' -- ui_utils' keyboard page), Ctrl+Enter
# sends
# (the field's keys a tick apart, as typed)
CMDS='wait_log_any 20000 hearth: m1 text\ndelay 500\ntext one two\ndelay 100\nkeypress Return\ndelay 100\ntext three\ndelay 100\nkeypress Return\ndelay 100\nkeypress Return\ndelay 100\ntext four\ndelay 100\nkeypress Up\ndelay 100\nkeypress Up\ndelay 100\ntext X\ndelay 100\nkeydown ctrl\ndelay 100\nkeypress Return\ndelay 100\nkeyup ctrl\nwait_log_any 10000 Xthree\nquit\n' \
	client admin checkpass12 "$t/admin9.log" '' BUILDAT_HEARTH_OPEN=1
get /t/1 > /dev/null
grep -qPz '<p>one two<br>\nXthree</p>\n<p>four</p>' "$t/page" ||
	fail "the multi-line reply: $(grep -a -B1 -A2 'Xthree\|one two' "$t/page" | head -6)"

# 9. Files ([FORUM] step 5): a new account uploads none; the admin's JPEG
# comes back within 1080p without its EXIF, a PNG as a PNG, another file
# as it came, a fake PNG refused; robots.txt keeps crawlers off /f/; over
# the budget an unused image is crushed again and another file deleted,
# and past delete_after the rest go
python3 - "$t" <<'PY' || fail "the test files"
import io, sys
from PIL import Image
d = sys.argv[1]
exif = Image.Exif()
exif[0x010e] = "SECRETPLACE"
b = io.BytesIO()
Image.linear_gradient("L").resize((2400, 600)).convert("RGB").save(
        b, "JPEG", quality=30, exif=exif.tobytes())
assert b"SECRETPLACE" in b.getvalue()
open(d + "/up_jpg", "w").write(b.getvalue().hex())
b = io.BytesIO()
Image.new("RGBA", (3, 2), (10, 20, 30, 128)).save(b, "PNG")
open(d + "/up_png", "w").write(b.getvalue().hex())
PY
client bob bobpass1234 "$t/bob_files.log" '{"cmd":"upload","name":"a.txt","data":"68690a"}
{"cmd":"file_settings","budget":0}'
answer "$t/bob_files.log" 1001 | grep -q "no files yet" ||
	fail "a new account's upload: $(answer "$t/bob_files.log" 1001)"
answer "$t/bob_files.log" 1002 | grep -q "only the Host" ||
	fail "bob set the budget: $(answer "$t/bob_files.log" 1002)"
client admin checkpass12 "$t/admin_files.log" "{\"cmd\":\"upload\",\"name\":\"far.jpg\",\"data\":\"$(cat "$t/up_jpg")\"}
{\"cmd\":\"upload\",\"name\":\"dot.png\",\"data\":\"$(cat "$t/up_png")\"}
{\"cmd\":\"upload\",\"name\":\"notes.txt\",\"data\":\"68656c6c6f\"}
{\"cmd\":\"upload\",\"name\":\"fake.png\",\"data\":\"89504e470d0a1a0a6e6f\"}"
for i in 1001 1002 1003; do
	answer "$t/admin_files.log" $i | grep -q '"ok":true' ||
		fail "the admin's upload $i: $(answer "$t/admin_files.log" $i)"
done
answer "$t/admin_files.log" 1004 | grep -q "not an image Hearth can read" ||
	fail "a fake PNG: $(answer "$t/admin_files.log" 1004)"
res(){ # log id python-expression-of-r
	answer "$1" $2 | sed 's/^hr: //' | python3 -c 'import json, sys
r = json.load(sys.stdin); print(eval(sys.argv[1]))' "$3"
}
# The ids are random ([SEC_HEARTH_FILES])
FJ=$(res "$t/admin_files.log" 1001 'r["result"]["id"]')
FP=$(res "$t/admin_files.log" 1002 'r["result"]["id"]')
FO=$(res "$t/admin_files.log" 1003 'r["result"]["id"]')
[ "$FJ" -gt 1000 ] && [ "$FP" -gt 1000 ] ||
	fail "file ids by counting: $FJ $FP $FO"
image(){ # path -> "format WxH", or why not
	python3 -c 'import sys; from PIL import Image; d = open(sys.argv[1], "rb").read()
im = Image.open(sys.argv[1]); print(im.format, "%dx%d" % im.size, "EXIF" if b"SECRETPLACE" in d else "")' "$t/page" 2>&1
}
[ "$(get /f/$FJ/far.jpg)" = 200 ] && [ "$(image)" = "JPEG 1920x480 " ] ||
	fail "the JPEG as served: $(image)"
[ "$(get /f/$FP)" = 200 ] && [ "$(image)" = "PNG 3x2 " ] || fail "the PNG: $(image)"
[ "$(get /f/$FO)" = 200 ] && [ "$(cat "$t/page")" = hello ] || fail "the other file"
[ "$(get /robots.txt)" = 200 ] && grep -q "Disallow: /f/" "$t/page" ||
	fail "robots.txt: $(cat "$t/page")"
# [HEARTH_ATTACHMENTS]: an image's thumbnail at /f/<id>/thumb, within
# 320x240; a message's own images drawn, one from elsewhere a link; its
# files listed at its end, an image the text does not draw with its
# thumbnail there; the same to the client, and the thumbnail by request
[ "$(get /f/$FJ/thumb)" = 200 ] && [ "$(image)" = "JPEG 320x80 " ] ||
	fail "the JPEG's thumbnail: $(image)"
client admin checkpass12 "$t/admin_att.log" "{\"cmd\":\"new_thread\",\"topic\":1,\"title\":\"Shots\",\"body\":\"See [![far.jpg](/f/$FJ/thumb)](/f/$FJ/far.jpg) and [dot.png](/f/$FP/dot.png), ![away](https://example.com/x.png) [notes](/f/$FO/notes.txt)\"}"
TA=$(res "$t/admin_att.log" 1001 'r["result"]')
client admin checkpass12 "$t/admin_att2.log" "{\"cmd\":\"thread\",\"thread\":$TA}
{\"cmd\":\"thumb\",\"file\":$FP}"
[ "$(get /t/$TA)" = 200 ] || fail "the thread with files: $TA"
grep -q "<a href=\"/f/$FJ/far.jpg\" rel=\"nofollow ugc\"><img src=\"/f/$FJ/thumb\" alt=\"far.jpg\" loading=\"lazy\"></a>" "$t/page" ||
	fail "the drawn thumbnail: $(grep -o '<p>See.*' "$t/page" | head -c 600)"
grep -q '<img src="https' "$t/page" || ! grep -q '<a href="https://example.com/x.png" rel="nofollow ugc">\[image: away\]</a>' "$t/page" &&
	fail "an image from elsewhere: $(grep -o '<p>See.*' "$t/page" | head -c 600)"
files=$(grep -o '<ul class="files">.*</ul>' "$t/page")
echo "$files" | grep -q "far.jpg</a> <span class=\"meta\">JPEG image, " &&
	echo "$files" | grep -q "<img src=\"/f/$FP/thumb\"" &&
	! echo "$files" | grep -q "<img src=\"/f/$FJ/thumb\"" &&
	echo "$files" | grep -q "notes.txt</a> <span class=\"meta\">file, 5 bytes" ||
	fail "the files' list: $files"
[ "$(res "$t/admin_att2.log" 1001 '[(f["name"], f["image"], f["drawn"]) for f in r["result"]["list"][0]["files"]]')" = "[('far.jpg', True, True), ('dot.png', True, False), ('notes.txt', False, False)]" ] ||
	fail "the files to the client: $(answer "$t/admin_att2.log" 1001 | head -c 600)"
[ "$(res "$t/admin_att2.log" 1002 'r["result"]["data"][:16]')" = 89504e470d0a1a0a ] ||
	fail "the thumbnail by request: $(answer "$t/admin_att2.log" 1002 | head -c 300)"
client admin checkpass12 "$t/admin_files2.log" '{"cmd":"file_settings","budget":0,"lod2_after":0}'
answer "$t/admin_files2.log" 1001 | grep -q '"ok":true' ||
	fail "the budget: $(answer "$t/admin_files2.log" 1001)"
[ "$(get /f/$FJ)" = 200 ] && [ "$(image)" = "JPEG 960x240 " ] ||
	fail "the JPEG over the budget: $(image)"
[ "$(get /f/$FJ/thumb)" = 200 ] && [ "$(image)" = "JPEG 320x80 " ] ||
	fail "the thumbnail after the crush: $(image)"
[ "$(get /f/$FO)" = 404 ] || fail "the other file over the budget was kept"
client admin checkpass12 "$t/admin_files3.log" '{"cmd":"file_settings","delete_after":0}'
[ "$(get /f/$FJ)" = 404 ] && [ "$(get /f/$FP)" = 404 ] ||
	fail "past delete_after an image was kept"

# 8. [HEARTH_TRACKER]: a tracker topic; a new account attaches a patch
# (git format-patch) to a patch ticket, which shows it inline, and links
# only to a tracker domain; its tracker link to a domain not on the list
# waits for the admin, who accepts the domain; removing the domain hides
# the link again; and the patch, fetched, applies with git am
g="git -c user.name=Dave -c user.email=dave@example.org"
mkdir "$t/repo" && cd "$t/repo" && $g init -q && echo one > f.txt &&
	$g add f.txt && $g commit -qm base && $g clone -q . ../repo2 &&
	echo two >> f.txt && $g commit -qam "f.txt: two" &&
	$g format-patch -q -1 -o .. && cd "$here/Build" ||
	fail "the test repository"
mv "$t"/0001-*.patch "$t/fix.patch"
client admin checkpass12 "$t/tr_admin.log" '{"cmd":"file_settings","budget":1000000000,"lod2_after":86400,"delete_after":8640000}
{"cmd":"new_topic","name":"Tracker","about":"Tickets","tracker":true}
{"cmd":"tracker_domains","add":["codeberg.org"]}' \
	"BUILDAT_HEARTH_ADMIN=add dave davepass1234"
T=$(res "$t/tr_admin.log" 1002 'r["result"]')
[ -n "$T" ] || fail "the tracker topic: $(answer "$t/tr_admin.log" 1002)"
client dave davepass1234 "$t/tr_dave1.log" "{\"cmd\":\"upload\",\"name\":\"fix.patch\",\"data\":\"$(xxd -p "$t/fix.patch" | tr -d '\n')\"}
{\"cmd\":\"upload\",\"name\":\"fake.patch\",\"data\":\"68690a\"}"
F=$(res "$t/tr_dave1.log" 1001 'r["result"]["id"] if r["result"]["patch"] else ""')
[ -n "$F" ] || fail "a new account's patch: $(answer "$t/tr_dave1.log" 1001)"
answer "$t/tr_dave1.log" 1002 | grep -q "no files yet" ||
	fail "a .patch that is not one: $(answer "$t/tr_dave1.log" 1002)"
client dave davepass1234 "$t/tr_dave2.log" "{\"cmd\":\"new_thread\",\"topic\":$T,\"kind\":\"patch\",\"title\":\"f.txt: two\",\"body\":\"[fix.patch](/f/$F/fix.patch), also at https://codeberg.org/dave/buildat\"}
{\"cmd\":\"new_thread\",\"topic\":1,\"kind\":\"patch\",\"title\":\"x\",\"body\":\"y\"}"
D=$(res "$t/tr_dave2.log" 1001 'r["result"]')
[ -n "$D" ] || fail "a new account's patch ticket: $(answer "$t/tr_dave2.log" 1001)"
answer "$t/tr_dave2.log" 1002 | grep -q "in a tracker topic" ||
	fail "a patch outside a tracker: $(answer "$t/tr_dave2.log" 1002)"
client dave davepass1234 "$t/tr_dave3.log" "{\"cmd\":\"reply\",\"thread\":$D,\"body\":\"see https://evil.example/x\"}
{\"cmd\":\"tracker_link\",\"thread\":$D,\"link\":\"https://git.dave.example/buildat/tree/fix\"}
{\"cmd\":\"thread\",\"thread\":$D}"
answer "$t/tr_dave3.log" 1001 | grep -q '"ok":true' ||
	fail "a new account's link off the tracker domains: $(answer "$t/tr_dave3.log" 1001)"
[ "$(res "$t/tr_dave3.log" 1002 'r["result"]')" = False ] &&
	[ "$(res "$t/tr_dave3.log" 1003 'r["result"]["link"] + "|" + r["result"]["link_waiting"] + "|" + str(r["result"]["ticket"]) + "|" + str(len(r["result"]["list"][0]["patches"]))')" = "|https://git.dave.example/buildat/tree/fix|True|1" ] ||
	fail "the waiting tracker link: $(answer "$t/tr_dave3.log" 1003 | cut -c1-300)"
[ "$(get /t/$D)" = 200 ] && grep -q "^+two" "$t/page" && grep -q "codeberg.org/dave" "$t/page" &&
	! grep -q "Tracker:" "$t/page" && ! grep -q "evil.example" "$t/page" &&
	grep -q "Waiting for a Keeper to approve its link" "$t/page" ||
	fail "the ticket's page before the domain: $(grep -c . "$t/page") lines"
client admin checkpass12 "$t/tr_admin2.log" '{"cmd":"queue"}'
R=$(res "$t/tr_admin2.log" 1001 '[x["id"] for x in r["result"] if x["kind"] == "domain" and x["reason"] == "git.dave.example"][0]')
[ -n "$R" ] || fail "the domain is not queued: $(answer "$t/tr_admin2.log" 1001 | cut -c1-300)"
client admin checkpass12 "$t/tr_admin3.log" "{\"cmd\":\"moderate\",\"report\":$R,\"action\":\"accept\"}"
[ "$(get /t/$D)" = 200 ] && grep -q 'Tracker: <a rel="nofollow ugc" href="https://git.dave.example/buildat/tree/fix"' "$t/page" ||
	fail "the accepted domain's link is not shown: $(answer "$t/tr_admin3.log" 1001)"
client admin checkpass12 "$t/tr_admin4.log" '{"cmd":"tracker_domains","remove":["git.dave.example"]}'
[ "$(get /t/$D)" = 200 ] && ! grep -q "Tracker:" "$t/page" ||
	fail "a removed domain's link is still shown"
[ "$(get /f/$F/fix.patch)" = 200 ] && cd "$t/repo2" && $g am -q "$t/page" &&
	grep -q two f.txt && cd "$here/Build" ||
	fail "the patch as served does not apply with git am"
echo "ok: a new account's patch ticket, inline and applied with git am; its links and its tracker link by the domains"
# [SEC_HEARTH_FILES]: the ticket hidden, its patch is not served
M=$(res "$t/tr_dave3.log" 1003 'r["result"]["list"][0]["id"]')
client admin checkpass12 "$t/tr_admin5.log" "{\"cmd\":\"report\",\"message\":$M,\"reason\":\"x\"}
{\"cmd\":\"queue\"}"
R=$(res "$t/tr_admin5.log" 1002 "[x['id'] for x in r['result'] if x['message'] == $M][0]")
client admin checkpass12 "$t/tr_admin6.log" "{\"cmd\":\"moderate\",\"report\":$R,\"action\":\"hide\",\"statement\":\"x\"}"
answer "$t/tr_admin6.log" 1001 | grep -q '"ok":true' ||
	fail "the ticket's hide: $(answer "$t/tr_admin6.log" 1001)"
[ "$(get /f/$F/fix.patch)" = 404 ] || fail "a hidden ticket's patch is served"
echo "ok: a hidden ticket's patch is not served"

# 10. A long thread is read a part at a time: the page links on to the
# rest, the client reads on by itself; and pages are limited per address.
# 20 messages of 20 kB, put in the file (the API's limits make them slow).
kill $pid; wait $pid 2>/dev/null
python3 - "$t/srv/apps/hearth/hearth.sqlite" <<'PY' || fail "the long thread"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executemany("INSERT INTO messages(thread, author, body, created) "
        "VALUES(1, 'admin', ?, 1)", [("x" * 19990 + " END%d" % i,) for i in range(1, 21)])
c.commit()
PY
start_server "$t/srv2.log" "Hearth: " 120 $P \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start again"
pid=$SERVER_PID
u=/t/1 pages=0
while [ "$(get "$u")" = 200 ] && pages=$((pages + 1)) &&
		u=$(grep -o '/t/1?after=[0-9]*' "$t/page"); do :; done
[ $pages -ge 2 ] && grep -q "END20" "$t/page" && ! grep -q "END1<" "$t/page" ||
	fail "the long thread's pages ($pages, the last: $(grep -o 'END[0-9]*' "$t/page" | tr '\n' ' '))"
WAIT=END20 client admin checkpass12 "$t/admin10.log" '' BUILDAT_HEARTH_OPEN=1
grep -a '^.*hr: ' "$t/admin10.log" | grep -q '"more":true' &&
	grep -a 'hr: ' "$t/admin10.log" | grep -q 'END20' ||
	fail "the client did not read the long thread on"
# 11. [HEARTH_UI]: the read position -- a thread with a message bob has
# not read is unread to him, and read once he has opened it; "thread"
# says where he was; a followed thread is listed; an account's page gives
# the trust counts to its owner alone; only the admin edits a topic
client admin checkpass12 "$t/admin11.log" '{"cmd":"new_thread","topic":1,"title":"Unread","body":"Read me"}
{"cmd":"edit_topic","topic":1,"name":"Help","about":"Questions & answers"}'
nt=$(answer "$t/admin11.log" 1001 | grep -o '"result":[0-9]*' | cut -d: -f2)
[ -n "$nt" ] || fail "the new thread: $(answer "$t/admin11.log" 1001)"
answer "$t/admin11.log" 1002 | grep -q '"ok":true' || fail "the admin's topic edit"
client bob bobpass1234 "$t/bob11.log" '{"cmd":"topic","topic":1}
{"cmd":"thread","thread":'$nt'}
{"cmd":"topic","topic":1}
{"cmd":"follow","thread":'$nt',"on":true}
{"cmd":"following"}
{"cmd":"account","name":"bob"}
{"cmd":"account","name":"admin"}
{"cmd":"edit_topic","topic":1,"name":"Mine","about":""}'
unread(){ answer "$t/bob11.log" $1 | grep -o "{[^{}]*\"id\":$nt,[^{}]*}" | grep -o '"unread":[a-z]*'; }
[ "$(unread 1001)" = '"unread":true' ] || fail "unread before reading: $(unread 1001)"
answer "$t/bob11.log" 1002 | grep -q '"read":0' || fail "where bob was: $(answer "$t/bob11.log" 1002 | head -c 300)"
[ "$(unread 1003)" = '"unread":false' ] || fail "unread after reading: $(unread 1003)"
answer "$t/bob11.log" 1005 | grep -q "\"id\":$nt," || fail "following: $(answer "$t/bob11.log" 1005 | head -c 300)"
answer "$t/bob11.log" 1006 | grep -q '"trust":{' || fail "bob's own trust counts"
answer "$t/bob11.log" 1007 | grep -q '"trust"' && fail "the admin's trust counts shown to bob"
answer "$t/bob11.log" 1008 | grep -q '"ok":false' || fail "bob edited a topic"

# 12. [TRUST_LADDER]: a held link, a helper, reports weighed by network
num(){ answer "$1" $2 | grep -o '"result":[0-9]*' | cut -d: -f2; }
B1=$(num "$t/bob.log" 1001)
WAIT="admin result: " client admin checkpass12 "$t/admin12a.log" '' "BUILDAT_HEARTH_ADMIN=add erin erinpass1234"
client erin erinpass1234 "$t/erin12.log" '{"cmd":"reply","thread":1,"body":"see [lamps](//erinlamps.example)"}
{"cmd":"reply","thread":1,"body":"and https://two.example"}'
held=$(num "$t/erin12.log" 1001)
[ -n "$held" ] || fail "erin's link: $(answer "$t/erin12.log" 1001)"
answer "$t/erin12.log" 1002 | grep -q "waiting for approval already" ||
	fail "a second held link: $(answer "$t/erin12.log" 1002)"
get /m/$held > /dev/null; grep -q "erinlamps.example" "$t/page" && fail "a held link on the page"
client admin checkpass12 "$t/admin12.log" '{"cmd":"level","name":"carol","level":20}'
answer "$t/admin12.log" 1001 | grep -q '"ok":true' || fail "carol made a helper: $(answer "$t/admin12.log" 1001)"
client carol carolpass1234 "$t/carol12.log" '{"cmd":"queue"}
{"cmd":"level","name":"bob","level":20}
{"cmd":"me"}'
R=$(res "$t/carol12.log" 1001 '[x["id"] for x in r["result"] if x["kind"] == "held" and x["message"] == '"$held"'][0]')
[ -n "$R" ] || fail "the held link not in a helper's queue: $(answer "$t/carol12.log" 1001 | cut -c1-300)"
answer "$t/carol12.log" 1002 | grep -q "only levels below one's own" || fail "a helper made a helper"
answer "$t/carol12.log" 1003 | grep -q '"level":20' || fail "carol's level: $(answer "$t/carol12.log" 1003)"
client carol carolpass1234 "$t/carol12b.log" "{\"cmd\":\"moderate\",\"report\":$R,\"action\":\"approve\"}
{\"cmd\":\"account\",\"name\":\"erin\"}
{\"cmd\":\"trust\",\"name\":\"bob\",\"on\":false}
{\"cmd\":\"trust\",\"name\":\"dave\",\"on\":true}"
answer "$t/carol12b.log" 1001 | grep -q '"ok":true' || fail "the approval: $(answer "$t/carol12b.log" 1001)"
answer "$t/carol12b.log" 1002 | grep -q '"approved_by":\[{"name":"carol".*"level":10' ||
	fail "erin after the approval: $(answer "$t/carol12b.log" 1002 | cut -c1-300)"
answer "$t/carol12b.log" 1003 | grep -q "only its own approval" || fail "a helper took back another's trust"
answer "$t/carol12b.log" 1004 | grep -q '"ok":true' || fail "carol trusted dave: $(answer "$t/carol12b.log" 1004)"
get /m/$held > /dev/null; grep -q "erinlamps.example" "$t/page" || fail "the approved link not shown"
# erin and dave, members on one network (every client is 127.0.0.1):
# one report's weight, 1
rep(){ client $1 $2 "$t/$3" "{\"cmd\":\"report\",\"message\":$B1,\"reason\":\"rude\"}"; }
rep erin erinpass1234 erin12b.log
rep dave davepass1234 dave12.log
[ "$(get /m/$B1)" = 200 ] && ! grep -q "Reported; hidden" "$t/page" ||
	fail "hidden by two members' reports from one network ($(answer "$t/dave12.log" 1001))"
# A helper's, 3, hides it until a moderator looks; dismissed, it is
# shown again, and the helper's next report weighs nothing
rep carol carolpass1234 carol12c.log
get /m/$B1 > /dev/null; grep -q "Reported; hidden until a Steward looks" "$t/page" ||
	fail "a helper's report did not hide it ($(answer "$t/carol12c.log" 1001))"
R2=$(num "$t/carol12c.log" 1001)
client admin checkpass12 "$t/admin12b.log" "{\"cmd\":\"moderate\",\"report\":$R2,\"action\":\"dismiss\"}"
[ "$(get /m/$B1)" = 200 ] && ! grep -q "Reported; hidden" "$t/page" ||
	fail "shown again after the dismissal ($(answer "$t/admin12b.log" 1001))"
rep carol carolpass1234 carol12d.log
[ "$(get /m/$B1)" = 200 ] && ! grep -q "Reported; hidden" "$t/page" ||
	fail "a report weighed after its reporter's was overturned"
echo "ok: held links approved by a helper, reports by network"

# 13. [HEARTH_NEW_IMAGES]: a new account uploads an image (no other file
# but a patch), names one of its images a thread; it is not drawn but
# for a helper, whose "show to everyone" draws it for all, in the log; a
# helper takes one back; the account trusted, its other images are
# shown, the one taken back not
WAIT="admin result: " client admin checkpass12 "$t/admin13a.log" '' "BUILDAT_HEARTH_ADMIN=add frank frankpass1234"
client frank frankpass1234 "$t/frank13.log" "{\"cmd\":\"upload\",\"name\":\"one.png\",\"data\":\"$(cat "$t/up_png")\"}
{\"cmd\":\"upload\",\"name\":\"two.png\",\"data\":\"$(cat "$t/up_png")\"}
{\"cmd\":\"upload\",\"name\":\"three.png\",\"data\":\"$(cat "$t/up_png")\"}
{\"cmd\":\"upload\",\"name\":\"a.txt\",\"data\":\"68690a\"}"
I1=$(res "$t/frank13.log" 1001 'r["result"]["id"]')
I2=$(res "$t/frank13.log" 1002 'r["result"]["id"]')
I3=$(res "$t/frank13.log" 1003 'r["result"]["id"]')
[ "$I1" -gt 0 ] && [ "$I2" -gt 0 ] && [ "$I3" -gt 0 ] ||
	fail "a new account's images: $(answer "$t/frank13.log" 1001 | head -c 300)"
answer "$t/frank13.log" 1004 | grep -q "no files yet but a patch or an image" ||
	fail "a new account's other file: $(answer "$t/frank13.log" 1004)"
img(){ echo "[![$1](/f/$2/thumb)](/f/$2/$1)"; }
client frank frankpass1234 "$t/frank13b.log" "{\"cmd\":\"new_thread\",\"topic\":1,\"title\":\"My lamp\",\"body\":\"$(img one.png $I1)\"}"
TN=$(num "$t/frank13b.log" 1001)
[ -n "$TN" ] || fail "a new account's image in a thread: $(answer "$t/frank13b.log" 1001)"
client frank frankpass1234 "$t/frank13c.log" "{\"cmd\":\"reply\",\"thread\":$TN,\"body\":\"$(img two.png $I2)\"}
{\"cmd\":\"reply\",\"thread\":$TN,\"body\":\"again $(img one.png $I1)\"}
{\"cmd\":\"new_thread\",\"topic\":1,\"title\":\"Other lamp\",\"body\":\"$(img two.png $I2)\"}
{\"cmd\":\"reply\",\"thread\":1,\"body\":\"$(img three.png $I3)\"}"
answer "$t/frank13c.log" 1001 | grep -q "one image a thread" ||
	fail "a second image in the thread: $(answer "$t/frank13c.log" 1001)"
for i in 1002 1003 1004; do
	answer "$t/frank13c.log" $i | grep -q '"ok":true' ||
		fail "frank's post $i: $(answer "$t/frank13c.log" $i)"
done
TN2=$(num "$t/frank13c.log" 1003)
M3=$(num "$t/frank13c.log" 1004)
shown(){ # log id: the first message's files' shown
	res "$1" $2 '[f["shown"] for f in r["result"]["list"][0]["files"]]'
}
[ "$(get /t/$TN)" = 200 ] && ! grep -q "<img src=\"/f/$I1/" "$t/page" &&
	grep -q "a new account's image, not shown until a helper says" "$t/page" ||
	fail "a new account's image drawn on the page"
client erin erinpass1234 "$t/erin13.log" "{\"cmd\":\"thread\",\"thread\":$TN}"
client carol carolpass1234 "$t/carol13.log" "{\"cmd\":\"thread\",\"thread\":$TN}
{\"cmd\":\"vet_file\",\"file\":$I1,\"on\":true}
{\"cmd\":\"vet_file\",\"file\":$I2,\"on\":false}"
client erin erinpass1234 "$t/erin13b.log" "{\"cmd\":\"thread\",\"thread\":$TN}
{\"cmd\":\"vet_file\",\"file\":$I3,\"on\":true}"
[ "$(shown "$t/erin13.log" 1001)" = "[False]" ] && [ "$(shown "$t/carol13.log" 1001)" = "[True]" ] &&
	[ "$(shown "$t/erin13b.log" 1001)" = "[True]" ] ||
	fail "shown to a member, a helper, then the member: $(shown "$t/erin13.log" 1001) $(shown "$t/carol13.log" 1001) $(shown "$t/erin13b.log" 1001)"
answer "$t/erin13b.log" 1002 | grep -q "says whether everyone sees" || fail "a member vetted an image"
grep -aq "carol showed everyone image $I1" "$t/srv2.log" || fail "the log has no vetting"
grep -aq "carol took back image $I2" "$t/srv2.log" || fail "the log has no taking back"
[ "$(get /t/$TN)" = 200 ] && grep -q "<img src=\"/f/$I1/thumb\"" "$t/page" ||
	fail "the vetted image not drawn on the page"
client admin checkpass12 "$t/admin13b.log" '{"cmd":"trust","name":"frank","on":true}'
[ "$(get /m/$M3)" = 200 ] && grep -q "<img src=\"/f/$I3/thumb\"" "$t/page" ||
	fail "a trusted account's earlier image not shown"
[ "$(get /t/$TN2)" = 200 ] && ! grep -q "<img src=\"/f/$I2/" "$t/page" ||
	fail "an image taken back shown once its account is trusted"
echo "ok: a new account's one image a thread, shown once a helper says or it is trusted"
# [SEC_RUN4_LEFTOVERS]: a helper does not take back the admin's image; an
# image is exactly /f/<id>[/<name>], not another path after it; /f/ says
# nosniff
client admin checkpass12 "$t/admin13c.log" "{\"cmd\":\"upload\",\"name\":\"a.png\",\"data\":\"$(cat "$t/up_png")\"}"
FP=$(res "$t/admin13c.log" 1001 'r["result"]["id"]')
client carol carolpass1234 "$t/carol13d.log" "{\"cmd\":\"vet_file\",\"file\":$FP,\"on\":false}"
answer "$t/carol13d.log" 1001 | grep -q "not yours to vet" ||
	fail "a helper took back the admin's image: $(answer "$t/carol13d.log" 1001)"
client admin checkpass12 "$t/admin13d.log" "{\"cmd\":\"reply\",\"thread\":1,\"body\":\"![a](/f/$FP/../../x) ![b](/f/$FP/ok.png)\"}"
MI=$(num "$t/admin13d.log" 1001)
[ "$(get /m/$MI)" = 200 ] && ! grep -q "<img src=\"/f/$FP/\.\." "$t/page" &&
	grep -q "<img src=\"/f/$FP/ok.png\"" "$t/page" ||
	fail "an image path past /f/<id>/<name>: $(grep -o '<img src="/f/[^>]*>' "$t/page" | head -3)"
curl -s -D - -o /dev/null "$U/f/$FP" | grep -qi "^X-Content-Type-Options: nosniff" ||
	fail "/f/ without nosniff"
echo "ok: a helper vets only below its level; an image by its exact path; /f/ nosniff"
# A Steward (a moderator): in the Server window's Accounts page, levels
# below its own and kicks and bans, but no password reset
client admin checkpass12 "$t/admin12c.log" '{"cmd":"level","name":"dave","level":30}'
answer "$t/admin12c.log" 1001 | grep -q '"ok":true' || fail "dave made a Steward: $(answer "$t/admin12c.log" 1001)"
WAIT="accounts listed
admin result: erin is a Guest" client dave davepass1234 "$t/dave12b.log" '{"cmd":"me"}' "BUILDAT_HEARTH_ADMIN=level bob 20
level carol 30
password bob newpass1234
level erin 0"
grep -aq "accounts listed" "$t/dave12b.log" || fail "no accounts list for a Steward"
grep -aq "admin result: bob is a Keeper" "$t/dave12b.log" || fail "a Steward made a Keeper: $(grep -a "admin result" "$t/dave12b.log")"
grep -aq "admin result: One sets only levels below one's own" "$t/dave12b.log" || fail "a Steward made a Steward"
grep -aq "admin result: Only the Host does that" "$t/dave12b.log" || fail "a Steward reset a password"
grep -aq "admin result: erin is a Guest" "$t/dave12b.log" || fail "a Steward took back a trust"
echo "ok: a Steward's Accounts page"

[ $n429 -gt 0 ] || fail "no page limit per address"
echo "PASS: posted, replied, edited, refused; answered, mentioned, notified; a chat line live; read as HTML with the markup escaped; CommonMark with no unsafe link; a multi-line reply; found by search; a new account limited; reported, hidden with a statement, appealed, restored; files crushed, served and swept, thumbnails drawn and listed; a new account's one image a thread, vetted by a helper; a patch ticket by a new account applied with git am; a long thread read in parts; read positions, following, an account page, a topic edited; a held link approved by a helper, reports weighed by network, a Steward's Accounts page; pages limited"
